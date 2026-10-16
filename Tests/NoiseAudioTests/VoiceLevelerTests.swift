import XCTest
import CNoiseRuntime
import NoiseAudio

final class VoiceLevelerTests: XCTestCase {
    private func voiceFrame(amplitude: Float, frame: Int) -> [Float] {
        (0..<480).map { i in
            let t = Double(frame * 480 + i) / 48000
            return amplitude * Float(sin(t * 2 * .pi * 180))
        }
    }
    private func rms(_ values: [Float]) -> Double {
        sqrt(values.reduce(0) { $0 + Double($1 * $1) } / Double(values.count))
    }

    func testQuietAndLoudSpeechConvergeToSimilarVolume() throws {
        let leveler = try XCTUnwrap(nr_voice_leveler_create())
        defer { nr_voice_leveler_destroy(leveler) }
        var quiet = [Float](), loud = [Float]()
        for index in 0..<800 {
            let amplitude: Float = index < 400 ? 0.02 : 0.5
            var frame = voiceFrame(amplitude: amplitude, frame: index)
            nr_voice_leveler_process(leveler, &frame, 1, true)
            if (300..<400).contains(index) { quiet.append(contentsOf: frame) }
            if index >= 700 { loud.append(contentsOf: frame) }
        }
        let quietRMS = rms(quiet), loudRMS = rms(loud)
        XCTAssertGreaterThan(quietRMS, 0.08, "Quiet speech should be brought up from approximately 0.014 RMS.")
        XCTAssertLessThan(loudRMS, 0.13, "Loud speech should be brought down from approximately 0.35 RMS.")
        XCTAssertLessThan(abs(20 * log10(quietRMS / loudRMS)), 1.5, "Settled voice levels should be within 1.5 dB.")
    }

    func testSuddenLoudSoundAfterQuietSpeechDoesNotClip() throws {
        let leveler = try XCTUnwrap(nr_voice_leveler_create())
        defer { nr_voice_leveler_destroy(leveler) }
        for index in 0..<300 {
            var frame = voiceFrame(amplitude: 0.01, frame: index)
            nr_voice_leveler_process(leveler, &frame, 1, true)
        }
        XCTAssertGreaterThan(nr_voice_leveler_gain_db(leveler), 10)
        var loud = voiceFrame(amplitude: 1, frame: 301)
        nr_voice_leveler_process(leveler, &loud, 1, true)
        XCTAssertTrue(loud.allSatisfy { $0.isFinite && abs($0) <= 0.891251 })
        XCTAssertGreaterThan(loud.map(abs).max() ?? 0, 0.1, "The limiter must preserve audible output.")
    }

    func testPausesDoNotIncreaseBackgroundNoise() throws {
        let leveler = try XCTUnwrap(nr_voice_leveler_create())
        defer { nr_voice_leveler_destroy(leveler) }
        for index in 0..<300 {
            var frame = voiceFrame(amplitude: 0.01, frame: index)
            nr_voice_leveler_process(leveler, &frame, 1, true)
        }
        let residual = [Float](repeating: 0.0003, count: 480)
        var afterPause = residual
        for _ in 0..<200 {
            afterPause = residual
            nr_voice_leveler_process(leveler, &afterPause, 0, true)
        }
        XCTAssertLessThanOrEqual(rms(afterPause), rms(residual) * 1.01)
        var silence = [Float](repeating: 0, count: 480)
        nr_voice_leveler_process(leveler, &silence, 0, true)
        XCTAssertTrue(silence.allSatisfy { $0 == 0 })
    }

    func testDisablingLevelingIsExactPassThrough() throws {
        let leveler = try XCTUnwrap(nr_voice_leveler_create())
        defer { nr_voice_leveler_destroy(leveler) }
        for index in 0..<100 {
            var frame = voiceFrame(amplitude: 0.01, frame: index)
            nr_voice_leveler_process(leveler, &frame, 1, true)
        }
        let original = voiceFrame(amplitude: 0.05, frame: 120)
        var output = original
        nr_voice_leveler_process(leveler, &output, 1, false)
        XCTAssertEqual(output, original)
        XCTAssertEqual(nr_voice_leveler_gain_db(leveler), 0)
    }

    func testOriginalBypassesDenoisingAndLevelingForEveryEngine() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let paths = RuntimePaths(root: root)
        guard NoiseEngine.allCases.allSatisfy(paths.isAvailable) else { throw XCTSkip("Install local engines first") }
        for engine in NoiseEngine.allCases {
            var error = [CChar](repeating: 0, count: 1024)
            let processor = try XCTUnwrap(nr_processor_create(Int32(engine.rawValue), paths.libraries.path, paths.models.path, &error, Int32(error.count)), String(cString: error))
            defer { nr_processor_destroy(processor) }
            for index in 0..<30 {
                let original = voiceFrame(amplitude: 0.07, frame: index)
                var output = [Float](repeating: 0, count: 480)
                XCTAssertTrue(nr_processor_process(processor, original, &output, true, true))
                XCTAssertEqual(output, original, engine.name)
                XCTAssertEqual(nr_processor_gain_db(processor), 0)
            }
        }
    }
}
