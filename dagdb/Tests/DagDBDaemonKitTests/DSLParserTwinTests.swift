import XCTest
@testable import DagDB
@testable import DagDBDaemonKit

/// Grammar + dispatch tests for the twin-spec DSL (interface phase, 2026-09). These tests
/// exercise: parsing every verb to its expected TwinCommand case, arity
/// rejection, the isReadOnly matrix, and the READER-session forbidden path.
/// STREAM/HEADER/RECORD went real in T8.2 (their dispatch behavior is
/// covered in TwinStreamCommandTests.swift instead); the stub-dispatch
/// tests here now target only the families still stubbed
/// (RINGS/CLOCK/GEAR — T8.3, XCONV/BUDGET — T8.4, ALARM — T8.5).
///
/// DSLCommand itself isn't Equatable (Predicate carries a non-Equatable
/// closure-free-but-untested field, and several non-twin cases were never
/// made Equatable), so these helpers pattern-match out the `.twin`/`.unknown`
/// payload instead of comparing DSLCommand values directly.
final class DSLParserTwinTests: XCTestCase {

    private func assertParsesTwin(
        _ input: String, _ expected: TwinCommand,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        guard case .twin(let actual) = DSLParser.parse(input) else {
            XCTFail("expected .twin(\(expected)) for '\(input)', got a non-twin command", file: file, line: line)
            return
        }
        XCTAssertEqual(actual, expected, "parsing '\(input)'", file: file, line: line)
    }

    private func assertUnknown(
        _ input: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        guard case .unknown(let raw) = DSLParser.parse(input) else {
            XCTFail("expected .unknown(...) for '\(input)'", file: file, line: line)
            return
        }
        XCTAssertEqual(raw, input, file: file, line: line)
    }

    // MARK: - STREAM

    func testStreamOpenParsesHexAndDecimal() {
        assertParsesTwin(
            "STREAM OPEN ref 0x853c49e6748fea9b 0xda3e39cb94b95bdb 0x5851f42d4c957f2d 0x14057b7ef767814f",
            .streamOpen(
                name: "ref",
                stateHi: 0x853c49e6748fea9b, stateLo: 0xda3e39cb94b95bdb,
                incHi: 0x5851f42d4c957f2d, incLo: 0x14057b7ef767814f
            )
        )
    }

    func testStreamOpenParsesDecimal() {
        assertParsesTwin("STREAM OPEN ref 1 2 3 4", .streamOpen(name: "ref", stateHi: 1, stateLo: 2, incHi: 3, incLo: 4))
    }

    func testStreamOpenPreservesNameCase() {
        assertParsesTwin("STREAM OPEN MixedCase 1 2 3 4", .streamOpen(name: "MixedCase", stateHi: 1, stateLo: 2, incHi: 3, incLo: 4))
    }

    func testStreamOpenArityErrorIsUnknown() {
        assertUnknown("STREAM OPEN ref 1 2 3")
        assertUnknown("STREAM OPEN ref 1 2 3 4 5")
    }

    func testStreamNextParses() {
        assertParsesTwin("STREAM NEXT s00000001 6", .streamNext(id: "s00000001", n: 6))
    }

    func testStreamStateCloseListParse() {
        assertParsesTwin("STREAM STATE s00000001", .streamState(id: "s00000001"))
        assertParsesTwin("STREAM CLOSE s00000001", .streamClose(id: "s00000001"))
        assertParsesTwin("STREAM LIST", .streamList)
    }

    func testStreamUnknownSubverbIsUnknown() {
        assertUnknown("STREAM FROB s00000001")
    }

    // MARK: - HEADER

    func testHeaderCheckParses() {
        assertParsesTwin(
            "HEADER CHECK 1500 0.6827 3000 1.0 0.6827 0.00001 0",
            .headerCheck(band: 1500, tau: 0.6827, comb: 3000, echo: 1.0, record: 0.6827, step: 0.00001, floor: 0)
        )
    }

    func testHeaderCheckArityErrorIsUnknown() {
        assertUnknown("HEADER CHECK 1500 0.6827 3000")
    }

    // MARK: - RECORD

    func testRecordOpenParses() {
        assertParsesTwin(
            "RECORD OPEN court 1500 0.6827 3000 1.0 0.6827 0.00001 0 1 2 3 4",
            .recordOpen(
                name: "court",
                band: 1500, tau: 0.6827, comb: 3000, echo: 1.0, record: 0.6827, step: 0.00001, floor: 0,
                stateHi: 1, stateLo: 2, incHi: 3, incLo: 4
            )
        )
    }

    func testRecordOpenArityErrorIsUnknown() {
        assertUnknown("RECORD OPEN court 1 2 3")
    }

    func testRecordSliceReplayVerifyInfoCloseListParse() {
        assertParsesTwin("RECORD SLICE t00000001 5", .recordSlice(id: "t00000001", count: 5))
        assertParsesTwin("RECORD REPLAY t00000001 1", .recordReplay(id: "t00000001", index: 1))
        assertParsesTwin("RECORD VERIFY t00000001", .recordVerify(id: "t00000001"))
        assertParsesTwin("RECORD INFO t00000001", .recordInfo(id: "t00000001"))
        assertParsesTwin("RECORD CLOSE t00000001", .recordClose(id: "t00000001"))
        assertParsesTwin("RECORD LIST", .recordList)
    }

    // MARK: - RINGS

    func testRingsOpenDefaultsAndExplicit() {
        assertParsesTwin("RINGS OPEN", .ringsOpen(gear: 6, rings: 6, cells: 32))
        assertParsesTwin("RINGS OPEN 6 4 8", .ringsOpen(gear: 6, rings: 4, cells: 8))
    }

    func testRingsOpenPartialArityIsUnknown() {
        assertUnknown("RINGS OPEN 6 4")
    }

    func testRingsWriteParsesMultipleValues() {
        assertParsesTwin("RINGS WRITE n00000001 1.5 -2.25 3", .ringsWrite(id: "n00000001", values: [1.5, -2.25, 3]))
    }

    func testRingsWriteRequiresAtLeastOneValue() {
        assertUnknown("RINGS WRITE n00000001")
    }

    func testRingsRecallInfoCloseListParse() {
        assertParsesTwin("RINGS RECALL n00000001 1250", .ringsRecall(id: "n00000001", lag: 1250))
        assertParsesTwin("RINGS INFO n00000001", .ringsInfo(id: "n00000001"))
        assertParsesTwin("RINGS CLOSE n00000001", .ringsClose(id: "n00000001"))
        assertParsesTwin("RINGS LIST", .ringsList)
    }

    // MARK: - CLOCK

    func testClockOpenParses() {
        assertParsesTwin("CLOCK OPEN", .clockOpen)
    }

    func testClockAdvanceVariants() {
        assertParsesTwin("CLOCK ADVANCE c00000001", .clockAdvance(id: "c00000001", n: 1, value: nil))
        assertParsesTwin("CLOCK ADVANCE c00000001 10000", .clockAdvance(id: "c00000001", n: 10000, value: nil))
        assertParsesTwin("CLOCK ADVANCE c00000001 VALUE 10.0", .clockAdvance(id: "c00000001", n: 1, value: 10.0))
        assertParsesTwin("CLOCK ADVANCE c00000001 1 VALUE 10.0", .clockAdvance(id: "c00000001", n: 1, value: 10.0))
    }

    func testClockAdvanceMalformedIsUnknown() {
        assertUnknown("CLOCK ADVANCE c00000001 VALUE")
        assertUnknown("CLOCK ADVANCE c00000001 notanumber")
    }

    func testClockStateCloseListParse() {
        assertParsesTwin("CLOCK STATE c00000001", .clockState(id: "c00000001"))
        assertParsesTwin("CLOCK CLOSE c00000001", .clockClose(id: "c00000001"))
        assertParsesTwin("CLOCK LIST", .clockList)
    }

    // MARK: - GEAR

    func testGearOpenParsesRatio() {
        assertParsesTwin("GEAR OPEN c00000001 g 3/7", .gearOpen(clockId: "c00000001", name: "g", num: 3, den: 7))
    }

    func testGearOpenMalformedRatioIsUnknown() {
        assertUnknown("GEAR OPEN c00000001 g 3-7")
    }

    func testGearStateCloseParse() {
        assertParsesTwin("GEAR STATE g00000001", .gearState(id: "g00000001"))
        assertParsesTwin("GEAR CLOSE g00000001", .gearClose(id: "g00000001"))
    }

    // MARK: - XCONV

    func testXConvCheckParses() {
        assertParsesTwin("XCONV CHECK 69 72 6 9 16", .xconvCheck(nA: 69, nB: 72, kA: 6, kB: 9, warmup: 16))
    }

    func testXConvCheckArityErrorIsUnknown() {
        assertUnknown("XCONV CHECK 69 72 6")
    }

    // MARK: - XCONV SEALED (gate K3, docs/contracts/KERNELS_GATES_FROZEN.md)

    func testXConvSealedWithoutWarmupParses() {
        assertParsesTwin("XCONV SEALED k00000001 2048", .xconvSealed(id: "k00000001", n: 2048, warmup: nil))
    }

    func testXConvSealedWithWarmupParses() {
        assertParsesTwin("XCONV SEALED k00000001 2048 185", .xconvSealed(id: "k00000001", n: 2048, warmup: 185))
    }

    func testXConvSealedArityErrorIsUnknown() {
        assertUnknown("XCONV SEALED k00000001")
        assertUnknown("XCONV SEALED k00000001 2048 185 1")
        assertUnknown("XCONV SEALED k00000001 notanumber")
        assertUnknown("XCONV SEALED k00000001 2048 notanumber")
    }

    // MARK: - BUDGET

    func testBudgetOpenParses() {
        assertParsesTwin("BUDGET OPEN 4 8 3", .budgetOpen(nPockets: 4, nTiers: 8, nClasses: 3))
    }

    func testBudgetSealedParses() {
        assertParsesTwin("BUDGET SEALED", .budgetSealed)
    }

    func testBudgetAllocateParsesPocketClassClaims() {
        assertParsesTwin(
            "BUDGET ALLOCATE b00000001 16164.352484758914 0:0 3:0",
            .budgetAllocate(
                id: "b00000001", budget: 16164.352484758914,
                claims: [(pocket: 0, classIndex: 0), (pocket: 3, classIndex: 0)]
            )
        )
    }

    func testBudgetAllocateMalformedClaimIsUnknown() {
        assertUnknown("BUDGET ALLOCATE b00000001 100.0 0-0")
    }

    func testBudgetAllocateRequiresAtLeastOneClaim() {
        assertUnknown("BUDGET ALLOCATE b00000001 100.0")
    }

    func testBudgetInfoCloseListParse() {
        assertParsesTwin("BUDGET INFO b00000001", .budgetInfo(id: "b00000001"))
        assertParsesTwin("BUDGET CLOSE b00000001", .budgetClose(id: "b00000001"))
        assertParsesTwin("BUDGET LIST", .budgetList)
    }

    // MARK: - BANK

    func testBankOpenNoNumbersParsesToReferenceSpec() {
        assertParsesTwin("BANK OPEN mouth", .bankOpen(name: "mouth", spec: nil, aliased: false))
    }

    func testBankOpenExplicitSpecParsesDecimalFloats() {
        assertParsesTwin(
            "BANK OPEN small 64 1000 10 3 0 0 0.02",
            .bankOpen(
                name: "small",
                spec: WaveBank.Spec(samples: 64, sampleRate: 1000, f0: 10, harmonics: 3,
                                     gaborCenters: 0, gaborFreqs: 0, gaborSigmaFrac: 0.02),
                aliased: false
            )
        )
    }

    func testBankOpenPartialArityIsUnknown() {
        assertUnknown("BANK OPEN small 64 1000 10 3 0 0")
        assertUnknown("BANK OPEN small 64 1000 10 3 0 0 0.02 1")
    }

    // MARK: - BANK OPEN ALIASED

    func testBankOpenAliasedWithNumbersParsesAliasedTrue() {
        assertParsesTwin(
            "BANK OPEN mouth 4096 3000 60 32 8 6 0.02 ALIASED",
            .bankOpen(
                name: "mouth",
                spec: WaveBank.Spec(samples: 4096, sampleRate: 3000, f0: 60, harmonics: 32,
                                     gaborCenters: 8, gaborFreqs: 6, gaborSigmaFrac: 0.02),
                aliased: true
            )
        )
    }

    func testBankOpenAliasedWithoutNumbersIsUnknown() {
        assertUnknown("BANK OPEN mouth ALIASED")
    }

    func testBankOpenLowercaseAliasedIsUnknown() {
        assertUnknown("BANK OPEN mouth 4096 3000 60 32 8 6 0.02 aliased")
    }

    func testBankGenerateParses() {
        assertParsesTwin("BANK GENERATE w00000001 5", .bankGenerate(id: "w00000001", columns: 5))
    }

    func testBankGenerateArityErrorIsUnknown() {
        assertUnknown("BANK GENERATE w00000001")
    }

    func testBankFitParses() {
        assertParsesTwin("BANK FIT w00000001", .bankFit(id: "w00000001"))
    }

    func testBankNoiseParses() {
        assertParsesTwin("BANK NOISE w00000001 0 20", .bankNoise(id: "w00000001", seed: 0, count: 20))
    }

    func testBankNoiseArityErrorIsUnknown() {
        assertUnknown("BANK NOISE w00000001 0")
    }

    func testBankBenchParses() {
        assertParsesTwin("BANK BENCH w00000001 1000 2", .bankBench(id: "w00000001", columns: 1000, reps: 2))
    }

    func testBankBenchArityErrorIsUnknown() {
        assertUnknown("BANK BENCH w00000001 1000")
    }

    func testBankInfoCloseListParse() {
        assertParsesTwin("BANK INFO w00000001", .bankInfo(id: "w00000001"))
        assertParsesTwin("BANK CLOSE w00000001", .bankClose(id: "w00000001"))
        assertParsesTwin("BANK LIST", .bankList)
    }

    func testBankUnknownSubverbIsUnknown() {
        assertUnknown("BANK FROB w00000001")
    }

    // MARK: - ALARM

    func testAlarmLoadWithoutSha() {
        assertParsesTwin("ALARM LOAD /data/w2_records.json", .alarmLoad(path: "/data/w2_records.json", sha256: nil))
    }

    func testAlarmLoadWithSha() {
        assertParsesTwin(
            "ALARM LOAD /data/w2_records.json SHA be5c431f8ba410c632bbb18b89bce2b93d74dfcbc7f069ea9051f44e37618303",
            .alarmLoad(
                path: "/data/w2_records.json",
                sha256: "be5c431f8ba410c632bbb18b89bce2b93d74dfcbc7f069ea9051f44e37618303"
            )
        )
    }

    func testAlarmLoadMalformedShaKeywordIsUnknown() {
        assertUnknown("ALARM LOAD /data/w2_records.json HASH abc")
    }

    func testAlarmInfoListCloseParse() {
        assertParsesTwin("ALARM INFO a00000001", .alarmInfo(id: "a00000001"))
        assertParsesTwin("ALARM LIST", .alarmList)
        assertParsesTwin("ALARM CLOSE a00000001", .alarmClose(id: "a00000001"))
    }

    func testAlarmFrameParses() {
        assertParsesTwin("ALARM FRAME a00000001 3", .alarmFrame(id: "a00000001", idx: 3))
    }

    func testAlarmCourtParses() {
        assertParsesTwin("ALARM COURT a00000001 16164.352484758914", .alarmCourt(id: "a00000001", budget: 16164.352484758914))
    }

    func testAlarmSuccessorParses() {
        assertParsesTwin(
            "ALARM SUCCESSOR a00000001 13491.480553724456 0.25 0 0",
            .alarmSuccessor(id: "a00000001", budget: 13491.480553724456, epsM: 0.25, epsS: 0, epsN: 0)
        )
    }

    func testAlarmCorruptParses() {
        assertParsesTwin(
            "ALARM CORRUPT a00000001 3 0.5 0 1",
            .alarmCorrupt(id: "a00000001", idx: 3, epsM: 0.5, epsS: 0, epsN: 1)
        )
    }

    func testAlarmSuccessorArityErrorIsUnknown() {
        assertUnknown("ALARM SUCCESSOR a00000001 100.0 0.25 0")
    }

    // MARK: - VIEW

    func testViewLoadWithoutSha() {
        assertParsesTwin("VIEW LOAD /data/cortex_v4_world.npz", .viewLoad(path: "/data/cortex_v4_world.npz", sha256: nil))
    }

    func testViewLoadWithSha() {
        assertParsesTwin(
            "VIEW LOAD /data/cortex_v4_world.npz SHA 7d732e58a4e68fc7c6357ce75346984b39aec1d71c4dccd4c76a666543890bc2",
            .viewLoad(path: "/data/cortex_v4_world.npz",
                      sha256: "7d732e58a4e68fc7c6357ce75346984b39aec1d71c4dccd4c76a666543890bc2")
        )
    }

    func testViewLoadMalformedShaKeywordIsUnknown() {
        assertUnknown("VIEW LOAD /data/cortex_v4_world.npz HASH abc")
    }

    func testViewLoadArityErrorIsUnknown() {
        assertUnknown("VIEW LOAD")
        assertUnknown("VIEW LOAD /x.npz SHA")
        assertUnknown("VIEW LOAD /x.npz SHA abc extra")
    }

    func testViewReflexRungCeilingParse() {
        assertParsesTwin("VIEW REFLEX v00000001 8", .viewReflex(id: "v00000001", stations: 8))
        assertParsesTwin("VIEW RUNG v00000001 8", .viewRung(id: "v00000001", stations: 8))
        assertParsesTwin("VIEW CEILING v00000001 8", .viewCeiling(id: "v00000001", stations: 8))
    }

    func testViewReflexRungCeilingArityErrorIsUnknown() {
        assertUnknown("VIEW REFLEX v00000001")
        assertUnknown("VIEW RUNG v00000001")
        assertUnknown("VIEW CEILING v00000001")
        assertUnknown("VIEW REFLEX v00000001 8 9")
    }

    func testViewFeaturesParses() {
        assertParsesTwin("VIEW FEATURES v00000001 0 8", .viewFeatures(id: "v00000001", frame: 0, stations: 8))
    }

    func testViewFeaturesArityErrorIsUnknown() {
        assertUnknown("VIEW FEATURES v00000001 0")
        assertUnknown("VIEW FEATURES v00000001")
    }

    func testViewInfoListCloseParse() {
        assertParsesTwin("VIEW INFO v00000001", .viewInfo(id: "v00000001"))
        assertParsesTwin("VIEW LIST", .viewList)
        assertParsesTwin("VIEW CLOSE v00000001", .viewClose(id: "v00000001"))
    }

    func testViewUnknownSubverbIsUnknown() {
        assertUnknown("VIEW BOGUS v00000001")
    }

    // MARK: - KERNEL (gates K3/K4, docs/contracts/KERNELS_GATES_FROZEN.md)

    func testKernelLoadPathOnlyParses() {
        assertParsesTwin(
            "KERNEL LOAD /data/w1_kernels.json",
            .kernelLoad(path: "/data/w1_kernels.json", sha256: nil, tauA: nil, tauB: nil, sigmaSource: nil, declaredWarmup: nil)
        )
    }

    func testKernelLoadWithShaParses() {
        assertParsesTwin(
            "KERNEL LOAD /data/w1_kernels.json SHA 2523d3a8a4de44b56268ee31a703b6bcc6522c7c66a305651f8ec7c03e5c56b8",
            .kernelLoad(path: "/data/w1_kernels.json",
                        sha256: "2523d3a8a4de44b56268ee31a703b6bcc6522c7c66a305651f8ec7c03e5c56b8",
                        tauA: nil, tauB: nil, sigmaSource: nil, declaredWarmup: nil)
        )
    }

    func testKernelLoadWithTauSigmaParses() {
        assertParsesTwin(
            "KERNEL LOAD /data/w1_kernels.json TAU 0.18227148035108542 0.18382585465904366 SIGMA 0.02",
            .kernelLoad(path: "/data/w1_kernels.json", sha256: nil,
                        tauA: 0.18227148035108542, tauB: 0.18382585465904366, sigmaSource: 0.02, declaredWarmup: nil)
        )
    }

    func testKernelLoadWithWarmupParses() {
        assertParsesTwin(
            "KERNEL LOAD /data/w1_kernels.json WARMUP 185",
            .kernelLoad(path: "/data/w1_kernels.json", sha256: nil, tauA: nil, tauB: nil, sigmaSource: nil, declaredWarmup: 185)
        )
    }

    func testKernelLoadAllGroupsFixedOrderParses() {
        assertParsesTwin(
            "KERNEL LOAD /data/w1_kernels.json SHA 2523d3a8a4de44b56268ee31a703b6bcc6522c7c66a305651f8ec7c03e5c56b8 " +
                "TAU 0.18227148035108542 0.18382585465904366 SIGMA 0.02 WARMUP 185",
            .kernelLoad(path: "/data/w1_kernels.json",
                        sha256: "2523d3a8a4de44b56268ee31a703b6bcc6522c7c66a305651f8ec7c03e5c56b8",
                        tauA: 0.18227148035108542, tauB: 0.18382585465904366, sigmaSource: 0.02, declaredWarmup: 185)
        )
    }

    /// Fixed order per the frozen grammar — [SHA] [TAU/SIGMA] [WARMUP]; any
    /// other order (e.g. WARMUP before TAU, or SHA after TAU) is .unknown,
    /// never reordered/matched.
    func testKernelLoadOutOfOrderGroupsIsUnknown() {
        assertUnknown("KERNEL LOAD /data/w1_kernels.json WARMUP 185 TAU 1 2 SIGMA 0.02")
        assertUnknown("KERNEL LOAD /data/w1_kernels.json TAU 1 2 SIGMA 0.02 SHA abc")
        assertUnknown("KERNEL LOAD /data/w1_kernels.json WARMUP 185 SHA abc")
    }

    func testKernelLoadMalformedTauSigmaIsUnknown() {
        assertUnknown("KERNEL LOAD /data/w1_kernels.json TAU 1 2 NOTSIGMA 0.02")
        assertUnknown("KERNEL LOAD /data/w1_kernels.json TAU 1 2")
        assertUnknown("KERNEL LOAD /data/w1_kernels.json TAU notanumber 2 SIGMA 0.02")
    }

    func testKernelLoadArityErrorIsUnknown() {
        assertUnknown("KERNEL LOAD")
    }

    func testKernelInfoListCloseParse() {
        assertParsesTwin("KERNEL INFO k00000001", .kernelInfo(id: "k00000001"))
        assertParsesTwin("KERNEL LIST", .kernelList)
        assertParsesTwin("KERNEL CLOSE k00000001", .kernelClose(id: "k00000001"))
    }

    func testKernelUnknownSubverbIsUnknown() {
        assertUnknown("KERNEL BOGUS k00000001")
    }

    // MARK: - FOLD (gate F4)

    func testFoldRunParsesWithoutF3OrCheck() {
        assertParsesTwin(
            "FOLD RUN 6 3 78 78",
            .foldRun(maxRank: 6, keepRank: 3, f1: 78, f2: 78, f3: -1, checkpoints: [])
        )
    }

    func testFoldRunParsesWithF3() {
        assertParsesTwin(
            "FOLD RUN 22 3 968 1370",
            .foldRun(maxRank: 22, keepRank: 3, f1: 968, f2: 1370, f3: -1, checkpoints: [])
        )
        assertParsesTwin(
            "FOLD RUN 22 3 968 1370 970",
            .foldRun(maxRank: 22, keepRank: 3, f1: 968, f2: 1370, f3: 970, checkpoints: [])
        )
    }

    func testFoldRunParsesWithCheckAndNoF3() {
        assertParsesTwin(
            "FOLD RUN 6 3 78 78 CHECK 5,4",
            .foldRun(maxRank: 6, keepRank: 3, f1: 78, f2: 78, f3: -1, checkpoints: [5, 4])
        )
    }

    func testFoldRunParsesWithF3AndCheck() {
        assertParsesTwin(
            "FOLD RUN 22 3 968 1370 970 CHECK 19,15,11,7",
            .foldRun(maxRank: 22, keepRank: 3, f1: 968, f2: 1370, f3: 970, checkpoints: [19, 15, 11, 7])
        )
    }

    func testFoldRunSingleCheckpointParses() {
        assertParsesTwin(
            "FOLD RUN 6 3 78 78 CHECK 5",
            .foldRun(maxRank: 6, keepRank: 3, f1: 78, f2: 78, f3: -1, checkpoints: [5])
        )
    }

    func testFoldRunArityErrorsAreUnknown() {
        assertUnknown("FOLD RUN 6 3 78")
        assertUnknown("FOLD RUN 6 3 78 78 CHECK")
        assertUnknown("FOLD RUN 6 3 78 78 970 CHECK 5 4")   // comma required, not a space
        assertUnknown("FOLD RUN a 3 78 78")
        assertUnknown("FOLD RUN 6 3 78 78 CHECK 5,x")
    }

    func testFoldKeptParses() {
        assertParsesTwin("FOLD KEPT", .foldKept)
    }

    func testFoldKeptArityErrorIsUnknown() {
        assertUnknown("FOLD KEPT 1")
    }

    func testFoldSourceParses() {
        assertParsesTwin("FOLD SOURCE 1", .foldSource(which: 1))
        assertParsesTwin("FOLD SOURCE 2", .foldSource(which: 2))
        assertParsesTwin("FOLD SOURCE 3", .foldSource(which: 3))
    }

    func testFoldSourceOutOfRangeWhichIsUnknown() {
        assertUnknown("FOLD SOURCE 0")
        assertUnknown("FOLD SOURCE 4")
    }

    func testFoldTierParsesNumericAndFinalLevels() {
        assertParsesTwin("FOLD TIER final 1", .foldTier(level: "final", which: 1))
        assertParsesTwin("FOLD TIER 5 2", .foldTier(level: "5", which: 2))
    }

    func testFoldTierOutOfRangeWhichIsUnknown() {
        assertUnknown("FOLD TIER final 0")
        assertUnknown("FOLD TIER final 4")
    }

    func testFoldInfoParses() {
        assertParsesTwin("FOLD INFO", .foldInfo)
    }

    func testFoldInfoArityErrorIsUnknown() {
        assertUnknown("FOLD INFO extra")
    }

    func testFoldUnknownSubverbIsUnknown() {
        assertUnknown("FOLD FROB")
    }

    // MARK: - HOOK (gate H5, docs/contracts/HOOK_GATES_FROZEN.md)

    func testHookOpenSealedLayoutMinimalParses() {
        assertParsesTwin(
            "HOOK OPEN a00000001 SEALED 16164.352484758914",
            .hookOpen(alarmId: "a00000001", layoutId: nil, budget: 16164.352484758914, delta: nil, policy: nil, clockId: nil)
        )
    }

    func testHookOpenExplicitLayoutIdParses() {
        assertParsesTwin(
            "HOOK OPEN a00000001 b00000001 100000",
            .hookOpen(alarmId: "a00000001", layoutId: "b00000001", budget: 100000, delta: nil, policy: nil, clockId: nil)
        )
    }

    func testHookOpenAllGroupsFixedOrderParses() {
        assertParsesTwin(
            "HOOK OPEN a00000001 SEALED 100000 DELTA 5 POLICY greedy CLOCK c00000001",
            .hookOpen(alarmId: "a00000001", layoutId: nil, budget: 100000, delta: 5, policy: .greedy, clockId: "c00000001")
        )
    }

    func testHookOpenDeltaOnlyParses() {
        assertParsesTwin(
            "HOOK OPEN a00000001 SEALED 100000 DELTA 5",
            .hookOpen(alarmId: "a00000001", layoutId: nil, budget: 100000, delta: 5, policy: nil, clockId: nil)
        )
    }

    func testHookOpenPolicyOnlyParses() {
        assertParsesTwin(
            "HOOK OPEN a00000001 SEALED 100000 POLICY uniform",
            .hookOpen(alarmId: "a00000001", layoutId: nil, budget: 100000, delta: nil, policy: .uniform, clockId: nil)
        )
    }

    func testHookOpenClockOnlyParses() {
        assertParsesTwin(
            "HOOK OPEN a00000001 SEALED 100000 CLOCK c00000001",
            .hookOpen(alarmId: "a00000001", layoutId: nil, budget: 100000, delta: nil, policy: nil, clockId: "c00000001")
        )
    }

    func testHookOpenOutOfOrderGroupsIsUnknown() {
        assertUnknown("HOOK OPEN a00000001 SEALED 100000 CLOCK c00000001 DELTA 5")
        assertUnknown("HOOK OPEN a00000001 SEALED 100000 POLICY greedy DELTA 5")
        assertUnknown("HOOK OPEN a00000001 SEALED 100000 CLOCK c00000001 POLICY greedy")
    }

    func testHookOpenMalformedPolicyIsUnknown() {
        assertUnknown("HOOK OPEN a00000001 SEALED 100000 POLICY bogus")
        assertUnknown("HOOK OPEN a00000001 SEALED 100000 POLICY Allocator")
    }

    func testHookOpenMalformedDeltaIsUnknown() {
        assertUnknown("HOOK OPEN a00000001 SEALED 100000 DELTA notanumber")
    }

    func testHookOpenArityErrorIsUnknown() {
        assertUnknown("HOOK OPEN a00000001 SEALED")
        assertUnknown("HOOK OPEN a00000001")
        assertUnknown("HOOK OPEN")
    }

    func testHookStepParses() {
        assertParsesTwin("HOOK STEP h00000001 3", .hookStep(id: "h00000001", count: 3))
    }

    func testHookStepArityErrorIsUnknown() {
        assertUnknown("HOOK STEP h00000001")
        assertUnknown("HOOK STEP h00000001 3 4")
    }

    func testHookStateParses() {
        assertParsesTwin("HOOK STATE h00000001", .hookState(id: "h00000001"))
    }

    func testHookLedgerDefaultAndRangeParse() {
        assertParsesTwin("HOOK LEDGER h00000001", .hookLedger(id: "h00000001", from: nil, count: nil))
        assertParsesTwin("HOOK LEDGER h00000001 2 3", .hookLedger(id: "h00000001", from: 2, count: 3))
    }

    func testHookLedgerArityErrorIsUnknown() {
        assertUnknown("HOOK LEDGER h00000001 2")
    }

    func testHookInfoListCloseParse() {
        assertParsesTwin("HOOK INFO h00000001", .hookInfo(id: "h00000001"))
        assertParsesTwin("HOOK LIST", .hookList)
        assertParsesTwin("HOOK CLOSE h00000001", .hookClose(id: "h00000001"))
    }

    func testHookUnknownSubverbIsUnknown() {
        assertUnknown("HOOK BOGUS h00000001")
    }

    // MARK: - isReadOnly matrix (both polarities)

    func testReadOnlyVerbsAreMarkedReadOnly() {
        let readOnly: [TwinCommand] = [
            .streamState(id: "s00000001"),
            .streamList,
            .headerCheck(band: 1, tau: 1, comb: 1, echo: 1, record: 1, step: 1, floor: 1),
            .recordReplay(id: "t00000001", index: 0),
            .recordVerify(id: "t00000001"),
            .recordInfo(id: "t00000001"),
            .recordList,
            .ringsRecall(id: "n00000001", lag: 1),
            .ringsInfo(id: "n00000001"),
            .ringsList,
            .clockState(id: "c00000001"),
            .clockList,
            .gearState(id: "g00000001"),
            .xconvCheck(nA: 1, nB: 1, kA: 1, kB: 1, warmup: 0),
            .xconvSealed(id: "k00000001", n: 2048, warmup: nil),
            .budgetAllocate(id: "b00000001", budget: 1, claims: [(0, 0)]),
            .budgetInfo(id: "b00000001"),
            .budgetList,
            .alarmInfo(id: "a00000001"),
            .alarmList,
            .alarmFrame(id: "a00000001", idx: 0),
            .alarmCourt(id: "a00000001", budget: 1),
            .alarmSuccessor(id: "a00000001", budget: 1, epsM: 0, epsS: 0, epsN: 0),
            .alarmCorrupt(id: "a00000001", idx: 0, epsM: 0, epsS: 0, epsN: 0),
            .bankGenerate(id: "w00000001", columns: 1),
            .bankFit(id: "w00000001"),
            .bankNoise(id: "w00000001", seed: 0, count: 1),
            .bankBench(id: "w00000001", columns: 1, reps: 1),
            .bankInfo(id: "w00000001"),
            .bankList,
            .viewReflex(id: "v00000001", stations: 8),
            .viewRung(id: "v00000001", stations: 8),
            .viewCeiling(id: "v00000001", stations: 8),
            .viewFeatures(id: "v00000001", frame: 0, stations: 8),
            .viewInfo(id: "v00000001"),
            .viewList,
            .kernelInfo(id: "k00000001"),
            .kernelList,
            // FOLD (gate F4): pure computation over CURRENT lanes, nothing
            // persisted. RUN moved to the mutating list at gate D5 (audit B
            // finding 18): it assigns the daemon-global last-fold result
            // these four read.
            .foldKept,
            .foldSource(which: 1),
            .foldTier(level: "final", which: 1),
            .foldInfo,
            .hookState(id: "h00000001"),
            .hookLedger(id: "h00000001", from: nil, count: nil),
            .hookInfo(id: "h00000001"),
            .hookList,
        ]
        for cmd in readOnly {
            XCTAssertTrue(cmd.isReadOnly, "\(cmd) should be read-only")
        }
    }

    func testMutatingVerbsAreNotReadOnly() {
        let mutating: [TwinCommand] = [
            .streamOpen(name: "n", stateHi: 0, stateLo: 0, incHi: 0, incLo: 0),
            .streamNext(id: "s00000001", n: 1),
            .streamClose(id: "s00000001"),
            .recordOpen(name: "n", band: 0, tau: 0, comb: 0, echo: 0, record: 0, step: 0, floor: 0, stateHi: 0, stateLo: 0, incHi: 0, incLo: 0),
            .recordSlice(id: "t00000001", count: 1),
            .recordClose(id: "t00000001"),
            .ringsOpen(gear: 6, rings: 6, cells: 32),
            .ringsWrite(id: "n00000001", values: [1]),
            .ringsClose(id: "n00000001"),
            .clockOpen,
            .clockAdvance(id: "c00000001", n: 1, value: nil),
            .clockClose(id: "c00000001"),
            .gearOpen(clockId: "c00000001", name: "g", num: 1, den: 1),
            .gearClose(id: "g00000001"),
            .budgetOpen(nPockets: 1, nTiers: 1, nClasses: 1),
            .budgetSealed,
            .budgetClose(id: "b00000001"),
            .alarmLoad(path: "/x.json", sha256: nil),
            .alarmClose(id: "a00000001"),
            .foldRun(maxRank: 6, keepRank: 3, f1: 78, f2: 78, f3: -1, checkpoints: []),
            .bankOpen(name: "n", spec: nil, aliased: false),
            .bankClose(id: "w00000001"),
            .viewLoad(path: "/x.npz", sha256: nil),
            .viewClose(id: "v00000001"),
            .kernelLoad(path: "/x.json", sha256: nil, tauA: nil, tauB: nil, sigmaSource: nil, declaredWarmup: nil),
            .kernelClose(id: "k00000001"),
            .hookOpen(alarmId: "a00000001", layoutId: nil, budget: 1, delta: nil, policy: nil, clockId: nil),
            .hookStep(id: "h00000001", count: 1),
            .hookClose(id: "h00000001"),
        ]
        for cmd in mutating {
            XCTAssertFalse(cmd.isReadOnly, "\(cmd) should NOT be read-only")
        }
    }

    // MARK: - Dispatch
    //
    // Family dispatch coverage lives in the per-family command tests
    // (TwinStreamCommandTests, TwinClockCommandTests, TwinBudgetCommandTests,
    // TwinAlarmCommandTests). The stub-fallthrough assertions that lived here
    // during the interface phase were retired when the last family went real.

    func testStatusReplyCarriesTwinOpenSuffix() throws {
        let f = try HandlerFixture(side: 4)
        XCTAssertTrue(f.handler.handle("STATUS").contains("twin_open=0"))
    }

    // MARK: - READER session forbidden path

    private func openReaderId(_ f: HandlerFixture) throws -> String {
        let openReply = f.handler.handle("OPEN_READER")
        guard let ridRange = openReply.range(of: "id="),
              let spaceRange = openReply.range(of: " ", range: ridRange.upperBound..<openReply.endIndex) else {
            throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "could not parse reader id out of: \(openReply)"])
        }
        return String(openReply[ridRange.upperBound..<spaceRange.lowerBound])
    }

    func testReaderSessionForbidsMutatingTwinVerb() throws {
        let f = try HandlerFixture(side: 4)
        let rid = try openReaderId(f)
        let reply = f.handler.handle("READER \(rid) STREAM OPEN ref 1 2 3 4")
        XCTAssertTrue(reply.hasPrefix("ERROR forbidden"), reply)
    }

    func testReaderSessionAllowsReadOnlyTwinVerbThrough() throws {
        let f = try HandlerFixture(side: 4)
        let rid = try openReaderId(f)
        // RINGS LIST is read-only: the reader session must let it through to
        // the dispatcher (any non-forbidden reply), not reject it as forbidden.
        let reply = f.handler.handle("READER \(rid) RINGS LIST")
        XCTAssertFalse(reply.hasPrefix("ERROR forbidden"), reply)
    }
}
