import CoreAudio
import Foundation

/// Core Audio delivers changes off the audio thread. The owner schedules its
/// catalog refresh and route changes on its own actor; the listener only signals.
public final class DefaultOutputObserver {
    private let queue = DispatchQueue(label: "za.co.mvs.Noise.default-output")
    private let listener: AudioObjectPropertyListenerBlock
    private var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    private var registered = false

    public init(onChange: @escaping @Sendable () -> Void) {
        listener = { count, addresses in
            if UnsafeBufferPointer(start: addresses, count: Int(count)).contains(where: {
                $0.mSelector == kAudioHardwarePropertyDefaultOutputDevice
            }) { onChange() }
        }
        registered = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, queue, listener) == noErr
        // The store's periodic refresh remains a fallback if registration fails.
    }

    deinit {
        if registered {
            AudioObjectRemovePropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, queue, listener)
        }
    }
}
