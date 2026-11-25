/// BANK verb family — the waveform mouth. One frozen
/// WaveBank Φ per open bank; generation is a single matrix product
/// (`WaveBank.generate`), fit is a least-squares solve (`WaveBank.fit`),
/// noise/bench are the frozen-bank diagnostics.
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
            if let e = nameCapRefusal("BANK OPEN", name) { return e }
            // No spec given ⇒ the repaired bank (it replaces the earlier
            // K=160 default with K=144).
            let spec = specIn ?? WaveBank.Spec.referenceNyquistSafe
            if let why = WaveBank.validationError(spec) {
                // The atom count is overflow-reporting inside
                // the validator; that refusal is named in the house form.
                if why == WaveBank.atomCountOverflow(spec) {
                    return "ERROR out_of_range: BANK OPEN \(why); nothing written"
                }
                return "ERROR bad_value: \(why)"
            }
            // Nyquist refusal: the operator must write ALIASED to
            // open a spec whose top harmonic reaches/exceeds Nyquist. The
            // library itself builds either spec unconditionally (the
            // control fixture must stay buildable) — only the daemon gates.
            if !aliased, let violation = WaveBank.aliasingViolation(spec) {
                // A harmonic index fs and f0 make too
                // large for Int (it trapped in the rule) is named in the house form.
                if violation == WaveBank.nyquistIndexOverflow(spec) {
                    return "ERROR out_of_range: BANK OPEN \(violation); nothing written"
                }
                return "ERROR bad_value: \(violation)"
            }
            // The atoms and the declaration's Double copy; the SVD.
            if let e = alloc1bTwinCap("BANK OPEN", prefix: "w") { return e }   // the count cap
            if let e = admitBankSVD("BANK OPEN", T: spec.samples, K: spec.atomCount, bytesPerTK: 12) { return e }
            // The bank is built and its declaration
            // checked BEFORE an id is minted and the WAL written; the built
            // bank is handed to `apply` (as ALARM, VIEW and KERNEL hand in
            // their fixtures). The refusal used to come after the record and
            // the open, leaving the refused bank open under a consumed id.
            let built: WaveBank
            do { built = try WaveBank(spec: spec) } catch { return twinBankErrorLine(TwinState.TwinError.badValue(Reply.errorWords(error))) }
            let K = spec.atomCount
            let decl: WaveBank.Declaration
            let deficient: Bool
            switch checkedDeclaration(built) {
            case .refused(let why): return "ERROR bad_value: BANK OPEN refused: \(why); nothing written"
            case .declared(let d, let rankDeficient): decl = d; deficient = rankDeficient
            }
            let id = twin.nextId(prefix: "w")
            let op = TwinOp.bankOpen(id: id, name: name, spec: spec)
            if let err = appendTwinWAL(op) { return err }
            // An op that reached the WAL was already allowed at write time
            // (validation + aliasing check both passed above) — replay
            // applies it unconditionally, without re-checking aliasing.
            do { try twin.apply(op, bankBuilder: { _ in built }) } catch { return twinBankErrorLine(error) }
            guard twin.banks.get(id) != nil else {
                return "ERROR io: bank \(id) missing immediately after apply"
            }
            return twinResponse(
                "BANK OPEN", sessionId: sessionId,
                "id=\(id) name=\(Reply.quoted(name)) T=\(spec.samples) K=\(K) atoms_bytes=\(spec.samples * K * 4) "
                    + "rank=\(decl.rank) cond=\(String(format: "%.6g", decl.conditionNumber)) "
                    + "rank_deficient=\(deficient ? 1 : 0)"
            )

        case .bankGenerate(let id, let m):
            guard m >= 1 else { return "ERROR out_of_range: M must be >= 1" }
            guard let entry = twin.banks.get(id) else { return "ERROR not_found: \(Reply.quoted(id))" }
            let bank = entry.bank
            // Both byte counts are overflow-reporting; M
            // is a wire Int, and `8 + K * M * 4` trapped before the capacity
            // guard below could refuse it. The shm frame check keeps its place.
            guard let inputBytes = checkedProduct(bank.K, m, 4).flatMap({ checkedSum(8, $0) }) else {
                return "ERROR out_of_range: BANK GENERATE M \(m): input bytes 8 + K*M*4 (K=\(bank.K)) overflow Int;"
                    + " nothing written"
            }
            guard inputBytes <= shmCapacityBytes else {
                return "ERROR out_of_range: BANK GENERATE input \(inputBytes) bytes exceeds shm capacity \(shmCapacityBytes)"
            }
            guard let outputBytes = checkedProduct(bank.T, m, 4).flatMap({ checkedSum(8, $0) }) else {
                return "ERROR out_of_range: BANK GENERATE M \(m): output bytes 8 + T*M*4 (T=\(bank.T)) overflow Int;"
                    + " nothing written"
            }
            guard outputBytes <= shmCapacityBytes else {
                return "ERROR out_of_range: BANK GENERATE output \(outputBytes) bytes exceeds shm capacity \(shmCapacityBytes)"
            }
            if let r = shm1FrameRefusal(.bankGenerate, bank.K, times: m) { return r }   // K·M f32, overflow-reporting
            guard let coefficients = readFloats(count: bank.K * m, at: 8) else {
                return "ERROR out_of_range: BANK GENERATE input \(inputBytes) bytes exceeds shm capacity \(shmCapacityBytes)"
            }
            let start = DispatchTime.now()
            // The throwing door: a column count above the bank's own
            // ceiling used to come back as an empty vector under an `OK`.
            let w: [Float]
            do {
                w = try bank.generateChecked(coefficients: coefficients, columns: m)
            } catch let e as WaveBank.BankError {
                guard case .badSpec(let why) = e else { return Reply.errorLine("bad_value", verb: "BANK GENERATE refused", e) }
                return "ERROR bad_value: BANK GENERATE refused: \(why)"
            } catch {
                return Reply.errorLine("bad_value", verb: "BANK GENERATE refused", error)
            }
            let end = DispatchTime.now()
            let elapsedMs = Double(end.uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000.0
            if let e = writeFloatVector(w) { return e }
            return twinResponse(
                "BANK GENERATE", sessionId: sessionId,
                "id=\(id) T=\(bank.T) M=\(m) samples=\(bank.T * m) elapsed_ms=\(elapsedMs)"
            )

        case .bankFit(let id):
            guard let entry = twin.banks.get(id) else { return "ERROR not_found: \(Reply.quoted(id))" }
            let bank = entry.bank
            let inputBytes = 8 + bank.T * 4
            guard inputBytes <= shmCapacityBytes else {
                return "ERROR out_of_range: BANK FIT input \(inputBytes) bytes exceeds shm capacity \(shmCapacityBytes)"
            }
            if let r = shm1FrameRefusal(.bankFit, count: bank.T) { return r }   // T f32
            if let e = admitBankFit(T: bank.T, K: bank.K) { return e }
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
            // `seed` is consumed by `for _ in 0..<seed { stream.next64() }`
            // — every other knob here was bounded; this one was not.
            if let e = checkCap("seed", seed, 0, DagDBCommandHandler.bankNoiseSeedCap) { return e }
            guard n >= 1 && n <= 200 else { return "ERROR out_of_range: n must be in [1, 200]" }
            guard let entry = twin.banks.get(id) else { return "ERROR not_found: \(Reply.quoted(id))" }
            // One fit's two T x K Double copies; the draws and the fits.
            do {
                let T = AdmitCount(entry.bank.T), K = AdmitCount(entry.bank.K), nn = AdmitCount(n)
                if let e = admit("BANK NOISE", bytes: Self.withByteMargin(AdmitCount(16) * T * K), what: "one fit's two T*K Double copies" + Self.byteMarginWords,
                                 work: [AdmitWork(units: "draws (T*n^2)", needed: T * nn * nn, cap: Self.alloc1aNoiseDrawCap),
                                        AdmitWork(units: "fit units (n*T*K^2)", needed: nn * T * K * K, cap: Self.alloc1aNoiseFitCap)]) {
                    return e
                }
            }
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
            guard let entry = twin.banks.get(id) else { return "ERROR not_found: \(Reply.quoted(id))" }
            // One rep's T x M output and the K x M coefficients; output bytes and flops.
            do {
                let T = AdmitCount(entry.bank.T), K = AdmitCount(entry.bank.K), M = AdmitCount(m), R = AdmitCount(reps)
                let out = AdmitCount(4) * T * M
                // The two figures' sum, with the K*M coefficient draws, in ns.
                let tm = Double(entry.bank.T) * Double(m), km = Double(entry.bank.K) * Double(m)
                let benchNs = Double(reps) * (4 * tm * Self.alloc1aBenchOutputNs + 2 * tm * Double(entry.bank.K) * Self.alloc1aBenchFlopNs)
                    + km * Self.alloc1aNoiseDrawNs
                if let e = admit("BANK BENCH", bytes: Self.withByteMargin(out + AdmitCount(4) * K * M),
                                 what: "one rep's 4*T*M output and the 4*K*M coefficients" + Self.byteMarginWords,
                                 work: [AdmitWork(units: "output bytes (4*T*M x reps)", needed: out * R, cap: Self.alloc1aBenchOutputByteCap),
                                        AdmitWork(units: "flops (reps x 2*T*K*M)", needed: R * AdmitCount(2) * T * K * M,
                                                  cap: Self.alloc1aBenchFlopCap),
                                        AdmitWork(units: "bench work ns (reps x (0.112*4*T*M + 0.000823*2*T*K*M) + 1.805*K*M)",
                                                  needed: Self.nsCount(benchNs), cap: Self.alloc1aBenchWorkCapNs)]) {
                    return e
                }
            }
            let bench = entry.bank.bench(columns: m, reps: reps)
            return twinResponse(
                "BANK BENCH", sessionId: sessionId,
                "id=\(id) M=\(bench.columns) reps=\(bench.reps) best_ms=\(bench.bestSeconds * 1000.0) samples_per_s=\(bench.samplesPerSecond)"
            )

        case .bankInfo(let id):
            guard let entry = twin.banks.get(id) else { return "ERROR not_found: \(Reply.quoted(id))" }
            if let e = admitBankSVD("BANK INFO", T: entry.bank.T, K: entry.bank.K, bytesPerTK: 8) { return e }   // the same SVD; the copy, 8*T*K
            let spec = entry.bank.spec
            let decl: WaveBank.Declaration
            let deficient: Bool
            switch checkedDeclaration(entry.bank) {
            case .refused(let why): return "ERROR bad_value: BANK INFO refused: \(why)"
            case .declared(let d, let rankDeficient): decl = d; deficient = rankDeficient
            }
            return twinResponse(
                "BANK INFO", sessionId: sessionId,
                "id=\(id) name=\(Reply.quoted(entry.name)) T=\(spec.samples) fs=\(spec.sampleRate) f0=\(spec.f0) "
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
            guard twin.banks.get(id) != nil else { return "ERROR not_found: \(Reply.quoted(id))" }
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

    /// The declaration through the throwing `declarationChecked()`, with one
    /// deliberate split.
    ///
    /// `declarationChecked()` refuses two different things: a LAPACK failure
    /// or a literally zero / non-finite smallest singular value (which
    /// `declaration()` itself already reports in its `refusal` field — the
    /// printed numbers mean nothing, and that refusal belongs on the wire),
    /// and, more strictly, ANY bank whose smallest singular value sits at or
    /// below the rank threshold. The second is not an error here: the sealed
    /// 160-atom control bank is deliberately rank deficient (146 of 160) and
    /// its printed `rank=146` is checked by the tests. So the first is refused and
    /// the second is DISCLOSED as `rank_deficient=1`.
    /// BANK OPEN, 12*T*K bytes (the T x K atoms and the
    /// declaration's Double copy); BANK INFO, 8*T*K (the copy: its
    /// atoms are already resident); both T*K^2 SVD units.
    func admitBankSVD(_ verb: String, T: Int, K: Int, bytesPerTK: Int) -> String? {
        let t = AdmitCount(T), k = AdmitCount(K)
        let what = bytesPerTK == 12 ? "the T*K atoms and the declaration's Double copy, 12*T*K"
                                    : "the declaration's Double copy of the resident atoms, 8*T*K"
        return admit(verb, bytes: Self.withByteMargin(AdmitCount(bytesPerTK) * t * k), what: what + Self.byteMarginWords,
                     work: [AdmitWork(units: "SVD units (T*K^2)", needed: t * k * k, cap: Self.alloc1aBankSVDCap)])
    }

    /// Every daemon path to `WaveBank.fit` is admitted —
    /// BANK FIT (here, one fit) and BANK NOISE (n fits, at its own site); no other
    /// daemon code calls it. One fit: atomsD and dgelsd's A, 16*T*K, and T*K^2 fit units.
    func admitBankFit(T: Int, K: Int) -> String? {
        let t = AdmitCount(T), k = AdmitCount(K)
        return admit("BANK FIT", bytes: Self.withByteMargin(AdmitCount(16) * t * k), what: "one fit's two T*K Double copies" + Self.byteMarginWords,
                     work: [AdmitWork(units: "fit units (n*T*K^2)", needed: t * k * k, cap: Self.alloc1aNoiseFitCap)])
    }

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
    /// file-scoped `private` helpers don't cross extension files, so this
    /// stays a local copy.
    private func twinBankErrorLine(_ error: Error) -> String {
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
}
