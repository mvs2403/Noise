import Foundation
import CoreAudio
import CNoiseRuntime

public struct StreamStatistics: Sendable {
    public var inputPeak: Float = 0
    public var outputPeak: Float = 0
    public var processingMilliseconds: Float = 0
    public var inputFrames: UInt64 = 0
    public var underrunFrames: UInt64 = 0
    public var droppedFrames: UInt64 = 0
    public var hasFailed = false
    public var voiceGainDB: Float = 0
    public init() {}
    init(_ value: NRStats) {
        inputPeak = value.input_peak; outputPeak = value.output_peak
        processingMilliseconds = value.processing_ms; inputFrames = value.input_frames
        underrunFrames = value.underrun_frames; droppedFrames = value.dropped_frames
        hasFailed = value.failed != 0
        voiceGainDB = value.voice_gain_db
    }
}

// All ownership transitions are serialized. Audio callbacks stay entirely in the C++ runtime.
public actor AudioRouter {
    private var incoming: OpaquePointer?
    private var outgoing: OpaquePointer?
    private let paths: RuntimePaths
    public init(paths: RuntimePaths = RuntimePaths()) { self.paths = paths }

    private func make(_ engine: NoiseEngine, voiceMode: VoiceMode) throws -> OpaquePointer {
        var error = [CChar](repeating: 0, count: 1024)
        guard let p = nr_pipeline_create(voiceMode.runtimeEngine(for: engine), paths.libraries.path, paths.models.path, &error, Int32(error.count)) else {
            throw AudioFailure(String(cString: error))
        }
        return p
    }
    public func startIncoming(engine: NoiseEngine, apps: [AudioApplication], output: AudioDeviceID, bypass: Bool, voiceLeveling: Bool,
                              strength: Float = 1, voiceMode: VoiceMode = .all) throws {
        let group = AudioApplicationGroup(applications: apps)
        guard !group.bundleIDs.isEmpty else { throw AudioFailure("Choose at least one application first.") }
        stopIncoming()
        let p = try make(engine, voiceMode: voiceMode)
        var adopted = false
        defer { if !adopted { nr_pipeline_destroy(p) } }
        nr_pipeline_set_strength(p, strength)
        nr_pipeline_set_leveling(p, voiceLeveling)
        nr_pipeline_set_bypass(p, bypass)
        var error = [CChar](repeating: 0, count: 1024)
        guard nr_pipeline_start_output(p, output, &error, Int32(error.count)) else { throw AudioFailure(String(cString: error)) }
        let ok = group.processIDs.withUnsafeBufferPointer { ids in
            nr_pipeline_start_apps(p, ids.baseAddress, Int32(ids.count), &error, Int32(error.count))
        }
        guard ok else { throw AudioFailure(String(cString: error)) }
        incoming = p; adopted = true
    }
    public func startOutgoing(engine: NoiseEngine, input: AudioDeviceID, virtualMicrophone: AudioDeviceID, bypass: Bool, voiceLeveling: Bool,
                              strength: Float = 1, voiceMode: VoiceMode = .all) throws {
        stopOutgoing()
        guard input != virtualMicrophone else { throw AudioFailure("Choose your physical microphone as the input.") }
        let p = try make(engine, voiceMode: voiceMode)
        var adopted = false
        defer { if !adopted { nr_pipeline_destroy(p) } }
        nr_pipeline_set_strength(p, strength)
        nr_pipeline_set_leveling(p, voiceLeveling)
        nr_pipeline_set_bypass(p, bypass)
        var error = [CChar](repeating: 0, count: 1024)
        guard nr_pipeline_start_output(p, virtualMicrophone, &error, Int32(error.count)),
              nr_pipeline_start_microphone(p, input, &error, Int32(error.count)) else {
            throw AudioFailure(String(cString: error))
        }
        outgoing = p; adopted = true
    }
    public func stopIncoming() { if let p = incoming { nr_pipeline_destroy(p) }; incoming = nil }
    public func stopOutgoing() { if let p = outgoing { nr_pipeline_destroy(p) }; outgoing = nil }
    public func stopAll() { stopIncoming(); stopOutgoing() }
    public func setIncomingBypass(_ bypass: Bool) { if let p = incoming { nr_pipeline_set_bypass(p, bypass) } }
    public func setOutgoingBypass(_ bypass: Bool) { if let p = outgoing { nr_pipeline_set_bypass(p, bypass) } }
    public func setIncomingLeveling(_ enabled: Bool) { if let p = incoming { nr_pipeline_set_leveling(p, enabled) } }
    public func setOutgoingLeveling(_ enabled: Bool) { if let p = outgoing { nr_pipeline_set_leveling(p, enabled) } }
    public func setIncomingStrength(_ strength: Float) { if let p = incoming { nr_pipeline_set_strength(p, strength) } }
    public func setOutgoingStrength(_ strength: Float) { if let p = outgoing { nr_pipeline_set_strength(p, strength) } }

    public func statistics() -> (incoming: StreamStatistics, outgoing: StreamStatistics) {
        (incoming.map { StreamStatistics(nr_pipeline_stats($0)) } ?? StreamStatistics(),
         outgoing.map { StreamStatistics(nr_pipeline_stats($0)) } ?? StreamStatistics())
    }
}
