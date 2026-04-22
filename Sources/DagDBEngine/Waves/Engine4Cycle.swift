// Engine4Cycle — orchestrates one epoch over a DagDB.
//
// One epoch = four sequential Metal compute passes (the "four snakes"):
//
//   1. Forward wave     — Queen → Leaves, iso-walk per rank
//   2. Leaf mirror      — state copied from leaves to mirror-leaves
//   3. Backward wave    — Mirror-leaves → Mirror-queen, with validation gates
//   4. Queen mirror     — Mirror-queen → next Queen (rank advances)
//
// Instrumentation (H(t), λ₂(t)) runs after every wave via side kernels.
//
// This is the skeleton. Rank-band dispatch is in place; algorithm
// specifics (e.g. the 14 validation gates in Kernel 3; the exact LUT6
// aggregation during leaf mirror; VBR escalation + library-loader wiring)
// are owed in subsequent commits.

import Foundation
import Metal

public final class Engine4Cycle {
    public struct Telemetry {
        public var epochIndex: Int = 0
        public var wavelinesProcessed: Int = 0
        public var entropyBits: UInt64 = 0        // fixed-point: 1000 * H(t)
        public var wallTimeMs: Double = 0
    }

    public let dag: DagDB
    private let queue: MTLCommandQueue
    private let forwardPSO: MTLComputePipelineState
    private let leafMirrorPSO: MTLComputePipelineState
    private let backwardPSO: MTLComputePipelineState
    private let queenMirrorPSO: MTLComputePipelineState
    private let entropyPSO: MTLComputePipelineState
    private let entropyAccBuf: MTLBuffer

    public private(set) var telemetry = Telemetry()

    public init(dag: DagDB) throws {
        self.dag = dag
        guard let q = dag.device.makeCommandQueue() else {
            throw EngineError.commandQueueCreationFailed
        }
        self.queue = q

        // Load the Metal shader source from the package's resource bundle
        // and compile at runtime. Avoids SwiftPM's .process("Shaders")
        // metallib-build-on-command-line quirk; works under `swift build`
        // and `swift test` without an Xcode project.
        guard let url = Bundle.module.url(forResource: "engine",
                                           withExtension: "metal"),
              let source = try? String(contentsOf: url, encoding: .utf8) else {
            throw EngineError.metalLibraryLoadFailed
        }
        let library: MTLLibrary
        do {
            library = try dag.device.makeLibrary(source: source, options: nil)
        } catch {
            throw EngineError.metalLibraryLoadFailed
        }

        func makePSO(_ name: String) throws -> MTLComputePipelineState {
            guard let fn = library.makeFunction(name: name) else {
                throw EngineError.functionNotFound(name)
            }
            return try dag.device.makeComputePipelineState(function: fn)
        }

        self.forwardPSO     = try makePSO("forwardWave")
        self.leafMirrorPSO  = try makePSO("leafMirror")
        self.backwardPSO    = try makePSO("backwardWave")
        self.queenMirrorPSO = try makePSO("queenMirror")
        self.entropyPSO     = try makePSO("entropyContribution")

        self.entropyAccBuf  = dag.device.makeBuffer(length: MemoryLayout<UInt32>.stride,
                                                     options: MTLResourceOptions.storageModeShared)!
    }

    // ─────────────────────────────────────────────────────────
    // Public: run one full 4-cycle epoch.
    // ─────────────────────────────────────────────────────────
    @discardableResult
    public func tick() throws -> Telemetry {
        let t0 = CFAbsoluteTimeGetCurrent()

        // Phase 1 — forward wave, rank 0 .. maxRank, ascending.
        for r in 0...Int(dag.maxRank) {
            try dispatch(pso: forwardPSO,
                         waveRank: UInt32(r),
                         gridSize: dag.nodeCount,
                         isMirror: false)
        }

        // Phase 2 — leaf mirror (a single dispatch at rank = maxRank).
        try dispatchLeafMirror()

        // Phase 3 — backward wave, mirror half.
        // Mirror-rank of forward node at rank r is (2*maxRank - r + 1), so
        // mirror ranks span [maxRank + 1, 2*maxRank + 1] inclusive. The
        // original range [maxRank+1, 2*maxRank] missed the mirror of the
        // rank-0 forward node (if any); extending by one covers the full
        // mirror half regardless of which rank the Queen sits on.
        for r in (Int(dag.maxRank) + 1)...Int(2 * dag.maxRank + 1) {
            try dispatch(pso: backwardPSO,
                         waveRank: UInt32(r),
                         gridSize: 2 * dag.nodeCount,
                         isMirror: true)
        }

        // Phase 4 — queen mirror (rank advances).
        try dispatchQueenMirror()

        // Instrumentation — accumulate entropy for this epoch.
        resetEntropyAccumulator()
        try dispatchEntropy()
        let entropy = readEntropyAccumulator()

        let t1 = CFAbsoluteTimeGetCurrent()
        telemetry.epochIndex += 1
        telemetry.wavelinesProcessed += 2 * Int(dag.maxRank) + 2
        telemetry.entropyBits = entropy
        telemetry.wallTimeMs  = (t1 - t0) * 1000.0
        return telemetry
    }

    // ─────────────────────────────────────────────────────────
    // Private: core dispatch helpers.
    // ─────────────────────────────────────────────────────────

    private func dispatch(pso: MTLComputePipelineState,
                          waveRank: UInt32,
                          gridSize: Int,
                          isMirror: Bool) throws
    {
        guard let cb = queue.makeCommandBuffer(),
              let enc = cb.makeComputeCommandEncoder() else {
            throw EngineError.encoderCreationFailed
        }
        enc.setComputePipelineState(pso)
        enc.setBuffer(dag.buffer, offset: 0, index: 0)
        var rank = waveRank
        enc.setBytes(&rank, length: MemoryLayout<UInt32>.size, index: 1)
        var nc = UInt32(dag.nodeCount)
        enc.setBytes(&nc, length: MemoryLayout<UInt32>.size, index: 2)

        let tg = MTLSize(width: min(pso.maxTotalThreadsPerThreadgroup, 256), height: 1, depth: 1)
        let gr = MTLSize(width: gridSize, height: 1, depth: 1)
        enc.dispatchThreads(gr, threadsPerThreadgroup: tg)
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        if let err = cb.error { throw EngineError.commandBufferFailed(err) }
    }

    private func dispatchLeafMirror() throws {
        guard let cb = queue.makeCommandBuffer(),
              let enc = cb.makeComputeCommandEncoder() else {
            throw EngineError.encoderCreationFailed
        }
        enc.setComputePipelineState(leafMirrorPSO)
        enc.setBuffer(dag.buffer, offset: 0, index: 0)
        var maxRank = dag.maxRank
        enc.setBytes(&maxRank, length: MemoryLayout<UInt32>.size, index: 1)
        var nc = UInt32(dag.nodeCount)
        enc.setBytes(&nc, length: MemoryLayout<UInt32>.size, index: 2)
        let gr = MTLSize(width: dag.nodeCount, height: 1, depth: 1)
        let tg = MTLSize(width: min(leafMirrorPSO.maxTotalThreadsPerThreadgroup, 256),
                         height: 1, depth: 1)
        enc.dispatchThreads(gr, threadsPerThreadgroup: tg)
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        if let err = cb.error { throw EngineError.commandBufferFailed(err) }
    }

    private func dispatchQueenMirror() throws {
        guard let cb = queue.makeCommandBuffer(),
              let enc = cb.makeComputeCommandEncoder() else {
            throw EngineError.encoderCreationFailed
        }
        enc.setComputePipelineState(queenMirrorPSO)
        enc.setBuffer(dag.buffer, offset: 0, index: 0)
        // Mirror-queen index = queenIdx + nodeCount (convention).
        var mqIdx = dag.queenIdx + UInt32(dag.nodeCount)
        enc.setBytes(&mqIdx, length: MemoryLayout<UInt32>.size, index: 1)
        var qIdx = dag.queenIdx
        enc.setBytes(&qIdx, length: MemoryLayout<UInt32>.size, index: 2)
        enc.dispatchThreads(MTLSize(width: 1, height: 1, depth: 1),
                            threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1))
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        if let err = cb.error { throw EngineError.commandBufferFailed(err) }
    }

    private func dispatchEntropy() throws {
        guard let cb = queue.makeCommandBuffer(),
              let enc = cb.makeComputeCommandEncoder() else {
            throw EngineError.encoderCreationFailed
        }
        enc.setComputePipelineState(entropyPSO)
        enc.setBuffer(dag.buffer, offset: 0, index: 0)
        enc.setBuffer(entropyAccBuf, offset: 0, index: 1)
        var nc = UInt32(dag.nodeCount)
        enc.setBytes(&nc, length: MemoryLayout<UInt32>.size, index: 2)
        enc.dispatchThreads(MTLSize(width: dag.nodeCount, height: 1, depth: 1),
                            threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        if let err = cb.error { throw EngineError.commandBufferFailed(err) }
    }

    private func resetEntropyAccumulator() {
        entropyAccBuf.contents().assumingMemoryBound(to: UInt32.self).pointee = 0
    }

    private func readEntropyAccumulator() -> UInt64 {
        UInt64(entropyAccBuf.contents().assumingMemoryBound(to: UInt32.self).pointee)
    }
}

public enum EngineError: Error {
    case commandQueueCreationFailed
    case metalLibraryLoadFailed
    case functionNotFound(String)
    case encoderCreationFailed
    case commandBufferFailed(Error)
}
