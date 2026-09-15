/// BANK verb family — spec 8, the waveform mouth (interface phase, 2026-09). One frozen
/// WaveBank Φ per open bank; generation is a single matrix product
/// (`WaveBank.generate`), fit is a least-squares solve (`WaveBank.fit`),
/// noise/bench are the frozen-bank diagnostics from spec 8's gates.
///
/// OPEN follows the same WAL-first pattern as STREAM/RECORD/BUDGET
/// (DagDBCommandHandler+TwinStreams.swift, +TwinBudget.swift): validate the
/// spec via `WaveBank.validationError` → mint an id via `twin.nextId(prefix:)`
/// → `appendTwinWAL` (abort on failure) → `twin.apply` → `OK …`. GENERATE and
/// FIT never mutate the twin registries — they write shm only, the same
/// read-only class as `RECORD REPLAY`. NOISE/BENCH/INFO/LIST are pure reads;
/// CLOSE logs `.close` first, like every other twin CLOSE verb.
import Foundation
import Dispatch
import DagDB

extension DagDBCommandHandler {
    func handleTwinBank(_ cmd: TwinCommand, sessionId: String?) -> String {
        switch cmd {

        case .bankOpen(let name, let specIn, let aliased):
            // No spec given ⇒ the repaired bank (amendment 2 (d) — this
            // amends the earlier K=160 default to K=144).
            let spec = specIn ?? WaveBank.Spec.referenceNyquistSafe
            if let err = WaveBank.validationError(spec) {
                return "ERROR bad_value: \(err)"
            }
            // Nyquist refusal (G8(c)): the operator must write ALIASED to
            // open a spec whose top harmonic reaches/exceeds Nyquist. The
            // library itself builds either spec unconditionally (the
            // control fixture must stay buildable) — only the daemon gates.
            if !aliased, let violation = WaveBank.aliasingViolation(spec) {
                return "ERROR bad_value: \(violation)"
            }
            let id = twin.nextId(prefix: "w")
            let op = TwinOp.bankOpen(id: id, name: name, spec: spec)
            if let err = appendTwinWAL(op) { return err }
            // An op that reached the WAL was already allowed at write time
            // (validation + aliasing check both passed above) — replay
            // applies it unconditionally, without re-checking aliasing.
            do { try twin.apply(op) } catch { return twinBankErrorLine(error) }
            guard let entry = twin.banks.get(id) else {
                return "ERROR io: bank \(id) missing immediately after apply"
            }
            let K = spec.atomCount
            let decl: WaveBank.Declaration
            let deficient: Bool
            switch checkedDeclaration(entry.bank) {
            case .refused(let why): return "ERROR bad_value: BANK OPEN refused: \(why)"
            case .declared(let d, let rankDeficient): decl = d; deficient = rankDeficient
            }
            return twinResponse(
                "BANK OPEN", sessionId: sessionId,
                "id=\(id) name=\(name) T=\(spec.samples) K=\(K) atoms_bytes=\(spec.samples * K * 4) "
                    + "rank=\(decl.rank) cond=\(String(format: "%.6g", decl.conditionNumber)) "
                    + "rank_deficient=\(deficient ? 1 : 0)"
            )

        case .bankGenerate(let id, let m):
            guard m >= 1 else { return "ERROR out_of_range: M must be >= 1" }
            guard let entry = twin.banks.get(id) else { return "ERROR not_found: \(id)" }
            let bank = entry.bank
            let inputBytes = 8 + bank.K * m * 4
            guard inputBytes <= shmCapacityBytes else {
                return "ERROR out_of_range: BANK GENERATE input \(inputBytes) bytes exceeds shm capacity \(shmCapacityBytes)"
            }
            let outputBytes = 8 + bank.T * m * 4
            guard outputBytes <= shmCapacityBytes else {
                return "ERROR out_of_range: BANK GENERATE output \(outputBytes) bytes exceeds shm capacity \(shmCapacityBytes)"
            }
            guard let coefficients = readFloats(count: bank.K * m, at: 8) else {
                return "ERROR out_of_range: BANK GENERATE input \(inputBytes) bytes exceeds shm capacity \(shmCapacityBytes)"
            }
            let start = DispatchTime.now()
            // F5 · alpha's throwing door: a column count above the bank's own
            // ceiling used to come back as an empty vector under an `OK`.
            let w: [Float]
            do {
                w = try bank.generateChecked(coefficients: coefficients, columns: m)
            } catch let e as WaveBank.BankError {
                guard case .badSpec(let why) = e else { return "ERROR bad_value: BANK GENERATE refused: \(e)" }
                return "ERROR bad_value: BANK GENERATE refused: \(why)"
            } catch {
                return "ERROR bad_value: BANK GENERATE refused: \(error)"
            }
            let end = DispatchTime.now()
            let elapsedMs = Double(end.uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000.0
            if let e = writeFloatVector(w) { return e }
            return twinResponse(
                "BANK GENERATE", sessionId: sessionId,
                "id=\(id) T=\(bank.T) M=\(m) samples=\(bank.T * m) elapsed_ms=\(elapsedMs)"
            )

        case .bankFit(let id):
            guard let entry = twin.banks.get(id) else { return "ERROR not_found: \(id)" }
            let bank = entry.bank
            let inputBytes = 8 + bank.T * 4
            guard inputBytes <= shmCapacityBytes else {
                return "ERROR out_of_range: BANK FIT input \(inputBytes) bytes exceeds shm capacity \(shmCapacityBytes)"
            }
            guard let x = readFloats(count: bank.T, at: 8) else {
                return "ERROR out_of_range: BANK FIT input \(inputBytes) bytes exceeds shm capacity \(shmCapacityBytes)"
            }
            guard let fit = bank.fit(x) else {
                return "ERROR io: BANK FIT did not converge"
            }
            if let e = writeFloatVector(fit.coefficients) { return e }
            return twinResponse(
                "BANK FIT", sessionId: sessionId,
                "id=\(id) residual=\(fit.residual) norm=\(fit.targetNorm) coefficients=\(fit.coefficients.count)"
            )

        case .bankNoise(let id, let seed, let n):
            // D1 · `seed` is consumed by `for _ in 0..<seed { stream.next64() }`
            // — every sibling knob here is bounded; this one was not (finding 21).
            if let e = checkCap("seed", seed, 0, DagDBCommandHandler.bankNoiseSeedCap) { return e }
            guard n >= 1 && n <= 200 else { return "ERROR out_of_range: n must be in [1, 200]" }
            guard let entry = twin.banks.get(id) else { return "ERROR not_found: \(id)" }
            var stream = NamedStream(
                name: "noise",
                stateHi: 0x853c_49e6_748f_ea9b, stateLo: 0xda3e_39cb_94b9_5bdb,
                incHi: 0x5851_f42d_4c95_7f2d, incLo: 0x1405_7b7e_f767_814f
            )
            for _ in 0..<seed { _ = stream.next64() }
            let law = entry.bank.noiseLaw(seeds: n, stream: stream)
            return twinResponse(
                "BANK NOISE", sessionId: sessionId,
                "id=\(id) n=\(n) expected=\(law.expected) mean=\(law.mean) min=\(law.min) max=\(law.max)"
            )

        case .bankBench(let id, let m, let reps):
            guard m >= 1 && m <= 100_000 else { return "ERROR out_of_range: M must be in [1, 100000]" }
            guard reps >= 1 && reps <= 20 else { return "ERROR out_of_range: reps must be in [1, 20]" }
            guard let entry = twin.banks.get(id) else { return "ERROR not_found: \(id)" }
            let bench = entry.bank.bench(columns: m, reps: reps)
            return twinResponse(
                "BANK BENCH", sessionId: sessionId,
                "id=\(id) M=\(bench.columns) reps=\(bench.reps) best_ms=\(bench.bestSeconds * 1000.0) samples_per_s=\(bench.samplesPerSecond)"
            )

        case .bankInfo(let id):
            guard let entry = twin.banks.get(id) else { return "ERROR not_found: \(id)" }
            let spec = entry.bank.spec
            let decl: WaveBank.Declaration
            let deficient: Bool
            switch checkedDeclaration(entry.bank) {
            case .refused(let why): return "ERROR bad_value: BANK INFO refused: \(why)"
            case .declared(let d, let rankDeficient): decl = d; deficient = rankDeficient
            }
            return twinResponse(
                "BANK INFO", sessionId: sessionId,
                "id=\(id) name=\(entry.name) T=\(spec.samples) fs=\(spec.sampleRate) f0=\(spec.f0) "
                    + "H=\(spec.harmonics) centers=\(spec.gaborCenters) freqs=\(spec.gaborFreqs) "
                    + "sigma_frac=\(spec.gaborSigmaFrac) K=\(entry.bank.K) "
                    + "rank=\(decl.rank) cond=\(String(format: "%.6g", decl.conditionNumber)) "
                    + "rank_deficient=\(deficient ? 1 : 0)"
            )

        case .bankList:
            let ids = twin.banks.ids.sorted()
            let idsSuffix = ids.isEmpty ? "" : " " + ids.joined(separator: " ")
            return twinResponse("BANK LIST", sessionId: sessionId, "count=\(ids.count)\(idsSuffix)")

        case .bankClose(let id):
            guard twin.banks.get(id) != nil else { return "ERROR not_found: \(id)" }
            let op = TwinOp.close(id: id)
            if let err = appendTwinWAL(op) { return err }
            do { try twin.apply(op) } catch { return twinBankErrorLine(error) }
            return twinResponse("BANK CLOSE", sessionId: sessionId, "id=\(id)")

        default:
            // Every case this family handler is dispatched (see handleTwin
            // in DagDBCommandHandler+Twin.swift) is covered above; this
            // branch exists only for switch exhaustiveness.
            return "ERROR unknown_command: twin verb not wired yet"
        }
    }

    /// F5 · the declaration through alpha's throwing door, with one
    /// deliberate split.
    ///
    /// `declarationChecked()` refuses two different things: a LAPACK failure
    /// or a literally zero / non-finite smallest singular value (which
    /// `declaration()` itself already reports in its `refusal` field — the
    /// printed numbers mean nothing, and that refusal belongs on the wire),
    /// and, more strictly, ANY bank whose smallest singular value sits at or
    /// below the rank threshold. The second is not an error here: the sealed
    /// 160-atom control bank is deliberately rank deficient (146 of 160) and
    /// its printed `rank=146` is a frozen gate. So the first is refused and
    /// the second is DISCLOSED as `rank_deficient=1`.
    enum CheckedDeclaration {
        case declared(WaveBank.Declaration, rankDeficient: Bool)
        case refused(String)
    }

    /// The door is tried FIRST and its own return value is used, so the
    /// ordinary path pays for exactly one SVD — `declaration()` recomputes
    /// rank and condition number on every call (about 10 ms at 4096x160),
    /// and calling both unconditionally would have doubled that on two
    /// verbs. Only a bank the door refuses is read a second time, to tell
    /// the two kinds of refusal apart.
    func checkedDeclaration(_ bank: WaveBank) -> CheckedDeclaration {
        do {
            return .declared(try bank.declarationChecked(), rankDeficient: false)
        } catch {
            let decl = bank.declaration()
            if let refusal = decl.refusal { return .refused(refusal) }
            return .declared(decl, rankDeficient: true)
        }
    }

    /// `TwinState.TwinError` renders via its own `description`; any other
    /// thrown error falls back to `ERROR io:`. Duplicated from
    /// +TwinStreams.swift's/+TwinBudget.swift's private `twinErrorLine` —
    /// file-scoped `private` helpers don't cross extension files, and the
    /// twin verb families are parallel-safe disjoint-file tasks (plan
    /// §ordering), so this stays a local copy rather than widening another
    /// task's file.
    private func twinBankErrorLine(_ error: Error) -> String {
        if let e = error as? TwinState.TwinError {
            switch e {
            case .notFound(let s): return "ERROR not_found: \(s)"
            case .badId(let s): return "ERROR bad_value: \(s)"
            case .badValue(let s): return "ERROR bad_value: \(s)"
            case .schema(let s): return "ERROR schema: \(s)"
            case .io(let s): return "ERROR io: \(s)"
            }
        }
        return "ERROR io: \(error)"
    }
}
