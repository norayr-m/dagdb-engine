/// DagDBDelta — Truth-state time-series codec for DagDB.
///
/// Purpose: compact recording of truth flips over many ticks.
/// Scope: static block (rank + LUT6 + nodeType) + N truth frames.
///
/// NOTE ON FORMAT RELATIONSHIP (see DagDBSnapshot.swift):
///   - DagDBSnapshot (.dags)  = full engine state at one instant, incl. edges.
///   - DagDBDelta    (.dagb)  = time-series of truth states, WITHOUT edges.
///   These formats are complementary, not interchangeable. Unification into
///   one file ("snapshot + appended frames") is planned: extend DagDBSnapshot
///   with a hasFrames flag bit and trailing frame section. Not yet wired.
///   Shared zlib codec lives in DagDBSnapshot.zlibCompress/zlibDecompress.
///
/// Format (.dagb):
///   Header: "DAGB" (4) + nodeCount (u32) + maxRank (u8) + padding (3)
///           + nFrames (u32) + keyframeInterval (u32) = 20 bytes
///   Static block: rank[n] + lut6Low[n*4] + lut6High[n*4] + nodeType[n]
///   Frame i: compressed_size (u32) + zlib(data)
///     where data = full truthState if keyframe, else XOR delta

import Foundation
// Compression handled via DagDBSnapshot.zlibCompress / zlibDecompress

public struct DagDBDelta {

    static let magic: [UInt8] = [0x44, 0x41, 0x47, 0x42]  // "DAGB"

    // MARK: - Encoder

    public final class Encoder {
        public let url: URL
        let nodeCount: UInt32
        let maxRank: UInt8
        let keyframeInterval: UInt32
        var handle: FileHandle
        var prevTruth: [UInt8]?
        public var frameCount: UInt32 = 0

        public init(path: String, nodeCount: Int, maxRank: Int,
                    staticState: DagDBState, keyframeInterval: Int = 60) throws {
            self.url = URL(fileURLWithPath: path)
            self.nodeCount = UInt32(nodeCount)
            self.maxRank = UInt8(maxRank)
            self.keyframeInterval = UInt32(keyframeInterval)

            FileManager.default.createFile(atPath: path, contents: nil)
            self.handle = try FileHandle(forWritingTo: url)

            // Write header (20 bytes)
            var header = Data()
            header.append(contentsOf: DagDBDelta.magic)
            var nc = self.nodeCount
            header.append(Data(bytes: &nc, count: 4))
            var mr = self.maxRank
            header.append(Data(bytes: &mr, count: 1))
            header.append(contentsOf: [UInt8](repeating: 0, count: 3))  // padding
            var nf: UInt32 = 0  // placeholder
            header.append(Data(bytes: &nf, count: 4))
            var kfi = self.keyframeInterval
            header.append(Data(bytes: &kfi, count: 4))
            handle.write(header)

            // Write static block: rank + lut6Low + lut6High + nodeType
            staticState.rank.withUnsafeBytes { handle.write(Data($0)) }

            // LUT6 as raw bytes
            staticState.lut6Low.withUnsafeBytes { handle.write(Data($0)) }
            staticState.lut6High.withUnsafeBytes { handle.write(Data($0)) }
            staticState.nodeType.withUnsafeBytes { handle.write(Data($0)) }
        }

        /// Add a truth state frame.
        public func addFrame(_ truthState: [UInt8]) {
            let isKeyframe = prevTruth == nil ||
                (keyframeInterval > 0 && frameCount % keyframeInterval == 0)

            let data: [UInt8]
            if isKeyframe {
                data = truthState
            } else {
                let prev = prevTruth!
                var delta = [UInt8](repeating: 0, count: truthState.count)
                for i in 0..<truthState.count {
                    delta[i] = truthState[i] ^ prev[i]
                }
                data = delta
            }

            // Shared zlib codec — see DagDBSnapshot.zlibCompress for the unified helper.
            let compressed = DagDBSnapshot.zlibCompress(Data(data))
            var size = UInt32(compressed.count)
            handle.write(Data(bytes: &size, count: 4))
            handle.write(compressed)

            prevTruth = truthState
            frameCount += 1
        }

        public func finalize() {
            // Update frame count at offset 12
            handle.seek(toFileOffset: 12)
            var nf = frameCount
            handle.write(Data(bytes: &nf, count: 4))
            handle.closeFile()
        }
    }

    // MARK: - Decoder

    public final class Decoder {
        public let nodeCount: Int
        public let maxRank: Int
        public let frameCount: Int
        public let keyframeInterval: Int

        // Static state (loaded once)
        public let rank: [UInt8]
        public let lut6Low: [UInt32]
        public let lut6High: [UInt32]
        public let nodeType: [UInt8]

        // Frame data
        private let data: Data
        private var frameOffsets: [Int]
        private var currentFrame: [UInt8]
        private var currentIndex: Int = -1

        public init(path: String) throws {
            self.data = try Data(contentsOf: URL(fileURLWithPath: path))
            var offset = 0

            // Read header
            guard data.count >= 20 else { throw DeltaError.invalidFormat }
            let m = [UInt8](data[0..<4])
            guard m == DagDBDelta.magic else { throw DeltaError.invalidMagic }
            offset = 4

            let nc = Int(UInt32(data[4]) | UInt32(data[5]) << 8 |
                        UInt32(data[6]) << 16 | UInt32(data[7]) << 24)
            let mr = Int(data[8])
            // skip 3 padding bytes
            let nf = Int(UInt32(data[12]) | UInt32(data[13]) << 8 |
                        UInt32(data[14]) << 16 | UInt32(data[15]) << 24)
            let kfi = Int(UInt32(data[16]) | UInt32(data[17]) << 8 |
                         UInt32(data[18]) << 16 | UInt32(data[19]) << 24)

            self.nodeCount = nc
            self.maxRank = mr
            self.frameCount = nf
            self.keyframeInterval = kfi
            self.currentFrame = [UInt8](repeating: 0, count: nc)
            offset = 20

            // Read static block (byte-safe, no alignment assumptions)
            self.rank = Array(data[offset..<offset+nc])
            offset += nc

            var low = [UInt32](repeating: 0, count: nc)
            for i in 0..<nc {
                let b = offset + i * 4
                low[i] = UInt32(data[b]) | UInt32(data[b+1]) << 8 |
                         UInt32(data[b+2]) << 16 | UInt32(data[b+3]) << 24
            }
            self.lut6Low = low
            offset += nc * 4

            var high = [UInt32](repeating: 0, count: nc)
            for i in 0..<nc {
                let b = offset + i * 4
                high[i] = UInt32(data[b]) | UInt32(data[b+1]) << 8 |
                          UInt32(data[b+2]) << 16 | UInt32(data[b+3]) << 24
            }
            self.lut6High = high
            offset += nc * 4

            self.nodeType = Array(data[offset..<offset+nc])
            offset += nc

            // Scan frame offsets
            var offsets = [Int]()
            for _ in 0..<nf {
                offsets.append(offset)
                let sz = Int(UInt32(data[offset]) | UInt32(data[offset+1]) << 8 |
                            UInt32(data[offset+2]) << 16 | UInt32(data[offset+3]) << 24)
                offset += 4 + sz
            }
            self.frameOffsets = offsets
        }

        /// Get truth state at frame index.
        public func truthState(at index: Int) -> [UInt8] {
            let idx = min(index, frameCount - 1)
            guard idx >= 0 else { return [UInt8](repeating: 0, count: nodeCount) }

            // Find nearest keyframe
            let kf = keyframeInterval > 0 ? (idx / keyframeInterval) * keyframeInterval : 0

            // Reset if needed
            if currentIndex < 0 || currentIndex > idx || currentIndex < kf {
                let off = frameOffsets[kf]
                let sz = Int(UInt32(data[off]) | UInt32(data[off+1]) << 8 | UInt32(data[off+2]) << 16 | UInt32(data[off+3]) << 24)
                let compressedData = data.subdata(in: (off+4)..<(off+4+sz))
                currentFrame = [UInt8](DagDBSnapshot.zlibDecompress(compressedData, expectedSize: nodeCount))
                currentIndex = kf
            }

            // Decode forward
            while currentIndex < idx {
                let next = currentIndex + 1
                let off = frameOffsets[next]
                let sz = Int(UInt32(data[off]) | UInt32(data[off+1]) << 8 | UInt32(data[off+2]) << 16 | UInt32(data[off+3]) << 24)
                let compressedData = data.subdata(in: (off+4)..<(off+4+sz))
                let decompressed = [UInt8](DagDBSnapshot.zlibDecompress(compressedData, expectedSize: nodeCount))

                let isKF = next == 0 || (keyframeInterval > 0 && next % keyframeInterval == 0)
                if isKF {
                    currentFrame = decompressed
                } else {
                    for j in 0..<nodeCount {
                        currentFrame[j] = currentFrame[j] ^ decompressed[j]
                    }
                }
                currentIndex = next
            }

            return currentFrame
        }

        /// Reconstruct full DagDBState at a given frame.
        public func state(at index: Int, width: Int, height: Int) -> DagDBState {
            var s = DagDBState(width: width, height: height)
            let truth = truthState(at: index)
            for i in 0..<min(nodeCount, s.nodeCount) {
                s.truthState[i] = truth[i]
                s.rank[i] = rank[i]
                s.lut6Low[i] = lut6Low[i]
                s.lut6High[i] = lut6High[i]
                s.nodeType[i] = nodeType[i]
            }
            return s
        }

    }

    enum DeltaError: Error {
        case invalidFormat
        case invalidMagic
    }
}
