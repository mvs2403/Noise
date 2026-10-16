import XCTest
import NoiseAudio
import CNoiseRuntime

final class NoiseStrengthTests: XCTestCase {
    func testEveryEngineUsesAlignedOriginalAndBlendsStrengthLinearly() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let paths = RuntimePaths(root: root)
        guard NoiseEngine.allCases.allSatisfy(paths.isAvailable), paths.mainSpeakerAvailable else { throw XCTSkip("Install local runtimes first") }
        let configurations: [(String, Int32, Int)] = NoiseEngine.allCases.map {
            ($0.name, Int32($0.rawValue), $0 == .dpdfnet ? 2400 : $0 == .deepFilterNet ? 1440 : 960)
        } + [("Main speaker", Int32(NR_MAIN_SPEAKER), 670)]
        for (name, kind, delay) in configurations {
            var error = [CChar](repeating: 0, count: 1024)
            let processors = try [Float(0), 0.5, 1].map { strength -> OpaquePointer in
                let p = try XCTUnwrap(nr_processor_create(kind, paths.libraries.path, paths.models.path, &error, Int32(error.count)), String(cString: error))
                nr_processor_set_strength(p, strength)
                return p
            }
            defer { processors.forEach(nr_processor_destroy) }
            var history = [Float](repeating: 0, count: delay)
            var outputs = [[Float]](repeating: .init(repeating: 0, count: 480), count: 3)
            var seed: UInt32 = 12345
            for frame in 0..<100 {
                let input = (0..<480).map { _ -> Float in
                    seed = seed &* 1664525 &+ 1013904223
                    return (Float(seed >> 8) / Float(0xFFFFFF) - 0.5) * 0.1
                }
                history.append(contentsOf: input)
                for i in 0..<3 { XCTAssertTrue(nr_processor_process(processors[i], input, &outputs[i], false, false), name) }
                if frame > 1 {
                    let aligned = Array(history[(frame * 480)..<(frame * 480 + 480)])
                    XCTAssertEqual(outputs[0], aligned, "Zero strength must be the delay-aligned original for \(name).")
                    let maxError = (0..<480).map { abs(outputs[1][$0] - (outputs[0][$0] + outputs[2][$0]) * 0.5) }.max() ?? 0
                    XCTAssertLessThan(maxError, 0.000001, "Half strength must blend the same moments of audio for \(name).")
                }
            }
            nr_processor_set_strength(processors[0], .nan)
            let input = [Float](repeating: 0.02, count: 480)
            XCTAssertTrue(nr_processor_process(processors[0], input, &outputs[0], false, true))
            XCTAssertEqual(outputs[0], input, "Original bypass must remain exact at any strength.")
        }
    }
}
