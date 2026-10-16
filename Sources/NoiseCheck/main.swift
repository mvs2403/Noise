import AVFoundation
import Foundation
import NoiseAudio
import CNoiseRuntime

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func loadMono48k(_ url: URL) throws -> AVAudioPCMBuffer {
    let file = try AVAudioFile(forReading: url)
    guard file.length > 0, file.length < 48_000 * 60 * 30 else {
        throw AudioFailure("Choose an audio file shorter than 30 minutes.")
    }
    guard let source = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)),
          let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1),
          let converter = AVAudioConverter(from: file.processingFormat, to: format) else {
        throw AudioFailure("Cannot convert this audio file to mono 48 kHz.")
    }
    try file.read(into: source)
    let capacity = AVAudioFrameCount(ceil(Double(source.frameLength) * 48000 / file.processingFormat.sampleRate)) + 4096
    guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { throw AudioFailure("Cannot allocate audio buffer.") }
    converter.downmix = true
    var supplied = false
    var error: NSError?
    let status = converter.convert(to: output, error: &error) { _, status in
        if supplied { status.pointee = .endOfStream; return nil }
        supplied = true; status.pointee = .haveData; return source
    }
    if status == .error { throw error ?? AudioFailure("Audio conversion failed.") as NSError }
    guard output.frameLength > 0 else { throw AudioFailure("The audio file is empty.") }
    return output
}

let args = Array(CommandLine.arguments.dropFirst())
if args.first == "verify-bundle" {
    guard args.count == 2 else { fail("Usage: NoiseCheck verify-bundle /path/to/Noise.app") }
    let resources = URL(fileURLWithPath: args[1]).appendingPathComponent("Contents/Resources")
    let paths = RuntimePaths(resources: resources)
    for kind in [Int32(NR_DPDFNET), Int32(NR_DEEPFILTERNET), Int32(NR_RNNOISE), Int32(NR_MAIN_SPEAKER)] {
        var error = [CChar](repeating: 0, count: 1024)
        guard let processor = nr_processor_create(kind, paths.libraries.path, paths.models.path, &error, Int32(error.count)) else {
            fail("Bundled engine \(kind): \(String(cString: error))")
        }
        var clean = [Float](repeating: 0, count: 480)
        let input = (0..<480).map { Float(sin(Double($0) * 0.1) * 0.03) }
        for _ in 0..<40 {
            guard nr_processor_process(processor, input, &clean, true, false), clean.allSatisfy(\.isFinite) else {
                nr_processor_destroy(processor)
                fail("Bundled engine \(kind) produced invalid audio.")
            }
        }
        nr_processor_destroy(processor)
    }
    print("All four bundled engines streamed finite audio using only the app's packaged runtimes and models. No live audio was captured.")
} else if args.first == "benchmark" {
    let positional = args.filter { $0 != "--level" && $0 != "--main-speaker" }
    let leveling = args.contains("--level")
    let mainSpeaker = args.contains("--main-speaker")
    guard positional.count >= 2 else { fail("Usage: NoiseCheck benchmark input.wav [output-folder] [--level] [--main-speaker]") }
    do {
        let inputURL = URL(fileURLWithPath: positional[1])
        let destination = URL(fileURLWithPath: positional.count > 2 ? positional[2] : ".cache/comparisons")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let buffer = try loadMono48k(inputURL)
        let samples = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
        let paths = RuntimePaths()
        var results: [[String: Any]] = []
        for engine in (mainSpeaker ? [.dpdfnet] : NoiseEngine.allCases) {
            let kind = mainSpeaker ? Int32(NR_MAIN_SPEAKER) : Int32(engine.rawValue)
            let name = mainSpeaker ? "Main speaker" : engine.name
            var error = [CChar](repeating: 0, count: 1024)
            let created = leveling
                ? nr_processor_create(kind, paths.libraries.path, paths.models.path, &error, Int32(error.count))
                : nr_denoiser_create(kind, paths.libraries.path, paths.models.path, &error, Int32(error.count))
            guard let model = created else {
                throw AudioFailure("\(name): \(String(cString: error))")
            }
            defer { if leveling { nr_processor_destroy(model) } else { nr_denoiser_destroy(model) } }
            var output = [Float](); output.reserveCapacity(samples.count + 480)
            var frame = [Float](repeating: 0, count: 480)
            var clean = frame
            var timings = [Double]()
            var gains = [Float]()
            for offset in stride(from: 0, to: samples.count, by: 480) {
                let count = min(480, samples.count - offset)
                for i in 0..<480 { frame[i] = i < count ? samples[offset + i] : 0 }
                let start = CFAbsoluteTimeGetCurrent()
                let ok = leveling ? nr_processor_process(model, frame, &clean, true, false) : nr_denoiser_process(model, frame, &clean)
                guard ok, clean.allSatisfy(\.isFinite) else {
                    throw AudioFailure("\(name) produced invalid audio.")
                }
                timings.append((CFAbsoluteTimeGetCurrent() - start) * 1000)
                if leveling { gains.append(nr_processor_gain_db(model)) }
                output.append(contentsOf: clean.prefix(count))
            }
            let outBuffer = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: AVAudioFrameCount(output.count))!
            outBuffer.frameLength = AVAudioFrameCount(output.count)
            output.withUnsafeBufferPointer { ptr in outBuffer.floatChannelData![0].update(from: ptr.baseAddress!, count: ptr.count) }
            let outputURL = destination.appendingPathComponent(name + (leveling ? "-leveled" : "") + ".wav")
            let file = try AVAudioFile(forWriting: outputURL, settings: buffer.format.settings)
            try file.write(from: outBuffer)
            let sorted = timings.sorted()
            let mean = timings.reduce(0, +) / Double(timings.count)
            let p95 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
            print(String(format: "%@: %.2f ms mean, %.2f ms p95 per 10 ms frame · %@", name, mean, p95, outputURL.path))
            results.append(["engine": name, "frames": output.count, "sampleRate": 48000,
                            "meanProcessingMS": mean, "p95ProcessingMS": p95, "realTimeFactor": mean / 10,
                            "peak": output.map(abs).max() ?? 0, "output": outputURL.path,
                            "voiceLeveling": leveling, "minimumGainDB": gains.min() ?? 0, "maximumGainDB": gains.max() ?? 0])
        }
        let json = try JSONSerialization.data(withJSONObject: ["input": inputURL.path, "engines": results,
            "note": "Processing time only; capture and playback buffers add latency. Outputs include each streaming model's startup delay. No objective speech-quality ranking is inferred."], options: [.prettyPrinted, .sortedKeys])
        try json.write(to: destination.appendingPathComponent(leveling ? "results-leveled.json" : "results.json"), options: .atomic)
    } catch { fail(error.localizedDescription) }
} else {
    let paths = RuntimePaths()
    for engine in NoiseEngine.allCases { print("\(engine.name): \(paths.isAvailable(engine) ? "ready" : "missing runtime/model")") }
    print("Main speaker: \(paths.mainSpeakerAvailable ? "ready" : "missing runtime/model")")
    print("\nAudio devices:")
    for device in AudioHardware.devices() { print("  \(device.name) · in \(device.inputChannels), out \(device.outputChannels)") }
    print("\nRunning audio apps:")
    for app in AudioHardware.applications() where !app.processIDs.isEmpty { print("  \(app.name) · \(app.processIDs.count) audio process(es)") }
    print("\nCompare a recording: swift run NoiseCheck benchmark input.wav output-folder [--level] [--main-speaker]")
}
