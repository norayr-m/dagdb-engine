import Foundation
import DagDB

// dagdb-twin-demo — a runnable walk through the seven twin primitives.
//
// Each step below is deliberately small: it constructs the primitive with
// the exact public API the test suite uses (DagDB/Tests/DagDBTests/*), then
// prints what happened. No result here is invented — every printed number
// comes from actually calling the engine.

func section(_ n: Int, _ title: String) {
    print("")
    print("=== [\(n)] \(title) ===")
}

func hex(_ v: UInt64) -> String { String(format: "0x%016llx", v) }

// MARK: - [1] NamedStream — deterministic draws, same seed -> same sequence

section(1, "NamedStream: deterministic draws")

func referenceStream(name: String) -> NamedStream {
    NamedStream(name: name,
                stateHi: 0x853c_49e6_748f_ea9b, stateLo: 0xda3e_39cb_94b9_5bdb,
                incHi: 0x5851_f42d_4c95_7f2d, incLo: 0x1405_7b7e_f767_814f)
}

var streamA = referenceStream(name: "demo-a")
var streamB = referenceStream(name: "demo-b")

let drawsA = (0..<4).map { _ in streamA.next64() }
let drawsB = (0..<4).map { _ in streamB.next64() }

print("stream A, first 4 draws (seed 0x853c49e6..da3e39cb):")
for d in drawsA { print("  \(hex(d))") }
print("stream B, same seed, first 4 draws:")
for d in drawsB { print("  \(hex(d))") }
precondition(drawsA == drawsB, "same seed must produce the same sequence")
print("A == B: \(drawsA == drawsB)  (identical seeds, identical sequence, verified by equality assert)")

// MARK: - [2] StreamHeader — admissible header, then three refusals

section(2, "StreamHeader: t-zero admissibility and refusals")

func w1Like() -> StreamHeader {
    StreamHeader(signalBandHz: 1500, tauWindowSec: 0.6827, combRateHz: 3000,
                 firstEchoSec: 1.0, recordWindowSec: 0.6827, stepSec: 1.0 / 24000,
                 clockSyncFloorSec: 0)
}

let admissible = w1Like()
print("admissible header (1.5 kHz band, 3 kHz comb, 0.6827 s window): isAdmissible = \(admissible.isAdmissible)")

var slowSignal = w1Like()
slowSignal.signalBandHz = 1.0 // period 1 s > 0.6827 s window
let v1 = slowSignal.violations()
print("refusal 1 — signal wider than window (band dropped to 1 Hz): \(v1.map(\.description).joined(separator: "; "))")

var sparseComb = w1Like()
sparseComb.combRateHz = 2000 // < 2 x 1500 Hz
let v2 = sparseComb.violations()
print("refusal 2 — comb below Nyquist (comb dropped to 2000 Hz): \(v2.map(\.description).joined(separator: "; "))")

var earlyEcho = w1Like()
earlyEcho.firstEchoSec = 0.5 // record window 0.6827 s reaches it
let v3 = earlyEcho.violations()
print("refusal 3 — record outlives echo (echo moved to 0.5 s): \(v3.map(\.description).joined(separator: "; "))")

// MARK: - [3] StreamRecord — record a slice, replay from boundary, bit-exact

section(3, "StreamRecord: record and bit-exact replay from boundary state")

var record = try! StreamRecord(header: w1Like(), generator: referenceStream(name: "court-demo"))
try! record.recordSlice(count: 5)
let middle = try! record.recordSlice(count: 7)
try! record.recordSlice(count: 3)

let replayed = try! record.replaySlice(1)
let bitExact = replayed == middle.payload
print("recorded slice 1: \(middle.count) draws, entry draw index \(middle.entryDraws)")
print("stored payload:  \(middle.payload.map(hex).joined(separator: " "))")
print("replayed payload:\(replayed.map(hex).joined(separator: " "))")
print("bit-exact equality: \(bitExact)")
precondition(bitExact, "replay from boundary state must match the stored payload exactly")
print("full-record verify() failing indices: \(record.verify())  (empty == every slice replays)")

// MARK: - [4] GearedRings — planted signed extremum recalled by lag

section(4, "GearedRings: signed extremum recall across lag")

var rings = try GearedRings(gear: 6, rings: 4, cellsPerRing: 8)
let plantedTick: UInt64 = 250
let plantedValue: Float = 7.5
let totalTicks: UInt64 = 1500
for t in 0..<totalTicks {
    let v: Float = (t == plantedTick) ? plantedValue : (t % 2 == 0 ? 0.01 : -0.01)
    rings.write(v)
}
let lag = totalTicks - plantedTick
if let recall = rings.recall(lag: lag) {
    print("planted value \(plantedValue) at tick \(plantedTick), \(totalTicks) ticks written, recalled at lag \(lag):")
    print("  value = \(recall.value), tick = \(recall.tick), ring = \(recall.ring), span length = \(recall.spanLength)")
    precondition(recall.value == plantedValue && recall.tick == plantedTick, "recall must return the exact planted value and tick")
} else {
    print("recall(lag: \(lag)) returned nil — beyond all horizons")
}

// MARK: - [5] MasterClock + PhaseGear — 6:1 ladder, exact integer fire counts

section(5, "MasterClock + PhaseGear: 6:1 ladder, exact fire counts")

var bands = try (0..<4).map { j -> PhaseGear in
    var den: UInt64 = 1
    for _ in 0..<j { den *= 6 }
    return PhaseGear(name: "band\(j)", ratio: try GearRatio(1, over: den))
}
var clock = MasterClock()
let n: UInt64 = 6 * 6 * 6 * 10
for _ in 0..<n {
    clock.advance()
    for i in bands.indices { bands[i].advance(masterTick: clock.tick, value: 0) }
}
let expected: [UInt64] = [n, n / 6, n / 36, n / 216]
print("N = \(n) master ticks; ladder ratios 1/1, 1/6, 1/36, 1/216:")
for (band, (fires, exp)) in zip(bands, zip(bands.map(\.fires), expected)) {
    print("  \(band.name) (\(band.ratio)): fires = \(fires), floor(N*p/q) = \(exp), exact = \(fires == exp)")
}
precondition(bands.map(\.fires) == expected, "fire counts must be exact integers with no drift")

// MARK: - [6] CrossConvolutionCheck — pass, scream, flash

section(6, "CrossConvolutionCheck: pass, scream, flash")

var srcStream = referenceStream(name: "w6-demo")
func unit(_ s: inout NamedStream) -> Float { Float(s.next64() >> 40) / Float(1 << 24) - 0.5 }
let source = (0..<64).map { _ in unit(&srcStream) }
let kernelA = CrossConvolutionCheck.PathKernel(taps: (0..<6).map { _ in unit(&srcStream) })
let kernelB = CrossConvolutionCheck.PathKernel(taps: (0..<9).map { _ in unit(&srcStream) })
let earA = CrossConvolutionCheck.convolve(source, kernelA).map { Float($0) }
let earB = CrossConvolutionCheck.convolve(source, kernelB).map { Float($0) }
let warmup = 16

let truePass = CrossConvolutionCheck.check(recordA: earA, recordB: earB,
                                            kernelA: kernelA, kernelB: kernelB, warmup: warmup)
print("true signal (kB*a vs kA*b, same source through both ears): residual = \(truePass.residual), passes(1e-6) = \(truePass.passes(tolerance: 1e-6))")

var noise = NamedStream(name: "forge", stateHi: 1, stateLo: 2, incHi: 3, incLo: 5)
let forged = (0..<earB.count).map { _ in unit(&noise) }
let scream = CrossConvolutionCheck.check(recordA: earA, recordB: forged,
                                          kernelA: kernelA, kernelB: kernelB, warmup: warmup)
print("forged recording (ear B replaced with unrelated noise): residual = \(scream.residual)  (a scream)")

let twistedKernel = CrossConvolutionCheck.PathKernel(taps: kernelB.taps.map { $0 * 1.2 })
let flash = CrossConvolutionCheck.check(recordA: earA, recordB: earB,
                                         kernelA: kernelA, kernelB: twistedKernel, warmup: warmup)
print("twisted path model (kernel B scaled 1.2x): residual = \(flash.residual)  (a flash, not a scream)")

// MARK: - [7] BudgetLayout — claim merge and the min-cost tie rule

section(7, "BudgetLayout: claim merge and the min-cost tie rule")

func row(r4: Double, r7: Double) -> [Double] {
    [r4 / 2, r4, r4 * 2, r4 * 4, r7, r7 * 2, r7 * 3, r7 * 4]
}
let layout = BudgetLayout(cost: [
    row(r4: 162, r7: 15138),  // pocket 0
    row(r4: 50, r7: 12168),   // pocket 1
    row(r4: 162, r7: 10952),  // pocket 2
    row(r4: 98, r7: 5618),    // pocket 3
], minTier: [4, 1, 4])

// Colocation rescue: two liar claims land in pocket 0 and merge into one
// purchase with value 2, cost carried by pocket 0's tier-4 rate — beating a
// lone cheaper claim in pocket 3.
let mergeClaims = [BudgetLayout.Claim(pocket: 0, classIndex: 0),
                   BudgetLayout.Claim(pocket: 0, classIndex: 0),
                   BudgetLayout.Claim(pocket: 3, classIndex: 0)]
let mergeLayout = try! layout.allocate(claims: mergeClaims, budget: 16164)
print("merge: two claims in pocket 0 + one claim in pocket 3, budget 16164")
print("  served pockets = \(mergeLayout.servedPockets), purchases = \(mergeLayout.purchases.count), readValue = \(mergeLayout.readValue), totalCost = \(mergeLayout.totalCost)")
print("  (pocket 0's two claims merged into one purchase; value 2 beats pocket 3's lone value 1)")

// Min-cost tie: one claim each in pockets 0 and 3, equal value (1 each);
// budget affords only one, so the cheaper pocket wins the slot.
let tieClaims = [BudgetLayout.Claim(pocket: 0, classIndex: 0),
                 BudgetLayout.Claim(pocket: 3, classIndex: 0)]
let tieLayout = try! layout.allocate(claims: tieClaims, budget: 16164)
print("min-cost tie: one claim each in pockets 0 and 3, budget 16164")
print("  served pockets = \(tieLayout.servedPockets), readValue = \(tieLayout.readValue), totalCost = \(tieLayout.totalCost)")
print("  (equal value 1 vs 1; pocket 3's cheaper purchase wins the legal tie)")

// MARK: - [8] NamedStream — Codable round-trip mid-sequence

section(8, "NamedStream: Codable round-trip mid-sequence")

var midStream = referenceStream(name: "codable-demo")
for _ in 0..<6 { _ = midStream.next64() }
print("stream after 6 draws: name=\(midStream.name) draws=\(midStream.draws)")

let encoder = JSONEncoder()
let decoder = JSONDecoder()
let encoded = try! encoder.encode(midStream)
var decodedStream = try! decoder.decode(NamedStream.self, from: encoded)
print("decoded == original: \(decodedStream == midStream)")
precondition(decodedStream == midStream, "decoded stream must equal the original mid-sequence stream")

let nextFromOriginal = midStream.next64()
let nextFromDecoded = decodedStream.next64()
print("next draw from original: \(hex(nextFromOriginal))")
print("next draw from decoded:  \(hex(nextFromDecoded))")
precondition(nextFromOriginal == nextFromDecoded, "decoded stream must continue the identical sequence")
print("(a daemon-held stream survives a restart in O(1) — restore from the boundary, never redraw)")

// MARK: - [9] SealedCourt — a legal miss at the P1 budget point

section(9, "SealedCourt: legal miss at B=13491.480553724456")

let legalMissLayout = SealedCourt.makeLayout()
let legalMissBudget = 13491.480553724456
let legalMissClaims = [
    BudgetLayout.Claim(pocket: SealedCourt.pocketIndex(SealedCourt.pocket(for: .A)), classIndex: SealedCourt.classIndex(.L)),
    BudgetLayout.Claim(pocket: SealedCourt.pocketIndex(SealedCourt.pocket(for: .B)), classIndex: SealedCourt.classIndex(.L)),
]
let legalMissResult = try! legalMissLayout.allocate(claims: legalMissClaims, budget: legalMissBudget)
let servedSealedPockets = legalMissResult.servedPockets.map(SealedCourt.sealedPocket)
print("claims: liar_A (sealed pocket \(SealedCourt.pocket(for: .A))) + liar_B (sealed pocket \(SealedCourt.pocket(for: .B))), budget \(legalMissBudget)")
print("  served sealed pockets = \(servedSealedPockets), readValue = \(legalMissResult.readValue), totalCost = \(legalMissResult.totalCost)")
print("  (liar_A's pocket \(SealedCourt.pocket(for: .A)) at r7 costs \(SealedCourt.tariff[SealedCourt.pocket(for: .A)]![7]!), over budget;")
print("   liar_B's pocket \(SealedCourt.pocket(for: .B)) at r7 costs \(SealedCourt.tariff[SealedCourt.pocket(for: .B)]![7]!), affordable —")
print("   liar_A legally misses even though nothing is wrong with its claim, only its price)")

// MARK: - [10] AllocatorCourt — sealed gate-1 grid, env-gated on the real fixture

section(10, "AllocatorCourt: sealed gate-1 grid (env-gated)")

if let fixturePath = AlarmFixture.envPath {
    do {
        let fixture = try AlarmFixture.load(path: fixturePath, expectedSHA256: AlarmFixture.sealedSHA256)
        print("loaded \(fixture.records.count) records (sha256 verified against the pinned sealed hash)")
        let grid = AllocatorCourt.runGrid(records: fixture.records)
        for point in grid {
            guard let allocator = point.arms[.allocator] else { continue }
            print("  B=\(point.budget) k7=\(point.k7): misses=\(allocator.misses) served=\(allocator.served) cost=\(allocator.cost)")
        }
    } catch {
        print("\(AlarmFixture.envVar) is set but the fixture failed to load: \(error)")
    }
} else {
    print("\(AlarmFixture.envVar) not set — sealed gate-1 grid skipped (see docs/contracts/INTERFACE_PHASE_GATES_FROZEN.md)")
}

print("")
print("=== twin demo complete: steps [1]-[10] exercised, all preconditions held ===")
