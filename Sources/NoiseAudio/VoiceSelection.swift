import Foundation
import CNoiseRuntime

public enum VoiceMode: String, CaseIterable, Identifiable, Sendable {
    case all
    case mainSpeaker = "main"
    public var id: Self { self }
    public var title: String { self == .all ? "All voices" : "Main speaker" }

    public init(restoring value: String?) {
        // Replace the old sample-based choices without requiring enrollment.
        if value == "mine" || value == "selected" { self = .mainSpeaker }
        else { self = Self(rawValue: value ?? "all") ?? .all }
    }

    public func runtimeEngine(for engine: NoiseEngine) -> Int32 {
        self == .mainSpeaker ? Int32(NR_MAIN_SPEAKER) : Int32(engine.rawValue)
    }
}
