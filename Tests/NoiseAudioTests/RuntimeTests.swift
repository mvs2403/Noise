import XCTest
import NoiseAudio
import CNoiseRuntime

final class RuntimeTests: XCTestCase {
    func testRingWrapsAndRejectsOverwrite() {
        XCTAssertTrue(nr_ring_self_test(), "An overloaded callback must never overwrite unread audio.")
    }
    func testMissingRuntimeFailsExplicitly() {
        var error = [CChar](repeating: 0, count: 1024)
        let state = nr_denoiser_create(Int32(NR_RNNOISE), "/nonexistent/noise-runtime", "/nonexistent/noise-models", &error, Int32(error.count))
        XCTAssertNil(state)
        XCTAssertTrue(String(cString: error).contains("Cannot load engine"))
    }
    func testEachEngineProducesFiniteBoundedStreamingAudio() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let paths = RuntimePaths(root: root)
        guard NoiseEngine.allCases.allSatisfy(paths.isAvailable) else { throw XCTSkip("Run script/bootstrap.py to install the three local inference engines.") }
        for engine in NoiseEngine.allCases {
            var error = [CChar](repeating: 0, count: 1024)
            let state = try XCTUnwrap(nr_denoiser_create(Int32(engine.rawValue), paths.libraries.path, paths.models.path, &error, Int32(error.count)), String(cString: error))
            defer { nr_denoiser_destroy(state) }
            var output = [Float](repeating: 0, count: 480)
            // Warm up on silence, then process continuous non-stationary synthetic input.
            for frame in 0..<120 {
                let input: [Float] = (0..<480).map { i in
                    let t = Double(frame * 480 + i) / 48000
                    return frame < 20 ? 0 : Float(sin(t * 2 * .pi * 180) * 0.12 + sin(t * 2 * .pi * 3731) * 0.015)
                }
                XCTAssertTrue(nr_denoiser_process(state, input, &output), engine.name)
                XCTAssertTrue(output.allSatisfy { $0.isFinite && abs($0) <= 1 }, engine.name)
            }
        }
    }
    func testPipelineCanBeCancelledBeforeCaptureStarts() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let paths = RuntimePaths(root: root)
        guard paths.isAvailable(.rnnoise) else { throw XCTSkip("RNNoise runtime not installed") }
        var error = [CChar](repeating: 0, count: 1024)
        for _ in 0..<3 {
            let p = try XCTUnwrap(nr_pipeline_create(Int32(NR_RNNOISE), paths.libraries.path, paths.models.path, &error, Int32(error.count)))
            nr_pipeline_set_bypass(p, true)
            XCTAssertEqual(nr_pipeline_stats(p).input_frames, 0)
            nr_pipeline_destroy(p)
        }
    }
    func testEachEngineReducesStationaryNoise() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let paths = RuntimePaths(root: root)
        guard NoiseEngine.allCases.allSatisfy(paths.isAvailable) else { throw XCTSkip("Local engines not installed") }
        for engine in NoiseEngine.allCases {
            var error = [CChar](repeating: 0, count: 1024)
            let state = try XCTUnwrap(nr_denoiser_create(Int32(engine.rawValue), paths.libraries.path, paths.models.path, &error, Int32(error.count)))
            defer { nr_denoiser_destroy(state) }
            var seed: UInt32 = 12345
            var input = [Float](repeating: 0, count: 480)
            var output = input
            var rawEnergy = 0.0, cleanedEnergy = 0.0
            for frame in 0..<300 {
                for i in 0..<480 {
                    seed = seed &* 1664525 &+ 1013904223
                    input[i] = (Float(seed >> 8) / Float(0xFFFFFF) - 0.5) * 0.08
                }
                XCTAssertTrue(nr_denoiser_process(state, input, &output), engine.name)
                if frame >= 100 {
                    rawEnergy += input.reduce(0) { $0 + Double($1 * $1) }
                    cleanedEnergy += output.reduce(0) { $0 + Double($1 * $1) }
                }
            }
            XCTAssertLessThan(cleanedEnergy, rawEnergy * 0.8, "\(engine.name) should suppress stationary noise after warmup")
        }
    }
}
