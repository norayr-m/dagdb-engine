import Foundation

// MARK: - An input verb reads only a frame its client wrote, for it
//
// Client_protocol 2, the verb-bound mark. The 14 verbs that read their input from the
// shm (the seven nodeCount-sized bulk installers, TTABLE_BULK,
// CONNECT_BACK_BULK, SET_TRUTH_BULK, XCONV CHECK, XCONV SEALED, BUDGET OPEN,
// BANK GENERATE, BANK FIT) read a client frame: `[u32 count][u32 0x314D4800 | v]`
// at bytes 0..7, v the code of the one verb that may read it, the payload at 8.
//
// No daemon write can leave a mark: every writer stores the header first,
// and the word1 values it stores are {0, 1, 2, 4, 8, 16, 24, 40}, all below
// 256, while every mark is at least 0x314D4801.
// Daemon start leaves (0, 0). So a frame that carries a verb's mark was
// written by a client after the daemon's last write, for that verb: a result
// left in place is refused by name instead of being read as input, and so is
// a frame another verb has read. The mark survives commands that write no
// shm, so a client may resend a frame it edited in place to the same verb.

extension DagDBCommandHandler {

    /// The 14 input verbs and their codes.
    enum InputVerb: UInt32, CaseIterable {
        case setRanksBulk = 1
        case setLutsBulk = 2
        case setNeighborsBulk = 3
        case setModesBulk = 4
        case setTTableIdsBulk = 5
        case setThreshBulk = 6
        case ttableBulk = 7
        case connectBackBulk = 8
        case setTruthBulk = 9
        case xconvCheck = 10
        case xconvSealed = 11
        case budgetOpen = 12
        case bankGenerate = 13
        case bankFit = 14

        /// The verb as its refusals name it.
        var name: String {
            switch self {
            case .setRanksBulk: return "SET_RANKS_BULK"
            case .setLutsBulk: return "SET_LUTS_BULK"
            case .setNeighborsBulk: return "SET_NEIGHBORS_BULK"
            case .setModesBulk: return "SET_MODES_BULK"
            case .setTTableIdsBulk: return "SET_TTABLE_IDS_BULK"
            case .setThreshBulk: return "SET_THRESH_BULK"
            case .ttableBulk: return "TTABLE_BULK"
            case .connectBackBulk: return "CONNECT_BACK_BULK"
            case .setTruthBulk: return "SET_TRUTH_BULK"
            case .xconvCheck: return "XCONV CHECK"
            case .xconvSealed: return "XCONV SEALED"
            case .budgetOpen: return "BUDGET OPEN"
            case .bankGenerate: return "BANK GENERATE"
            case .bankFit: return "BANK FIT"
            }
        }

        /// word1 of a frame for this verb: 0x314D4800 | v.
        var mark: UInt32 { DagDBCommandHandler.shm1MarkBase | rawValue }

        /// The mark as the refusals print it: `0x314D48`, then v in two uppercase hex digits.
        var markText: String { String(format: "0x%08X", mark) }
    }

    /// The bytes 0x00 'H' 'M' '1' (little-endian), every mark's upper three;
    /// the low byte of a mark is its verb's code.
    public static let shm1MarkBase: UInt32 = 0x314D_4800

    /// The client protocol this daemon speaks; STATUS ends with it.
    public static let clientProtocol = 2

    /// The check every input verb runs immediately before its read, after
    /// every check that runs before the read (for CONNECT_BACK_BULK and
    /// SET_TRUTH_BULK, whose count is word0 itself, first, in the old
    /// row-size check's place). `count` is the number of elements the verb
    /// reads, in its unit. Returns the refusal line, or nil when bytes 0..7
    /// hold `[count][verb.mark]`: the u32 range, then the mark (a frame marked
    /// for another verb is named; anything else is the missing-mark line),
    /// then the count. A refusal writes nothing and logs nothing.
    func shm1FrameRefusal(_ verb: InputVerb, count: Int) -> String? {
        guard count >= 0, count <= Int(UInt32.max) else {
            return "ERROR out_of_range: \(verb.name) reads \(count) elements; a frame's u32 count holds at most "
                + "\(UInt32.max); nothing written"
        }
        let w0 = shmBase.load(fromByteOffset: 0, as: UInt32.self)
        let w1 = shmBase.load(fromByteOffset: 4, as: UInt32.self)
        guard w1 == verb.mark else {
            if w1 & 0xFFFF_FF00 == Self.shm1MarkBase, let other = InputVerb(rawValue: w1 & 0xFF) {
                return "ERROR stale_frame: \(verb.name) reads a client frame, and this one is marked for \(other.name); "
                    + "write [u32 count][u32 \(verb.markText)] at bytes 0..7, then the payload at 8; nothing written"
            }
            return "ERROR stale_frame: \(verb.name) reads a client frame; the shm header is (\(w0), \(w1)), "
                + "not (\(count), \(verb.markText)): write [u32 count][u32 \(verb.markText)] at bytes 0..7, "
                + "then the payload at 8; nothing written"
        }
        guard Int(w0) == count else {
            return "ERROR bad_value: \(verb.name) frame count \(w0), the verb reads \(count); nothing written"
        }
        return nil
    }

    /// The frame check's own count arithmetic, overflow-reporting: the expected count a·b, plus c when given (BANK
    /// GENERATE K·M, XCONV SEALED 2n, BUDGET OPEN p·t + c), or, when it
    /// overflows Int, the refusal by name instead of a trap.
    enum ExpectedCount: Equatable {
        case count(Int)
        case refused(String)
    }

    static func shm1ExpectedCount(_ verb: InputVerb, _ a: Int, times b: Int, plus c: Int? = nil) -> ExpectedCount {
        let product = a.multipliedReportingOverflow(by: b)
        var count = product.partialValue, over = product.overflow
        if let c = c, !over {
            let sum = count.addingReportingOverflow(c)
            count = sum.partialValue; over = sum.overflow
        }
        guard !over else {
            let expr = "\(a)*\(b)" + (c.map { "+\($0)" } ?? "")
            return .refused("ERROR out_of_range: \(verb.name) frame count \(expr) overflows Int; nothing written")
        }
        return .count(count)
    }

    /// The frame check of a verb whose expected count is a·b (+ c): the count
    /// computed with its overflow reported, then `shm1FrameRefusal`.
    func shm1FrameRefusal(_ verb: InputVerb, _ a: Int, times b: Int, plus c: Int? = nil) -> String? {
        switch Self.shm1ExpectedCount(verb, a, times: b, plus: c) {
        case .refused(let r): return r
        case .count(let n): return shm1FrameRefusal(verb, count: n)
        }
    }
}
