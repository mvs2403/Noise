import CoreAudio

/// The system option resolves again whenever macOS changes its playback device.
/// Only an explicit device choice is pinned to a UID across launches.
public enum AudioOutputSelection: Hashable, Sendable {
    case system
    case device(String)

    public init(restoring value: String?) {
        if let value, !value.isEmpty { self = .device(value) }
        else { self = .system }
    }

    public var storedValue: String {
        switch self {
        case .system: ""
        case .device(let uid): uid
        }
    }

    public func resolve(in devices: [AudioDevice], systemDefault: AudioDeviceID) -> AudioDevice? {
        devices.first { device in
            guard device.outputChannels > 0, !device.isVirtual else { return false }
            switch self {
            case .system: return device.id == systemDefault
            case .device(let uid): return device.uid == uid
            }
        }
    }
}
