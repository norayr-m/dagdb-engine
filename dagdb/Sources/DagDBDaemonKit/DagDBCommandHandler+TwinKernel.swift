/// KERNEL / XCONV SEALED verb family — per-path kernel storage and the
/// sealed cross-convolution residual.
///
/// `KERNEL LOAD` follows VIEW LOAD's guardPath-first, validate-before-mint
/// pattern (DagDBCommandHandler+TwinView.swift): `guardPath` rejects
/// traversal/outside-dataRoot paths before any file I/O; `KernelPair.load`
/// then does the real work (SHA check when `SHA <hex>` is given, else the
/// file's own hash is computed and used unchecked) — any `KernelPair.
/// KernelError` (file missing, sha mismatch, malformed layout, a bad
/// kernel shape) becomes `ERROR io:`, never silently accepted. The
/// `TwinOp.kernelLoad` logged to the WAL and applied to `twin` always
/// carries the pair's OWN computed sha256 (not the caller's optional `SHA`
/// argument) — that is the by-reference pin later restore/replay verifies
/// against; τA/τB/σ_source/declaredWarmup are the caller's DECLARED values
/// (never read from the kernels file). Because the pair is already in
/// hand, the custom `kernelLoader` closure passed to `twin.apply` just
/// returns it directly rather than re-reading the file.
///
/// `XCONV SEALED` is the court's fixed residual (the formula in
/// `SealedCrossConvolution.residual`) reached over the socket — it is NOT
/// the standing `XCONV CHECK` patrol check (DagDBCommandHandler+TwinBudget.
/// swift), which stays unchanged (the two are printed side by side by the
/// library's own test, not by this handler). INFO/LIST are pure reads; CLOSE logs `.close` first, like
/// every other twin CLOSE verb.
import Foundation
import DagDB

extension DagDBCommandHandler {
    func handleTwinKernel(_ cmd: TwinCommand, sessionId: String?) -> String {
        switch cmd {

        case .kernelLoad(let path, let shaArg, let tauA, let tauB, let sigmaSource, let declaredWarmup):
            if let err = guardPath(path) { return err }
            // The count cap, then the load's peak by the file's size (3.5-5.1 x the file).
            if let e = alloc1bTwinCap("KERNEL LOAD", prefix: "k") { return e }
            // Admitted on the opened file's st_size (see ALARM LOAD's note).
            // The one JSON pair (see ALARM LOAD's note); a flat 1.1*(4.2*file + 64 KiB) was broken by 2.32x.
            let admitKernel: (Int) -> String? = { [unowned self] fb in
                self.admit("KERNEL LOAD", bytes: Self.newBytes(Self.alloc1bMargin * AdmissionCharge.jsonRead(fileBytes: fb)),
                           what: "the file's read, 1.1*2.52 B per byte for \(fb) B")
            }
            let parseKernel: (Data) -> String? = { [unowned self] d in self.jsonParseAdmission("KERNEL LOAD", d) }
            let loaded: (pair: KernelPair, sha256: String)
            do {
                loaded = try KernelPair.load(path: path, expectedSHA256: shaArg, tauA: tauA, tauB: tauB,
                                              sigmaSource: sigmaSource, declaredWarmup: declaredWarmup,
                                              admit: admitKernel, admitParse: parseKernel)
            } catch DaemonFile.Refusal.admission(let line) {
                return line
            } catch {
                return kernelLoadErrorLine(error)
            }
            // The throwing door, BEFORE the id is minted and the op
            // reaches the WAL: a resolved warmup that leaves no comparison
            // window must not install a kernel the daemon then reports on.
            let resolved: (value: Int, derived: Bool)?
            do {
                resolved = try loaded.pair.checkedWarmup(override: nil)
            } catch {
                return kernelWarmupRefusal("KERNEL LOAD", error)
            }

            let id = twin.nextId(prefix: "k")
            let op = TwinOp.kernelLoad(id: id, path: path, sha256: loaded.sha256, tauA: tauA, tauB: tauB,
                                        sigmaSource: sigmaSource, declaredWarmup: declaredWarmup)
            if let err = appendTwinWAL(op) { return err }
            do {
                try twin.apply(op, kernelLoader: { _ in loaded.pair })
            } catch { return kernelStateErrorLine(error) }

            let warmupStr = resolved.map { "\($0.value)" } ?? "none"
            let derivedStr = (resolved?.derived ?? false) ? "1" : "0"
            return twinResponse(
                "KERNEL LOAD", sessionId: sessionId,
                "id=\(id) taps=\(loaded.pair.taps) fs=\(formatKernelFS(loaded.pair.meta.fs)) " +
                "window=\(loaded.pair.meta.window) ears=\(loaded.pair.meta.earA)/\(loaded.pair.meta.earB) " +
                "warmup=\(warmupStr) derived=\(derivedStr) sha256=\(loaded.sha256)"
            )

        case .xconvSealed(let id, let n, let warmupOverride):
            guard n >= 2 else { return "ERROR out_of_range: n must be >= 2" }
            guard let set = twin.kernels.get(id) else { return "ERROR not_found: \(Reply.quoted(id))" }
            let pair = set.pair
            // `2 * n * 8` traps on overflow before this guard can fire.
            guard let inputBytes = checkedProduct(2, n, 8).flatMap({ checkedSum(8, $0) }) else {
                return overflowRefusal("XCONV SEALED input", "n=\(n)")
            }
            guard inputBytes <= shmCapacityBytes else {
                return "ERROR out_of_range: XCONV SEALED input \(inputBytes) bytes exceeds shm capacity \(shmCapacityBytes)"
            }
            // The same door on the override path: a warmup at or above
            // `window_samples` was silently clamped downstream.
            let resolvedOpt: (value: Int, derived: Bool)?
            do {
                resolvedOpt = try pair.checkedWarmup(override: warmupOverride)
            } catch {
                return kernelWarmupRefusal("XCONV SEALED", error)
            }
            guard let resolved = resolvedOpt else {
                return "ERROR bad_value: warmup: neither derived (TAU/SIGMA) nor declared"
            }
            guard resolved.value < n else {
                return "ERROR out_of_range: warmup \(resolved.value) must be < n \(n)"
            }
            guard let bOffset = checkedProduct(n, 8).flatMap({ checkedSum(8, $0) }) else {
                return overflowRefusal("XCONV SEALED input", "n=\(n)")
            }
            // 2n f64 (a, then b), after every check above; the count overflow-reporting.
            if let r = shm1FrameRefusal(.xconvSealed, 2, times: n) { return r }
            guard let a = readDoubles(count: n, at: 8),
                  let b = readDoubles(count: n, at: bOffset) else {
                return "ERROR out_of_range: XCONV SEALED input \(inputBytes) bytes exceeds shm capacity \(shmCapacityBytes)"
            }
            let result = SealedCrossConvolution.residual(a: a, b: b, pair: pair, warmup: resolved.value)
            return twinResponse(
                "XCONV SEALED", sessionId: sessionId,
                "id=\(id) n=\(n) warmup=\(resolved.value) derived=\(resolved.derived ? 1 : 0) " +
                "residual=\(result.residual) compared=\(n - resolved.value)"
            )

        case .kernelInfo(let id):
            guard let set = twin.kernels.get(id) else { return "ERROR not_found: \(Reply.quoted(id))" }
            let pair = set.pair
            let resolved: (value: Int, derived: Bool)?
            do {
                resolved = try pair.checkedWarmup(override: nil)
            } catch {
                return kernelWarmupRefusal("KERNEL INFO", error)
            }
            let warmupStr = resolved.map { "\($0.value)" } ?? "none"
            let derivedStr = (resolved?.derived ?? false) ? "1" : "0"
            let tauAStr = pair.meta.tauA.map { "\($0)" } ?? "none"
            let tauBStr = pair.meta.tauB.map { "\($0)" } ?? "none"
            let sigmaStr = pair.meta.sigmaSource.map { "\($0)" } ?? "none"
            return twinResponse(
                "KERNEL INFO", sessionId: sessionId,
                "id=\(id) path=\(Reply.quoted(set.ref.path)) sha256=\(set.ref.sha256) taps=\(pair.taps) " +
                "fs=\(formatKernelFS(pair.meta.fs)) window=\(pair.meta.window) " +
                "ears=\(pair.meta.earA)/\(pair.meta.earB) tau_a=\(tauAStr) tau_b=\(tauBStr) sigma=\(sigmaStr) " +
                "warmup=\(warmupStr) derived=\(derivedStr)"
            )

        case .kernelList:
            let ids = twin.kernels.ids.sorted()
            return twinResponse("KERNEL LIST", sessionId: sessionId, "count=\(ids.count)\(idsSuffixKernel(ids))")

        case .kernelClose(let id):
            guard twin.kernels.get(id) != nil else { return "ERROR not_found: \(Reply.quoted(id))" }
            let op = TwinOp.close(id: id)
            if let err = appendTwinWAL(op) { return err }
            do { try twin.apply(op) } catch { return kernelStateErrorLine(error) }
            return twinResponse("KERNEL CLOSE", sessionId: sessionId, "id=\(id)")

        default:
            // Every case this family handler is dispatched (see handleTwin
            // in DagDBCommandHandler+Twin.swift) is covered above; this
            // branch exists only for switch exhaustiveness.
            return "ERROR unknown_command: twin verb not wired yet"
        }
    }

    // MARK: - fs formatting

    /// `KernelPair.Meta.fs` is a Double but every kernels fixture's sample
    /// rate is a whole number of Hz (3000) — printed without a trailing
    /// ".0" when it round-trips through Int exactly, else with full Double
    /// precision (never silently truncated).
    ///
    /// fs comes from the kernels file KERNEL LOAD
    /// names (KernelPair refuses only a non-finite one), and `Int(v)` trapped
    /// on a whole number outside Int (fs 1e300 killed the KERNEL LOAD and
    /// KERNEL INFO replies). The conversion is exact or not taken: such an fs
    /// prints as the Double it is, like every fs that is not a whole number.
    private func formatKernelFS(_ v: Double) -> String {
        guard v.isFinite, v == v.rounded(), let i = Int(exactly: v) else { return "\(v)" }
        return "\(i)"
    }

    // MARK: - Error formatting

    /// `KernelPair.KernelError` (file missing, sha mismatch, malformed
    /// layout, a bad kernel shape) always maps to `ERROR io:` — every
    /// kernel-load failure is an I/O-layer finding, never silently accepted
    /// (mirrors VIEW LOAD's contract). The sha-mismatch line always
    /// contains the literal phrase "sha256 mismatch".
    private func kernelLoadErrorLine(_ error: Error) -> String {
        if let e = error as? KernelPair.KernelError {
            switch e {
            case .fileNotFound(let p):
                return "ERROR io: file not found: \(Reply.quoted(p))"
            case .shaMismatch(let expected, let actual):
                return "ERROR io: sha256 mismatch: expected \(Reply.quoted(expected)) actual \(actual)"
            case .badLayout(let reason):
                return "ERROR io: bad layout: \(reason)"
            case .badKernel(let reason):
                return "ERROR io: bad kernel: \(reason)"
            }
        }
        return Reply.errorLine("io", error)
    }

    /// `KernelPair.checkedWarmup`'s refusal on the wire. It is a
    /// validating front door catching what used to be a silent clamp, so it
    /// carries `bad_value` like every other such door. Reachable today only
    /// from `XCONV SEALED`'s override: `KernelPair.load` runs the same check
    /// itself, so a pair in the registry has already passed it and the
    /// `KERNEL LOAD` / `KERNEL INFO` uses are defence in depth.
    private func kernelWarmupRefusal(_ verb: String, _ error: Error) -> String {
        if let e = error as? KernelPair.KernelError, case .badLayout(let why) = e {
            return "ERROR bad_value: \(verb) refused: \(why)"
        }
        return "ERROR bad_value: \(verb) refused: \(Reply.errorWords(error))"
    }

    /// `TwinState.TwinError` renders via its own `description`; kept as a
    /// file-local twin (see DagDBCommandHandler+TwinAlarm.swift's
    /// `twinStateErrorLine`) since `private` helpers in another extension
    /// file aren't visible here.
    private func kernelStateErrorLine(_ error: Error) -> String {
        if let e = error as? TwinState.TwinError {
            switch e {
            case .notFound(let s): return "ERROR not_found: \(Reply.quoted(s))"
            case .badId(let s): return "ERROR bad_value: \(Reply.quoted(s))"
            case .badValue(let s): return "ERROR bad_value: \(s)"
            case .schema(let s): return "ERROR schema: \(s)"
            case .io(let s): return "ERROR io: \(s)"
            }
        }
        return Reply.errorLine("io", error)
    }

    private func idsSuffixKernel(_ ids: [String]) -> String {
        ids.isEmpty ? "" : " " + ids.joined(separator: " ")
    }
}
