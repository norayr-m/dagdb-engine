/// DagDBCommandHandler+EngineG — the selection writers: `SET_LUTS … FILL | MAP [MASK]` by
/// selection; the work is the engine's (DagDBEngine+SetLuts.swift); and
/// `SET_TRUTH … FILL` by selection (DagDBEngine+SetTruthFill.swift).

import Foundation
import DagDB

extension DagDBCommandHandler {

    // MARK: - SET_LUTS by selection

    /// Validate (the selection in TRUTH_SLICE's words, MAP's pair rules), log, write.
    /// A LUT write moves no rank, slot, back edge or truth byte: the DAG
    /// verdict, the frontier index, the GPU latch's plan and the (truth, rank) index stay
    /// (`keepsDagShape` names the verb; nothing here marks anything dirty).
    func setLuts(_ sel: DagDBEngine.LutSelection, _ op: DagDBEngine.LutOp) -> String {
        if let r = DagDBEngine.setLutsRefusal(sel, op, nodeCount: nodeCount) {
            return "ERROR \(r.category): \(r.detail)" + (r.selection ? "" : "; nothing written")
        }
        // Log-first: the record before the lane is touched.
        if let wal = walAppender {
            do { _ = try wal.setLuts(sel, op) }
            catch { return walAppendError(error) }
        }
        engine.clearGPUFailure()
        do {
            let r = try engine.setLuts(sel, op)
            return "OK SET_LUTS nodes=\(r.selected) written=\(r.written)"
        } catch let f as DagDBEngine.CommandBufferFailure {
            // The rule for a command buffer that did not complete: named, nothing claimed.
            return "ERROR gpu: SET_LUTS: \(Reply.errorWords(f)); nothing claimed, the LUT lane may hold part of that command buffer's writes"
                + (walAppender != nil ? "; the WAL record stands (replay applies the verb whole)" : "")
        } catch {
            return Reply.errorLine("bad_value", verb: "SET_LUTS", error)     // the refusals were checked above
        }
    }

    // MARK: - SET_TRUTH … FILL by selection

    /// Validate (the selection in TRUTH_SLICE's words; a value ≥ 3 on a graph with a
    /// ternary node, by name), log, write. A truth write: the (truth, rank)
    /// index is dirtied when a node was written; it moves no rank, slot, back
    /// edge or LUT, so the DAG verdict, the frontier index, the GPU latch's plan and the
    /// rank topology stay (`keepsDagShape` names the verb).
    func setTruthFill(_ sel: DagDBEngine.LutSelection, _ v: UInt8) -> String {
        if let r = DagDBEngine.setTruthFillRefusal(sel, v, nodeCount: nodeCount, nonBinaryNodes: engine.nonBinaryNodeCount) {
            return r.value ? ternaryRefusal("SET_TRUTH FILL \(v): \(r.detail)") + "; nothing written"
                           : "ERROR \(r.category): \(r.detail)"
        }
        // Log-first: the record before the lane is touched.
        if let wal = walAppender {
            do { _ = try wal.setTruthFill(sel, v) }
            catch { return walAppendError(error) }
        }
        do {
            let r = try engine.setTruthFill(sel, v)
            if r.selected > 0 { truthRankIndex.markDirty() }
            return "OK SET_TRUTH nodes=\(r.selected) truth=\(v)"
        } catch {
            return Reply.errorLine("bad_value", verb: "SET_TRUTH", error)     // the refusals were checked above
        }
    }
}
