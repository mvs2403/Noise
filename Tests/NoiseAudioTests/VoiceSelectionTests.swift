import XCTest
import NoiseAudio
import CNoiseRuntime

final class VoiceSelectionTests: XCTestCase {
    private var paths: RuntimePaths {
        RuntimePaths(root: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent())
    }
    func testSavedVoiceChoicesMigrateWithoutEnrollment() {
        XCTAssertEqual(VoiceMode(restoring: nil), .all)
        XCTAssertEqual(VoiceMode(restoring: "all"), .all)
        XCTAssertEqual(VoiceMode(restoring: "mine"), .mainSpeaker)
        XCTAssertEqual(VoiceMode(restoring: "selected"), .mainSpeaker)
        XCTAssertEqual(VoiceMode(restoring: "main"), .mainSpeaker)
        XCTAssertEqual(VoiceMode(restoring: "unknown"), .all)
    }
    func testAllVoicesHonorsChosenEngineAndMainSpeakerUsesForegroundModel() {
        for engine in NoiseEngine.allCases {
            XCTAssertEqual(VoiceMode.all.runtimeEngine(for: engine), Int32(engine.rawValue))
            XCTAssertEqual(VoiceMode.mainSpeaker.runtimeEngine(for: engine), Int32(NR_MAIN_SPEAKER))
        }
    }
    func testMissingForegroundRuntimeFailsClearlyInsteadOfFallingBack() {
        var error = [CChar](repeating: 0, count: 1024)
        let p = nr_denoiser_create(Int32(NR_MAIN_SPEAKER), "/missing-runtime", "/missing-models", &error, Int32(error.count))
        XCTAssertNil(p)
        XCTAssertTrue(String(cString: error).contains("main-speaker runtime is missing"))
    }
    func testMissingForegroundModelFailsClearly() throws {
        guard paths.mainSpeakerAvailable else { throw XCTSkip("Run script/bootstrap.py first") }
        var error = [CChar](repeating: 0, count: 1024)
        let p = nr_denoiser_create(Int32(NR_MAIN_SPEAKER), paths.libraries.path, "/missing-models", &error, Int32(error.count))
        XCTAssertNil(p)
        XCTAssertTrue(String(cString: error).contains("main-speaker model is missing"))
    }
    func testAutomaticModeNeedsNoProfileAndOriginalIsExact() throws {
        guard paths.mainSpeakerAvailable else { throw XCTSkip("Run script/bootstrap.py first") }
        var error = [CChar](repeating: 0, count: 1024)
        let p = try XCTUnwrap(nr_processor_create(Int32(NR_MAIN_SPEAKER), paths.libraries.path, paths.models.path, &error, Int32(error.count)), String(cString: error))
        defer { nr_processor_destroy(p) }
        var output = [Float](repeating: 0, count: 480)
        for frame in 0..<160 {
            let input = (0..<480).map { i in Float(sin(Double(frame * 480 + i) * 2 * .pi * 180 / 48000)) * 0.1 }
            XCTAssertTrue(nr_processor_process(p, input, &output, true, false))
            XCTAssertTrue(output.allSatisfy { $0.isFinite && abs($0) <= 1 })
            if frame % 30 == 0 {
                XCTAssertTrue(nr_processor_process(p, input, &output, true, true))
                XCTAssertEqual(output, input)
                XCTAssertEqual(nr_processor_gain_db(p), 0)
            }
        }
    }
    func testForegroundSessionsDoNotShareMutableAudioState() throws {
        guard paths.mainSpeakerAvailable else { throw XCTSkip("Run script/bootstrap.py first") }
        var error = [CChar](repeating: 0, count: 1024)
        func make() throws -> OpaquePointer {
            try XCTUnwrap(nr_denoiser_create(Int32(NR_MAIN_SPEAKER), paths.libraries.path, paths.models.path, &error, Int32(error.count)), String(cString: error))
        }
        let a = try make(), b = try make(), reference = try make()
        defer { [a, b, reference].forEach(nr_denoiser_destroy) }
        var outA = [Float](repeating: 0, count: 480), outB = outA, expected = outA
        for frame in 0..<100 {
            let input = (0..<480).map { i in Float(sin(Double(frame * 480 + i) * 0.027)) * 0.1 }
            let other = input.map { -$0 * 0.3 }
            XCTAssertTrue(nr_denoiser_process(a, input, &outA))
            XCTAssertTrue(nr_denoiser_process(b, other, &outB))
            XCTAssertTrue(nr_denoiser_process(reference, input, &expected))
            XCTAssertEqual(outA, expected)
        }
    }
}
