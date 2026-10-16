import AppKit
import CoreAudio

public struct AudioDevice: Identifiable, Equatable, Sendable {
    public let id: AudioDeviceID
    public let uid: String
    public let name: String
    public let inputChannels: Int
    public let outputChannels: Int
    public var isNoiseMicrophone: Bool { uid == "Noise Microphone_UID" }
    public var isVirtual: Bool { isNoiseMicrophone || uid.lowercased().contains("blackhole") }
}

public enum AudioHardware {
    private static func address(_ selector: AudioObjectPropertySelector,
                                scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }
    public static func objects(_ object: AudioObjectID, selector: AudioObjectPropertySelector) -> [AudioObjectID] {
        var a = address(selector)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &a, 0, nil, &size) == noErr else { return [] }
        guard size > 0 else { return [] }
        var values = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        let status = values.withUnsafeMutableBytes { bytes in
            AudioObjectGetPropertyData(object, &a, 0, nil, &size, bytes.baseAddress!)
        }
        return status == noErr ? values : []
    }
    public static func string(_ object: AudioObjectID, selector: AudioObjectPropertySelector) -> String {
        var a = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &a, 0, nil, &size, $0)
        }
        guard status == noErr, let value else { return "" }
        return value.takeRetainedValue() as String
    }
    public static func integer(_ object: AudioObjectID, selector: AudioObjectPropertySelector) -> UInt32 {
        var a = address(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        _ = AudioObjectGetPropertyData(object, &a, 0, nil, &size, &value)
        return value
    }
    private static func channels(_ object: AudioObjectID, scope: AudioObjectPropertyScope) -> Int {
        var a = address(kAudioDevicePropertyStreamConfiguration, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &a, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let memory = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { memory.deallocate() }
        guard AudioObjectGetPropertyData(object, &a, 0, nil, &size, memory) == noErr else { return 0 }
        return UnsafeMutableAudioBufferListPointer(memory.assumingMemoryBound(to: AudioBufferList.self))
            .reduce(0) { $0 + Int($1.mNumberChannels) }
    }
    public static func devices() -> [AudioDevice] {
        objects(AudioObjectID(kAudioObjectSystemObject), selector: kAudioHardwarePropertyDevices).compactMap { id in
            let uid = string(id, selector: kAudioDevicePropertyDeviceUID)
            guard !uid.isEmpty else { return nil }
            return AudioDevice(id: id, uid: uid, name: string(id, selector: kAudioObjectPropertyName),
                               inputChannels: channels(id, scope: kAudioDevicePropertyScopeInput),
                               outputChannels: channels(id, scope: kAudioDevicePropertyScopeOutput))
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    public static func defaultInput() -> AudioDeviceID {
        integer(AudioObjectID(kAudioObjectSystemObject), selector: kAudioHardwarePropertyDefaultInputDevice)
    }
    public static func defaultOutput() -> AudioDeviceID {
        integer(AudioObjectID(kAudioObjectSystemObject), selector: kAudioHardwarePropertyDefaultOutputDevice)
    }
    public static func applications() -> [AudioApplication] {
        let running = NSWorkspace.shared.runningApplications.filter {
            $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && $0.activationPolicy == .regular
        }
        var grouped: [String: [AudioObjectID]] = [:]
        var active = Set<String>()
        var names: [String: String] = [:]
        var urls: [String: URL] = [:]
        for app in running {
            guard let bundleID = app.bundleIdentifier else { continue }
            names[bundleID] = app.localizedName ?? bundleID
            urls[bundleID] = app.bundleURL
        }
        let audioProcesses = objects(AudioObjectID(kAudioObjectSystemObject), selector: kAudioHardwarePropertyProcessObjectList)
        for process in audioProcesses {
            let pid = pid_t(integer(process, selector: kAudioProcessPropertyPID))
            guard pid != ProcessInfo.processInfo.processIdentifier else { continue }
            let app = NSRunningApplication(processIdentifier: pid)
            let reportedID = string(process, selector: kAudioProcessPropertyBundleID)
            var bundleID = app?.bundleIdentifier ?? reportedID
            if let path = app?.bundleURL?.path, let outer = path.range(of: ".app/") {
                let root = URL(fileURLWithPath: String(path[..<outer.lowerBound]) + ".app")
                if let identifier = Bundle(url: root)?.bundleIdentifier { bundleID = identifier }
            }
            guard !bundleID.isEmpty, bundleID != Bundle.main.bundleIdentifier else { continue }
            // Electron helpers may report a helper bundle ID despite living under the parent app.
            if let parent = running.first(where: { app?.bundleURL?.path.hasPrefix(($0.bundleURL?.path ?? "___") + "/") == true }),
               let parentID = parent.bundleIdentifier { bundleID = parentID }
            if names[bundleID] == nil,
               let parentID = names.keys.sorted(by: { $0.count > $1.count }).first(where: { reportedID.hasPrefix($0 + ".") }) {
                bundleID = parentID
            }
            guard names[bundleID] != nil else { continue }
            grouped[bundleID, default: []].append(process)
            if integer(process, selector: kAudioProcessPropertyIsRunningOutput) != 0 { active.insert(bundleID) }
        }
        return names.map { id, name in
            AudioApplication(id: id, name: name, processIDs: (grouped[id] ?? []).sorted(), bundleURL: urls[id], isOutputActive: active.contains(id))
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
