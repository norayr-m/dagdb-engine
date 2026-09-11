import Foundation
import Dispatch
import Accelerate

/// Alarm-set derived views over the sealed cortex v4 world (spec line 4,
/// second view family). Reads `CortexFixture` only; every number here is
/// judged against `docs/contracts/DERIVED_VIEWS_GATES_FROZEN.md` — its
/// Definitions, the six letters under ruling (e), and gates V1-V5, V7.
///
/// Station subsets (contract): for S in {2, 4, 6, 8}, the first S columns
/// of `fixture.tau` / `fixture.tauRaw` and the first S rows of a frame —
/// both already ordered by `fixture.scan`, so index s in 0..<S means the
/// same station on both sides without any remapping.
public struct DerivedViews {
    public let fixture: CortexFixture

    public init(fixture: CortexFixture) {
        self.fixture = fixture
    }

    // MARK: - Arrivals (ruling: per-station front index, S-subset re-zeroed)

    public struct Arrivals: Equatable {
        public let raw: [Double]
        public let zeroed: [Double]

        public init(raw: [Double], zeroed: [Double]) {
            self.raw = raw
            self.zeroed = zeroed
        }
    }

    /// Per station s in 0..<S of the frame: first index t where
    /// |x_s[t]| > 0.25 * max_t |x_s[t]|, as Double. An all-zero station has
    /// no exceedance — numpy's argmax of an all-False mask is 0, so that
    /// station's raw arrival is 0. zeroed = raw - min(raw) over the S
    /// stations in use.
    public static func arrivals(frame: [[Float]], stations S: Int) -> Arrivals {
        var raw = [Double](repeating: 0, count: S)
        for s in 0..<S {
            let row = frame[s]
            var maxAbs: Float = 0
            for v in row {
                let a = abs(v)
                if a > maxAbs { maxAbs = a }
            }
            let threshold = 0.25 * maxAbs
            var found: Int? = nil
            for t in 0..<row.count {
                if abs(row[t]) > threshold {
                    found = t
                    break
                }
            }
            raw[s] = Double(found ?? 0)
        }
        let minRaw = raw.min() ?? 0
        let zeroed = raw.map { $0 - minRaw }
        return Arrivals(raw: raw, zeroed: zeroed)
    }

    // MARK: - Reflex (amended letter: 2-parameter fit per candidate, tie rule)

    public struct ReflexDecision: Equatable {
        public let winner: Int
        public let tiedSet: [Int]
        public let residuals: [Double]
        public let rMin: Double
        public let nearEdge: Int

        public init(winner: Int, tiedSet: [Int], residuals: [Double], rMin: Double, nearEdge: Int) {
            self.winner = winner
            self.tiedSet = tiedSet
            self.residuals = residuals
            self.rMin = rMin
            self.nearEdge = nearEdge
        }
    }

    /// Per candidate c in 0..<129: A (S x 2) = [tau[c][0..<S], 1.0]; solve
    /// the least squares fit A*[alpha, beta] ~= zeroed in Double via
    /// LAPACK dgelsd_ (same solver family as WaveBank.fit / numpy's
    /// lstsq — keeps tie behaviour, not a closed form). alpha < 0 => alpha
    /// = 0 (beta unchanged); the residual is then recomputed from the
    /// (possibly clamped) alpha, beta — never taken from the solver.
    public func reflex(frame: [[Float]], stations S: Int) -> ReflexDecision {
        let zeroed = DerivedViews.arrivals(frame: frame, stations: S).zeroed
        let candidates = fixture.candidates
        let stride = fixture.stations

        // Workspace size depends only on the (S, 2, nrhs=1) shape, which is
        // fixed for every candidate in this call — query it once per frame
        // instead of once per candidate (129x fewer query calls).
        let workspace = DerivedViews.lstsqWorkspaceQuery(m: S, n: 2)

        var residuals = [Double](repeating: 0, count: candidates)
        for c in 0..<candidates {
            let base = c * stride
            var A = [Double](repeating: 0, count: S * 2)
            for s in 0..<S { A[s] = fixture.tau[base + s] }          // column 0
            for s in 0..<S { A[S + s] = 1.0 }                        // column 1
            let sol = DerivedViews.solveLstSq(A: A, m: S, n: 2, b: zeroed, workspace: workspace)
            var alpha = sol?[0] ?? 0
            let beta = sol?[1] ?? 0
            if alpha < 0 { alpha = 0 }
            var r = 0.0
            for s in 0..<S {
                let pred = alpha * fixture.tau[base + s] + beta
                let d = pred - zeroed[s]
                r += d * d
            }
            residuals[c] = r
        }

        let rMin = residuals.min() ?? 0
        let tol = 1e-9 * max(1.0, rMin)
        var tiedSet: [Int] = []
        for c in 0..<candidates where residuals[c] <= rMin + tol { tiedSet.append(c) }
        let winner = tiedSet.first ?? 0

        let edge = rMin + tol
        var nearEdge = 0
        for c in 0..<candidates where abs(residuals[c] - edge) <= 10 * tol { nearEdge += 1 }

        return ReflexDecision(winner: winner, tiedSet: tiedSet, residuals: residuals, rMin: rMin, nearEdge: nearEdge)
    }

    public struct ReflexSummary: Equatable {
        public let hits: Int
        public let oracleHits: Int
        public let tieMin: Int
        public let tieMedian: Double
        public let tieMax: Int
        public let framesWithTie: Int
        public let nearEdgeTotal: Int
        public let wallMs: Double

        public init(hits: Int, oracleHits: Int, tieMin: Int, tieMedian: Double, tieMax: Int,
                    framesWithTie: Int, nearEdgeTotal: Int, wallMs: Double) {
            self.hits = hits
            self.oracleHits = oracleHits
            self.tieMin = tieMin
            self.tieMedian = tieMedian
            self.tieMax = tieMax
            self.framesWithTie = framesWithTie
            self.nearEdgeTotal = nearEdgeTotal
            self.wallMs = wallMs
        }
    }

    /// Over the 300 test frames: hit iff winner == yTest[m]; oracle hit iff
    /// yTest[m] is in the tied set; tie sizes reduced to min/median(numpy)/
    /// max; framesWithTie = frames whose tied set has more than one member.
    public func reflexSummary(stations S: Int) -> ReflexSummary {
        let start = DispatchTime.now()
        var hits = 0
        var oracleHits = 0
        var tieSizes: [Int] = []
        tieSizes.reserveCapacity(fixture.testCount)
        var framesWithTie = 0
        var nearEdgeTotal = 0

        for m in 0..<fixture.testCount {
            let frame = fixture.frame(test: m)
            let decision = reflex(frame: frame, stations: S)
            let label = fixture.yTest[m]
            if decision.winner == label { hits += 1 }
            if decision.tiedSet.contains(label) { oracleHits += 1 }
            tieSizes.append(decision.tiedSet.count)
            if decision.tiedSet.count > 1 { framesWithTie += 1 }
            nearEdgeTotal += decision.nearEdge
        }

        let tieMin = tieSizes.min() ?? 0
        let tieMax = tieSizes.max() ?? 0
        let tieMedian = DerivedViews.numpyMedian(tieSizes)
        let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000.0

        return ReflexSummary(hits: hits, oracleHits: oracleHits, tieMin: tieMin, tieMedian: tieMedian,
                              tieMax: tieMax, framesWithTie: framesWithTie, nearEdgeTotal: nearEdgeTotal,
                              wallMs: elapsedMs)
    }

    /// numpy's median: sort, and for an even count average the two middle
    /// values.
    public static func numpyMedian(_ v: [Int]) -> Double {
        let sorted = v.sorted()
        let n = sorted.count
        guard n > 0 else { return 0 }
        if n % 2 == 1 { return Double(sorted[n / 2]) }
        return Double(sorted[n / 2 - 1] + sorted[n / 2]) / 2.0
    }

    // MARK: - Front-aligned energy features (ruling e.2/e.3/e.4)

    /// 3*S values, station-major — for each station s in 0..<S: (ii) log
    /// front-window energy ratio, (iii) magnitude-weighted spectral
    /// centroid of the front window, (iv) log energy ratio of the second
    /// 16-sample window over the first.
    public static func features(frame: [[Float]], stations S: Int, fs: Double, eps: Double = 1e-12) -> [Double] {
        let arr = DerivedViews.arrivals(frame: frame, stations: S)

        var frameEnergy = 0.0
        for s in 0..<S {
            for v in frame[s] {
                let d = Double(v)
                frameEnergy += d * d
            }
        }

        var out = [Double]()
        out.reserveCapacity(3 * S)
        for s in 0..<S {
            let row = frame[s]
            let f = Int(arr.raw[s])
            var win1 = [Double](repeating: 0, count: 16)
            for n in 0..<16 {
                let idx = f + n
                if idx >= 0 && idx < row.count { win1[n] = Double(row[idx]) }
            }
            var win2 = [Double](repeating: 0, count: 16)
            for n in 0..<16 {
                let idx = f + 16 + n
                if idx >= 0 && idx < row.count { win2[n] = Double(row[idx]) }
            }

            let sumWin1Sq = win1.reduce(0.0) { $0 + $1 * $1 }
            let sumWin2Sq = win2.reduce(0.0) { $0 + $1 * $1 }
            let ii = log(sumWin1Sq + eps) - log(frameEnergy + eps)

            var magSum = 0.0
            var weighted = 0.0
            for k in 0...8 {
                var re = 0.0
                var im = 0.0
                for n in 0..<16 {
                    let theta = 2.0 * Double.pi * Double(k) * Double(n) / 16.0
                    re += win1[n] * cos(theta)
                    im -= win1[n] * sin(theta)
                }
                let mag = (re * re + im * im).squareRoot()
                let fk = Double(k) * fs / 16.0
                magSum += mag
                weighted += mag * fk
            }
            let iii = magSum < eps ? 0.0 : weighted / magSum

            let iv = log(sumWin2Sq + eps) - log(sumWin1Sq + eps)

            out.append(ii)
            out.append(iii)
            out.append(iv)
        }
        return out
    }

    // MARK: - Class centroids (standardized, train set)

    public struct Centroids: Equatable {
        public let mean: [Double]
        public let std: [Double]
        public let centroids: [[Double]]
        public let wallMs: Double

        public init(mean: [Double], std: [Double], centroids: [[Double]], wallMs: Double) {
            self.mean = mean
            self.std = std
            self.centroids = centroids
            self.wallMs = wallMs
        }
    }

    /// Features of all 6966 train frames; mean and population std (ddof=0)
    /// per feature, std floored at 1e-12; candidate centroid = mean of the
    /// standardized features over that candidate's 54 train frames.
    public func centroids(stations S: Int) -> Centroids {
        let start = DispatchTime.now()
        let n = fixture.trainCount
        let dim = 3 * S

        var allFeatures = [[Double]]()
        allFeatures.reserveCapacity(n)
        for m in 0..<n {
            let frame = fixture.frame(train: m)
            allFeatures.append(DerivedViews.features(frame: frame, stations: S, fs: fixture.fs))
        }

        var mean = [Double](repeating: 0, count: dim)
        for f in allFeatures {
            for k in 0..<dim { mean[k] += f[k] }
        }
        for k in 0..<dim { mean[k] /= Double(n) }

        var variance = [Double](repeating: 0, count: dim)
        for f in allFeatures {
            for k in 0..<dim {
                let d = f[k] - mean[k]
                variance[k] += d * d
            }
        }
        for k in 0..<dim { variance[k] /= Double(n) }
        var std = variance.map { $0.squareRoot() }
        for k in 0..<dim where std[k] < 1e-12 { std[k] = 1e-12 }

        let candidates = fixture.candidates
        var classSum = [[Double]](repeating: [Double](repeating: 0, count: dim), count: candidates)
        var classCount = [Int](repeating: 0, count: candidates)
        for m in 0..<n {
            let c = fixture.yTrain[m]
            classCount[c] += 1
            for k in 0..<dim {
                classSum[c][k] += (allFeatures[m][k] - mean[k]) / std[k]
            }
        }
        var centroidsArr = [[Double]](repeating: [Double](repeating: 0, count: dim), count: candidates)
        for c in 0..<candidates {
            let count = classCount[c]
            guard count > 0 else { continue }
            let inv = 1.0 / Double(count)
            for k in 0..<dim { centroidsArr[c][k] = classSum[c][k] * inv }
        }

        let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000.0
        return Centroids(mean: mean, std: std, centroids: centroidsArr, wallMs: elapsedMs)
    }

    // MARK: - Geometry-then-energy rung (V4)

    public struct RungSummary: Equatable {
        public let hits: Int
        public let minMargin: Double
        public let wallMs: Double

        public init(hits: Int, minMargin: Double, wallMs: Double) {
            self.hits = hits
            self.minMargin = minMargin
            self.wallMs = wallMs
        }
    }

    /// Per test frame: tied set from reflex; standardized test features;
    /// among the tied set choose the candidate with the smallest Euclidean
    /// distance to its centroid (exact ties keep the lowest index). hit
    /// iff the chosen candidate is the true label. minMargin is a printed
    /// floor: the minimum, over frames with a tie, of the gap between the
    /// second-best and best distance.
    public func rung(stations S: Int, centroids: Centroids) -> RungSummary {
        let start = DispatchTime.now()
        var hits = 0
        var margins: [Double] = []

        for m in 0..<fixture.testCount {
            let frame = fixture.frame(test: m)
            let decision = reflex(frame: frame, stations: S)
            let feat = DerivedViews.features(frame: frame, stations: S, fs: fixture.fs)
            var z = [Double](repeating: 0, count: feat.count)
            for k in 0..<feat.count { z[k] = (feat[k] - centroids.mean[k]) / centroids.std[k] }

            var distances = [Double](repeating: 0, count: decision.tiedSet.count)
            for (i, c) in decision.tiedSet.enumerated() {
                var distSq = 0.0
                for k in 0..<z.count {
                    let d = z[k] - centroids.centroids[c][k]
                    distSq += d * d
                }
                distances[i] = distSq.squareRoot()
            }

            var bestIdx = 0
            var bestDist = distances.first ?? 0
            for i in 1..<distances.count where distances[i] < bestDist {
                bestDist = distances[i]
                bestIdx = i
            }
            let chosen = decision.tiedSet[bestIdx]
            if chosen == fixture.yTest[m] { hits += 1 }

            if distances.count > 1 {
                let sorted = distances.sorted()
                margins.append(sorted[1] - sorted[0])
            }
        }

        let minMargin = margins.min() ?? 0
        let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000.0
        return RungSummary(hits: hits, minMargin: minMargin, wallMs: elapsedMs)
    }

    // MARK: - Arrival-geometry ceiling (V5)

    public struct Ceiling: Equatable {
        public let identifiable: Int
        public let unique: Int
        public let groups: Int
        public let ceiling: Double
        public let exactTwinPairs: Int

        public init(identifiable: Int, unique: Int, groups: Int, ceiling: Double, exactTwinPairs: Int) {
            self.identifiable = identifiable
            self.unique = unique
            self.groups = groups
            self.ceiling = ceiling
            self.exactTwinPairs = exactTwinPairs
        }
    }

    /// k = 1/(speed*dt*os); A_c = k*tauRaw[c][0..<S], row-shifted by its
    /// min. Exact-twin pairs: max_s|A_i - A_j| < 1e-9. Classes: union-find
    /// over max_s|A_i - A_j| < 1.0 (transitive closure); identifiable =
    /// unique (size-1 classes) + groups (size>=2 classes).
    public func ceiling(stations S: Int) -> Ceiling {
        let k = 1.0 / (fixture.speed * fixture.dt * Double(fixture.os))
        let candidates = fixture.candidates
        let stride = fixture.stations

        var A = [[Double]](repeating: [Double](repeating: 0, count: S), count: candidates)
        for c in 0..<candidates {
            let base = c * stride
            var row = [Double](repeating: 0, count: S)
            for s in 0..<S { row[s] = k * fixture.tauRaw[base + s] }
            let rmin = row.min() ?? 0
            for s in 0..<S { row[s] -= rmin }
            A[c] = row
        }

        var exactTwinPairs = 0
        var uf = DerivedViews.UnionFind(n: candidates)
        for i in 0..<candidates {
            for j in (i + 1)..<candidates {
                var maxDiff = 0.0
                for s in 0..<S {
                    let d = abs(A[i][s] - A[j][s])
                    if d > maxDiff { maxDiff = d }
                }
                if maxDiff < 1e-9 { exactTwinPairs += 1 }
                if maxDiff < 1.0 { uf.union(i, j) }
            }
        }

        var sizes = [Int: Int]()
        for i in 0..<candidates {
            let r = uf.find(i)
            sizes[r, default: 0] += 1
        }
        let unique = sizes.values.filter { $0 == 1 }.count
        let groups = sizes.values.filter { $0 > 1 }.count
        let identifiable = unique + groups
        let ceilingVal = Double(identifiable) / Double(candidates)

        return Ceiling(identifiable: identifiable, unique: unique, groups: groups,
                        ceiling: ceilingVal, exactTwinPairs: exactTwinPairs)
    }

    // MARK: - Union-find (ceiling's transitive closure)

    private struct UnionFind {
        var parent: [Int]

        init(n: Int) {
            parent = Array(0..<n)
        }

        mutating func find(_ x: Int) -> Int {
            var x = x
            while parent[x] != x {
                parent[x] = parent[parent[x]]
                x = parent[x]
            }
            return x
        }

        mutating func union(_ a: Int, _ b: Int) {
            let ra = find(a), rb = find(b)
            if ra != rb { parent[ra] = rb }
        }
    }

    // MARK: - Least squares (dgelsd_, workspace-query style from WaveBank.fit)

    struct LstsqWorkspace {
        let lwork: Int
        let liwork: Int
    }

    /// One workspace-size query for the (m, n, nrhs=1) shape, reused across
    /// every candidate solve in a single `reflex` call — the same solver
    /// family and query pattern as `WaveBank.fit`, but queried once per
    /// frame instead of once per candidate.
    static func lstsqWorkspaceQuery(m: Int, n: Int) -> LstsqWorkspace {
        var A = [Double](repeating: 0, count: m * n)
        var b = [Double](repeating: 0, count: max(m, n))
        var s = [Double](repeating: 0, count: min(m, n))
        var mm = __CLPK_integer(m)
        var nn = __CLPK_integer(n)
        var nrhs = __CLPK_integer(1)
        var lda = __CLPK_integer(m)
        var ldb = __CLPK_integer(max(m, n))
        var rcond = Double.ulpOfOne * Double(max(m, n))
        var rank: __CLPK_integer = 0
        var info: __CLPK_integer = 0
        var workQuery = [Double](repeating: 0, count: 1)
        var lworkQuery = __CLPK_integer(-1)
        var iworkQuery = [__CLPK_integer](repeating: 0, count: 1)
        dgelsd_(&mm, &nn, &nrhs, &A, &lda, &b, &ldb, &s, &rcond, &rank,
                &workQuery, &lworkQuery, &iworkQuery, &info)
        let lwork = max(Int(workQuery[0]), 1)
        let liwork = max(Int(iworkQuery[0]), 1)
        return LstsqWorkspace(lwork: lwork, liwork: liwork)
    }

    /// A is column-major m x n; b is length m (m >= n here, S >= 2).
    /// rcond = eps(Double) * max(m, n) — numpy's float64 lstsq default.
    /// Returns the first n entries of the solved b (alpha, beta), or nil
    /// on a LAPACK failure.
    static func solveLstSq(A: [Double], m: Int, n: Int, b: [Double], workspace: LstsqWorkspace) -> [Double]? {
        var Acopy = A
        var bBuf = b
        let ldbLen = max(m, n)
        if bBuf.count < ldbLen {
            bBuf += [Double](repeating: 0, count: ldbLen - bBuf.count)
        }
        var mm = __CLPK_integer(m)
        var nn = __CLPK_integer(n)
        var nrhs = __CLPK_integer(1)
        var lda = __CLPK_integer(m)
        var ldb = __CLPK_integer(ldbLen)
        var singularValues = [Double](repeating: 0, count: min(m, n))
        var rcond = Double.ulpOfOne * Double(max(m, n))
        var rank: __CLPK_integer = 0
        var info: __CLPK_integer = 0
        var work = [Double](repeating: 0, count: workspace.lwork)
        var iwork = [__CLPK_integer](repeating: 0, count: workspace.liwork)
        var lwork = __CLPK_integer(workspace.lwork)
        dgelsd_(&mm, &nn, &nrhs, &Acopy, &lda, &bBuf, &ldb, &singularValues, &rcond, &rank,
                &work, &lwork, &iwork, &info)
        guard info == 0 else { return nil }
        return Array(bBuf[0..<n])
    }
}
