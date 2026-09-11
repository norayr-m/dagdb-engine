/// VIEW verb family — alarm-set derived views over the sealed cortex v4
/// world (spec line 4, second view family). Gate contract:
/// docs/contracts/DERIVED_VIEWS_GATES_FROZEN.md, gate V6.
///
/// `VIEW LOAD` follows ALARM LOAD's guardPath-first, validate-before-mint
/// pattern (DagDBCommandHandler+TwinAlarm.swift): `guardPath` rejects
/// traversal/outside-dataRoot paths before any file I/O; the fixture is
/// then loaded ONCE (any `CortexFixture.FixtureError` — file missing, SHA
/// mismatch, malformed npz layout — becomes `ERROR io:`, never silently
/// accepted). The `TwinOp.viewLoad` logged to the WAL and applied to
/// `twin` always carries the fixture's OWN computed sha256 (not the
/// caller's optional `SHA` argument) — that is the by-reference pin later
/// restore/replay verifies against. Because the fixture is already in
/// hand, the custom `viewLoader` closure passed to `twin.apply` just
/// returns it directly rather than re-reading the file.
///
/// REFLEX/RUNG/CEILING/FEATURES/INFO/LIST are pure reads over the loaded
/// `DerivedViews` — no WAL, no mutation. CLOSE logs `.close` first, like
/// every other twin CLOSE verb.
import Foundation
import DagDB

extension DagDBCommandHandler {
    func handleTwinView(_ cmd: TwinCommand, sessionId: String?) -> String {
        switch cmd {

        case .viewLoad(let path, let sha256Arg):
            if let err = guardPath(path) { return err }
            let fixture: CortexFixture
            do {
                fixture = try CortexFixture.load(path: path, expectedSHA256: sha256Arg)
            } catch {
                return viewLoadErrorLine(error)
            }
            let id = twin.nextId(prefix: "v")
            let op = TwinOp.viewLoad(id: id, path: path, sha256: fixture.sha256)
            if let err = appendTwinWAL(op) { return err }
            do {
                try twin.apply(op, viewLoader: { _, _ in fixture })
            } catch { return twinViewStateErrorLine(error) }

            return twinResponse(
                "VIEW LOAD", sessionId: sessionId,
                "id=\(id) train=\(fixture.trainCount) test=\(fixture.testCount) stations=\(fixture.stations) " +
                "samples=\(fixture.samples) candidates=\(fixture.candidates) sha256=\(fixture.sha256)"
            )

        case .viewReflex(let id, let s):
            guard let set = twin.views.get(id) else { return "ERROR not_found: \(id)" }
            if let err = stationsRangeError(s, set) { return err }
            let summary = set.views.reflexSummary(stations: s)
            return twinResponse(
                "VIEW REFLEX", sessionId: sessionId,
                "id=\(id) S=\(s) reflex=\(summary.hits) oracle=\(summary.oracleHits) " +
                "tie_min=\(summary.tieMin) tie_median=\(summary.tieMedian) tie_max=\(summary.tieMax) " +
                "frames_with_tie=\(summary.framesWithTie) near_edge=\(summary.nearEdgeTotal)"
            )

        case .viewRung(let id, let s):
            guard let set = twin.views.get(id) else { return "ERROR not_found: \(id)" }
            if let err = stationsRangeError(s, set) { return err }
            let centroids = set.views.centroids(stations: s)
            let summary = set.views.rung(stations: s, centroids: centroids)
            return twinResponse(
                "VIEW RUNG", sessionId: sessionId,
                "id=\(id) S=\(s) hits=\(summary.hits) min_margin=\(summary.minMargin)"
            )

        case .viewCeiling(let id, let s):
            guard let set = twin.views.get(id) else { return "ERROR not_found: \(id)" }
            if let err = stationsRangeError(s, set) { return err }
            let c = set.views.ceiling(stations: s)
            return twinResponse(
                "VIEW CEILING", sessionId: sessionId,
                "id=\(id) S=\(s) identifiable=\(c.identifiable) of=\(set.views.fixture.candidates) " +
                "ceiling=\(String(format: "%.6f", c.ceiling)) exact_twin_pairs=\(c.exactTwinPairs) " +
                "unique=\(c.unique) groups=\(c.groups)"
            )

        case .viewFeatures(let id, let frame, let s):
            guard let set = twin.views.get(id) else { return "ERROR not_found: \(id)" }
            if let err = stationsRangeError(s, set) { return err }
            guard frame >= 0 && frame < set.views.fixture.testCount else {
                return "ERROR out_of_range: frame \(frame) not in [0, \(set.views.fixture.testCount))"
            }
            let centroids = set.views.centroids(stations: s)
            let testFrame = set.views.fixture.frame(test: frame)
            let feat = DerivedViews.features(frame: testFrame, stations: s, fs: set.views.fixture.fs)
            var z = [Float](repeating: 0, count: feat.count)
            for k in 0..<feat.count { z[k] = Float((feat[k] - centroids.mean[k]) / centroids.std[k]) }
            let outputBytes = 8 + z.count * 4
            guard outputBytes <= shmCapacityBytes else {
                return "ERROR out_of_range: VIEW FEATURES output \(outputBytes) bytes exceeds shm capacity \(shmCapacityBytes)"
            }
            writeFloatVector(z)
            return twinResponse(
                "VIEW FEATURES", sessionId: sessionId,
                "id=\(id) frame=\(frame) S=\(s) count=\(z.count)"
            )

        case .viewInfo(let id):
            guard let set = twin.views.get(id) else { return "ERROR not_found: \(id)" }
            return twinResponse(
                "VIEW INFO", sessionId: sessionId,
                "id=\(id) path=\(set.ref.path) sha256=\(set.ref.sha256) train=\(set.views.fixture.trainCount) " +
                "test=\(set.views.fixture.testCount) stations=\(set.views.fixture.stations) " +
                "samples=\(set.views.fixture.samples) candidates=\(set.views.fixture.candidates)"
            )

        case .viewList:
            let ids = twin.views.ids.sorted()
            return twinResponse("VIEW LIST", sessionId: sessionId, "count=\(ids.count)\(idsSuffixView(ids))")

        case .viewClose(let id):
            guard twin.views.get(id) != nil else { return "ERROR not_found: \(id)" }
            let op = TwinOp.close(id: id)
            if let err = appendTwinWAL(op) { return err }
            do { try twin.apply(op) } catch { return twinViewStateErrorLine(error) }
            return twinResponse("VIEW CLOSE", sessionId: sessionId, "id=\(id)")

        default:
            // Every case this family handler is dispatched (see handleTwin
            // in DagDBCommandHandler+Twin.swift) is covered above; this
            // branch exists only for switch exhaustiveness.
            return "ERROR unknown_command: twin verb not wired yet"
        }
    }

    // MARK: - Shared range check

    /// nil iff `s` is a valid station-subset size for `set`'s fixture
    /// (1...stations, fixed at 8 by CortexFixture.load).
    private func stationsRangeError(_ s: Int, _ set: TwinState.ViewSet) -> String? {
        guard s >= 1 && s <= set.views.fixture.stations else {
            return "ERROR out_of_range: S \(s) not in [1, \(set.views.fixture.stations)]"
        }
        return nil
    }

    // MARK: - Error formatting

    /// `CortexFixture.FixtureError` (file missing, sha mismatch, malformed
    /// npz layout) always maps to `ERROR io:` — every view-load failure is
    /// an I/O-layer finding, never silently accepted (mirrors ALARM LOAD's
    /// contract). The sha-mismatch line always contains the literal phrase
    /// "sha256 mismatch".
    private func viewLoadErrorLine(_ error: Error) -> String {
        if let e = error as? CortexFixture.FixtureError {
            switch e {
            case .fileNotFound(let p):
                return "ERROR io: file not found: \(p)"
            case .shaMismatch(let expected, let actual):
                return "ERROR io: sha256 mismatch: expected \(expected) actual \(actual)"
            case .badLayout(let reason):
                return "ERROR io: bad layout: \(reason)"
            }
        }
        return "ERROR io: \(error)"
    }

    /// `TwinState.TwinError` renders via its own `description`; kept as a
    /// file-local twin (see DagDBCommandHandler+TwinAlarm.swift's
    /// `twinStateErrorLine`) since `private` helpers in a sibling extension
    /// file aren't visible here.
    private func twinViewStateErrorLine(_ error: Error) -> String {
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

    private func idsSuffixView(_ ids: [String]) -> String {
        ids.isEmpty ? "" : " " + ids.joined(separator: " ")
    }
}
