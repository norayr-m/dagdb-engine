// Smoke tests for the DagDB 4-cycle engine.
// Real correctness + convergence tests land once the wave algorithms
// are implemented. This file locks in the build shape.

import XCTest
import Metal
@testable import DagDBEngine

final class Engine4CycleTests: XCTestCase {
    func testSingleTickOnTrivialDag() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("no Metal device")
        }
        let identityLUT: UInt64 = 0xAAAA_AAAA_AAAA_AAAA
        let nodes: [DagNode] = [
            DagNode(id: 0, rank: 0,
                    inputs: (-1, -1, -1, -1, -1, -1),
                    lut: identityLUT, state: 1),
            DagNode(id: 1, rank: 1,
                    inputs: (0, -1, -1, -1, -1, -1),
                    lut: identityLUT),
        ]
        let dag    = DagDB(device: device, nodes: nodes, maxRank: 1, queenIdx: 0)
        let engine = try Engine4Cycle(dag: dag)
        let telem  = try engine.tick()
        XCTAssertEqual(telem.epochIndex, 1)
        XCTAssertGreaterThan(telem.wavelinesProcessed, 0)
    }
}
