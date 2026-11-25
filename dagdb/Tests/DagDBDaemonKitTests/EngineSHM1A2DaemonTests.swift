import XCTest
@testable import DagDB
@testable import DagDBDaemonKit

/// The verb-bound mark. A client
/// frame's word1 is 0x314D4800 | v, v the code of the one verb that may read
/// it, so a frame serves only its own verb. The replies are written here from
/// their specified text, never read from the code under test:
///   - a frame marked for another verb: `ERROR stale_frame: <VERB> reads a
///     client frame, and this one is marked for <OTHER>; write [u32 count][u32
///     0x314D48<VV>] at bytes 0..7, then the payload at 8; nothing written`;
///   - no mark: `ERROR stale_frame: <VERB> reads a client frame; the shm header
///     is (<w0>, <w1>), not (<count>, 0x314D48<VV>): write [u32 count][u32
///     0x314D48<VV>] at bytes 0..7, then the payload at 8; nothing written`.
/// VV is the code of <VERB>, two uppercase hex digits.
///
/// Every ordered pair (V1, V2) of distinct input verbs, 14 × 13 = 182,
/// on the graph of `EngineE1DaemonTests` at 24², binary and ternary (the main legs at daemon start:
/// the kernel, the K = 6, T = 64 bank, a one-table library). The client writes
/// a correct frame for V1, V1 is sent and answers OK, then V2 is sent without
/// a rewrite. V2 answers the line naming V1; after BANK GENERATE and BANK FIT,
/// whose output is a daemon write with header (64, 4) and (6, 4), the
/// missing-mark line carrying that header. The state, the WAL
/// and the buffer are unchanged by V2.
extension EngineSHM1DaemonTests {

    /// 0x314D48<VV> for the verb, from the test-side codes.
    static func a2Hex(_ verb: String) -> String {
        String(format: "0x314D48%02X", SHM1Verb.named(verb).rawValue)
    }

    static func a2CrossVerb(_ verb: String, _ other: String) -> String {
        "ERROR stale_frame: \(verb) reads a client frame, and this one is marked for \(other); "
            + "write [u32 count][u32 \(a2Hex(verb))] at bytes 0..7, then the payload at 8; nothing written"
    }

    static func a2Missing(_ verb: String, _ w0: UInt32, _ w1: UInt32, _ count: Int) -> String {
        "ERROR stale_frame: \(verb) reads a client frame; the shm header is (\(w0), \(w1)), not (\(count), \(a2Hex(verb))): "
            + "write [u32 count][u32 \(a2Hex(verb))] at bytes 0..7, then the payload at 8; nothing written"
    }

    struct A2Tally {
        var cells = 0, green = 0, accepted = 0, otherReply = 0, changed = 0, v1Refused = 0
        var bankCells = 0, bankGreen = 0
        var acceptedPairs: [String] = []
        var line: String {
            "cells=\(cells) green=\(green) red=\(cells - green) (V2 accepted \(accepted), other reply \(otherReply), "
                + "state/WAL/shm changed \(changed), V1 not OK \(v1Refused)); after BANK GENERATE/FIT \(bankCells) cells, green \(bankGreen)"
        }
    }

    /// The header V1's output leaves on the fixture: BANK
    /// GENERATE w00000001 1 writes T·M = 64 f32, BANK FIT writes K = 6.
    static let a2BankHeader: [String: (UInt32, UInt32)] = ["BANK GENERATE": (64, 4), "BANK FIT": (6, 4)]

    func a21(_ make: () throws -> Leg) throws -> A2Tally {
        var t = A2Tally()
        var name = ""
        for i in 0..<14 {
            var leg = try make()
            name = leg.name
            let v1Verb = inputs(leg.f)[i].verb
            /// V1: the client's correct frame, sent; it must answer OK.
            func sendV1(_ leg: Leg) -> Bool {
                let v1 = inputs(leg.f)[i]
                v1.write()
                let r = leg.f.handler.handle(v1.line)
                if r.hasPrefix("OK") { return true }
                XCTFail("verb-bound mark \(leg.name): V1 \(v1.verb) did not answer OK on its own frame: \(r.prefix(150))")
                return false
            }
            guard sendV1(leg) else { t.v1Refused += 1; t.cells += 13; continue }
            for j in 0..<14 where j != i {
                let v2 = inputs(leg.f)[j]
                let (w0, w1) = Self.header(leg.f.shm)
                let before = snap(leg.f, leg.walPath)
                let reply = leg.f.handler.handle(v2.line)
                let after = snap(leg.f, leg.walPath)
                let want: String
                if let bh = Self.a2BankHeader[v1Verb] {
                    t.bankCells += 1
                    want = Self.a2Missing(v2.verb, bh.0, bh.1, v2.framed ? Int(bh.0) : v2.count)
                } else {
                    want = Self.a2CrossVerb(v2.verb, v1Verb)
                }
                t.cells += 1
                let same = after == before
                if reply == want && same {
                    t.green += 1
                    if Self.a2BankHeader[v1Verb] != nil { t.bankGreen += 1 }
                    continue
                }
                if reply.hasPrefix("OK") {
                    t.accepted += 1; t.acceptedPairs.append("\(v1Verb) -> \(v2.verb)")
                } else { t.otherReply += 1 }
                if !same { t.changed += 1 }
                XCTFail("verb-bound mark \(leg.name): \(v2.verb) after \(v1Verb), header (\(w0), \(w1)): '\(reply.prefix(170))'"
                        + (same ? "" : "; the state, the WAL or the buffer changed"))
                // An accepted or state-changing V2 leaves another graph or buffer: a fresh fixture, V1 again.
                if reply.hasPrefix("OK") || !same {
                    leg = try make()
                    guard sendV1(leg) else { t.v1Refused += 1; break }
                }
            }
        }
        print("SHM1 A2.1 \(name): \(t.line)")
        print("SHM1 A2.1 \(name) V2 accepted, by pair: \(t.acceptedPairs)")
        return t
    }

    // MARK: - Every ordered pair of input verbs

    func testA2_1EveryOrderedPairOfInputVerbsE1Binary() throws {
        let t = try a21 { try self.mainLeg(ternary: false, start: true) }
        XCTAssertEqual(t.cells, 182)
    }

    func testA2_1EveryOrderedPairOfInputVerbsE1Ternary() throws {
        let t = try a21 { try self.mainLeg(ternary: true, start: true) }
        XCTAssertEqual(t.cells, 182)
    }
}
