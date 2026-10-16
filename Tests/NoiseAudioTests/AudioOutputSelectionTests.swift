import XCTest
@testable import NoiseAudio

final class AudioOutputSelectionTests: XCTestCase {
    private let speakers = AudioDevice(id: 10, uid: "speakers", name: "Mac speakers", inputChannels: 0, outputChannels: 2)
    private let headphones = AudioDevice(id: 20, uid: "headphones", name: "Headphones", inputChannels: 1, outputChannels: 2)

    func testFollowMacIsTheDefaultAndSurvivesPreferenceRoundTrip() {
        XCTAssertEqual(AudioOutputSelection(restoring: nil), .system)
        let restored = AudioOutputSelection(restoring: AudioOutputSelection.system.storedValue)
        XCTAssertEqual(restored, .system)
    }

    func testFollowingMacReResolvesEachOutputChangeWithoutChangingThePreference() {
        let selection = AudioOutputSelection.system
        let devices = [speakers, headphones]
        XCTAssertEqual(selection.resolve(in: devices, systemDefault: speakers.id), speakers)
        XCTAssertEqual(selection.resolve(in: devices, systemDefault: headphones.id), headphones)
        XCTAssertEqual(selection.resolve(in: devices, systemDefault: speakers.id), speakers)
        XCTAssertEqual(selection.storedValue, "")
    }

    func testExplicitOverrideUsesUIDAcrossDeviceReconnectionAndIgnoresSystemChanges() {
        let selection = AudioOutputSelection(restoring: AudioOutputSelection.device(headphones.uid).storedValue)
        XCTAssertEqual(selection, .device(headphones.uid))
        XCTAssertEqual(selection.resolve(in: [speakers, headphones], systemDefault: speakers.id), headphones)
        let reconnected = AudioDevice(id: 99, uid: headphones.uid, name: headphones.name, inputChannels: 1, outputChannels: 2)
        XCTAssertEqual(selection.resolve(in: [speakers, reconnected], systemDefault: speakers.id), reconnected)
        XCTAssertNil(selection.resolve(in: [speakers], systemDefault: speakers.id))
    }

    func testMissingDefaultDoesNotSilentlyPickAnotherDeviceAndCanRecover() {
        let selection = AudioOutputSelection.system
        XCTAssertNil(selection.resolve(in: [speakers], systemDefault: 0))
        XCTAssertNil(selection.resolve(in: [speakers], systemDefault: headphones.id))
        XCTAssertEqual(selection.resolve(in: [speakers, headphones], systemDefault: headphones.id), headphones)
    }

    func testInputOnlyAndVirtualMicrophoneCannotBecomeListeningOutputs() {
        let microphone = AudioDevice(id: 30, uid: "microphone", name: "Microphone", inputChannels: 1, outputChannels: 0)
        let virtual = AudioDevice(id: 40, uid: "Noise Microphone_UID", name: "Noise Microphone", inputChannels: 2, outputChannels: 2)
        let devices = [speakers, microphone, virtual]
        for invalid in [microphone, virtual] {
            XCTAssertNil(AudioOutputSelection.system.resolve(in: devices, systemDefault: invalid.id))
            XCTAssertNil(AudioOutputSelection.device(invalid.uid).resolve(in: devices, systemDefault: speakers.id))
        }
    }
}
