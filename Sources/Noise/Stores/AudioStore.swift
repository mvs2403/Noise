import AppKit
import AVFoundation
import Foundation
import NoiseAudio
import Observation

private func savedReduction(_ key: String) -> Double {
    let value = UserDefaults.standard.object(forKey: key) as? Double ?? 1
    return value.isFinite ? min(1, max(0, value)) : 1
}

@MainActor @Observable final class AudioStore {
    static let shared = AudioStore()
    let router = AudioRouter()
    let runtime = RuntimePaths()
    let appPicker = ApplicationPicker()
    var applications: [AudioApplication] = []
    var devices: [AudioDevice] = []
    private(set) var appSelection = ApplicationSelection() {
        didSet {
            guard oldValue != appSelection else { return }
            UserDefaults.standard.set(appSelection.encoded(), forKey: "incoming.applications")
            incomingRouteChanged()
        }
    }
    // The legacy incoming.output key pinned the last used hardware. Start with
    // Follow Mac output unless the user explicitly overrides this new setting.
    var outputSelection = AudioOutputSelection(restoring: UserDefaults.standard.string(forKey: "incoming.outputSelection")) {
        didSet {
            guard oldValue != outputSelection else { return }
            UserDefaults.standard.set(outputSelection.storedValue, forKey: "incoming.outputSelection")
            incomingRouteChanged()
        }
    }
    private(set) var systemOutputID: AudioDevice.ID = 0
    var selectedInputUID = UserDefaults.standard.string(forKey: "outgoing.input") ?? "" {
        didSet { if oldValue != selectedInputUID { outgoingRouteChanged() } }
    }
    var incomingEngine = NoiseEngine(rawValue: UserDefaults.standard.object(forKey: "incoming.engine") as? Int ?? 0) ?? .dpdfnet {
        didSet { if oldValue != incomingEngine { incomingEngineChanged() } }
    }
    var outgoingEngine = NoiseEngine(rawValue: UserDefaults.standard.object(forKey: "outgoing.engine") as? Int ?? 0) ?? .dpdfnet {
        didSet { if oldValue != outgoingEngine { outgoingEngineChanged() } }
    }
    var incomingVoiceLeveling = UserDefaults.standard.object(forKey: "incoming.voiceLeveling") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(incomingVoiceLeveling, forKey: "incoming.voiceLeveling")
            let enabled = incomingVoiceLeveling
            Task { await router.setIncomingLeveling(enabled) }
        }
    }
    var outgoingVoiceLeveling = UserDefaults.standard.object(forKey: "outgoing.voiceLeveling") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(outgoingVoiceLeveling, forKey: "outgoing.voiceLeveling")
            let enabled = outgoingVoiceLeveling
            Task { await router.setOutgoingLeveling(enabled) }
        }
    }
    var incomingReduction = savedReduction("incoming.reduction") {
        didSet {
            UserDefaults.standard.set(incomingReduction, forKey: "incoming.reduction")
            let value = Float(incomingReduction)
            Task { await router.setIncomingStrength(value) }
        }
    }
    var outgoingReduction = savedReduction("outgoing.reduction") {
        didSet {
            UserDefaults.standard.set(outgoingReduction, forKey: "outgoing.reduction")
            let value = Float(outgoingReduction)
            Task { await router.setOutgoingStrength(value) }
        }
    }
    var microphoneVoices = VoiceMode(restoring: UserDefaults.standard.string(forKey: "outgoing.voices")) {
        didSet {
            UserDefaults.standard.set(microphoneVoices.rawValue, forKey: "outgoing.voices")
            if oldValue != microphoneVoices { outgoingRouteChanged() }
        }
    }
    var incomingVoices = VoiceMode(restoring: UserDefaults.standard.string(forKey: "incoming.voices")) {
        didSet {
            UserDefaults.standard.set(incomingVoices.rawValue, forKey: "incoming.voices")
            if oldValue != incomingVoices { incomingRouteChanged() }
        }
    }
    var showMenuBar = UserDefaults.standard.object(forKey: "interface.showMenuBar") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(showMenuBar, forKey: "interface.showMenuBar")
            AppPresence.update(showMenuBar: showMenuBar)
        }
    }
    var incomingRunning = false
    var incomingWaiting = false
    var outgoingRunning = false
    var incomingBusy = false
    var incomingConnectionDelayed = false
    var outgoingBusy = false
    var incomingBypass = false
    var outgoingBypass = false
    var incomingError: String?
    var outgoingError: String?
    var incomingStats = StreamStatistics()
    var outgoingStats = StreamStatistics()
    var installing = false
    var showDriverInstall = false
    var driverMessage: String?
    var applicationChooserSession = UUID()
    @ObservationIgnored private var monitor: Task<Void, Never>?
    @ObservationIgnored private var sleepObserver: NSObjectProtocol?
    @ObservationIgnored private var wakeObserver: NSObjectProtocol?
    @ObservationIgnored private var outputObserver: DefaultOutputObserver?
    @ObservationIgnored private var incomingOperation: UInt64 = 0
    @ObservationIgnored private var outgoingOperation: UInt64 = 0
    @ObservationIgnored private var incomingWanted = false
    @ObservationIgnored private var incomingRefreshPending = false
    @ObservationIgnored private var hardwareRefreshPending = false

    var outputs: [AudioDevice] { devices.filter { $0.outputChannels > 0 && !$0.isVirtual } }
    var inputs: [AudioDevice] { devices.filter { $0.inputChannels > 0 && !$0.isVirtual } }
    var virtualMicrophone: AudioDevice? { devices.first { $0.isNoiseMicrophone } }
    var selectedApps: [AudioApplication] { appSelection.resolve(in: applications) }
    var hasSelectedApps: Bool { !appSelection.applications.isEmpty }
    var selectedOutput: AudioDevice? { outputSelection.resolve(in: devices, systemDefault: systemOutputID) }
    var systemOutput: AudioDevice? { AudioOutputSelection.system.resolve(in: devices, systemDefault: systemOutputID) }
    var selectedInput: AudioDevice? { inputs.first { $0.uid == selectedInputUID } }
    var incomingEnabled: Bool { incomingRunning || incomingWaiting }
    var incomingWaitingLabel: String { selectedOutput == nil ? "Waiting for Mac output" : "Waiting for app audio" }
    var anyRunning: Bool { incomingEnabled || outgoingRunning }
    var canStop: Bool { anyRunning || incomingBusy || outgoingBusy }
    var anyFiltering: Bool { (incomingRunning && !incomingBypass) || (outgoingRunning && !outgoingBypass) }

    init() {
        refresh()
        let restored = ApplicationSelection(restoring: UserDefaults.standard.data(forKey: "incoming.applications"),
                                            legacyBundleID: UserDefaults.standard.string(forKey: "incoming.app"),
                                            available: applications)
        appSelection = ApplicationSelection(restored.applications.filter { $0.id != Bundle.main.bundleIdentifier })
        UserDefaults.standard.set(appSelection.encoded(), forKey: "incoming.applications")
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.stopAll() }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        outputObserver = DefaultOutputObserver { [weak self] in
            Task { @MainActor in self?.defaultOutputChanged() }
        }
        monitor = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                guard let self else { return }
                let stats = await router.statistics()
                incomingStats = stats.incoming; outgoingStats = stats.outgoing
                if incomingRunning && incomingStats.hasFailed && !incomingBusy {
                    // A disconnected output can fill the playback queue before
                    // its default-device notification reaches the main actor.
                    refresh()
                    if !incomingBusy {
                        await router.stopIncoming(); incomingRunning = false
                        incomingWanted = false
                        incomingError = "Processing could not keep up. Original app audio has been restored. Try RNNoise or another listening device."
                    }
                }
                if outgoingRunning && outgoingStats.hasFailed && !outgoingBusy {
                    await router.stopOutgoing(); outgoingRunning = false
                    outgoingError = "Microphone processing stopped. Select your physical microphone in the call app, or try another engine."
                }
                tick += 1
                if tick % 25 == 0 {
                    let oldInput = selectedInput?.id
                    refresh()
                    if outgoingRunning && (selectedInput?.id != oldInput || virtualMicrophone == nil) && !outgoingBusy {
                        await router.stopOutgoing(); outgoingRunning = false
                        outgoingError = "An audio device disconnected. Select your physical microphone in the call app."
                    }
                }
            }
        }
    }

    func refresh() {
        // HAL discovery can wait behind a capture setup/permission request.
        // Keep application selection responsive using the last complete catalog.
        guard !incomingBusy && !outgoingBusy else { hardwareRefreshPending = true; return }
        hardwareRefreshPending = false
        let previousGroup = AudioApplicationGroup(applications: selectedApps)
        let previousOutput = selectedOutput?.id
        devices = AudioHardware.devices()
        systemOutputID = AudioHardware.defaultOutput()
        applications = AudioHardware.applications()
        if selectedInputUID.isEmpty {
            selectedInputUID = inputs.first { $0.id == AudioHardware.defaultInput() }?.uid ?? inputs.first?.uid ?? ""
        }
        if incomingWanted && (previousOutput != selectedOutput?.id
            || previousGroup != AudioApplicationGroup(applications: selectedApps)
            || (incomingWaiting && selectedOutput != nil && selectedApps.contains { $0.isOutputActive })) {
            incomingRouteChanged()
        }
    }

    private func defaultOutputChanged() {
        if incomingBusy && incomingWanted && outputSelection == .system {
            incomingRefreshPending = true
        }
        refresh()
    }

    private func finishIncomingOperation() {
        incomingBusy = false
        incomingConnectionDelayed = false
        let reconnect = incomingRefreshPending
        incomingRefreshPending = false
        // A device change received during a permission prompt must not be lost.
        // Refresh first so a queued reconnect cannot reuse the old output.
        if hardwareRefreshPending { refresh() }
        if reconnect && !incomingBusy { setIncoming(incomingWanted) }
    }

    func selectApplications(_ references: [ApplicationReference]) {
        let selectedIDs = Set(references.map(\.id))
        var byID: [String: ApplicationReference] = [:]
        references.forEach { byID[$0.id] = $0 }
        for app in applications where selectedIDs.contains(app.id) { byID[app.id] = app.reference }
        appSelection = ApplicationSelection(Array(byID.values).filter { $0.id != Bundle.main.bundleIdentifier })
    }

    func prepareApplicationChooser() {
        refresh()
        applicationChooserSession = UUID()
    }

    func pickApplicationWindow() {
        appPicker.begin { [weak self] application in
            guard let self else { return }
            appSelection = ApplicationSelection(appSelection.applications + [application])
            refresh()
        }
    }

    func setIncomingFiltering(_ enabled: Bool) {
        guard !incomingBusy else { return }
        if enabled {
            if incomingRunning { setIncomingBypass(false); return }
            incomingBypass = false
        }
        setIncoming(enabled)
    }
    func setIncoming(_ enabled: Bool) {
        incomingWanted = enabled
        if incomingBusy { incomingRefreshPending = true; return }
        incomingOperation &+= 1
        let operation = incomingOperation
        incomingBusy = true; incomingError = nil
        incomingConnectionDelayed = false
        if enabled {
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                guard let self, incomingOperation == operation, incomingBusy else { return }
                incomingConnectionDelayed = true
            }
        }
        Task {
            defer { finishIncomingOperation() }
            if !enabled { await router.stopIncoming(); incomingRunning = false; incomingWaiting = false; return }
            let apps = selectedApps
            guard !apps.isEmpty else {
                await router.stopIncoming(); incomingRunning = false
                incomingWaiting = false
                if !incomingRefreshPending { incomingWanted = false }
                incomingError = "Choose at least one application first."; return
            }
            guard let output = selectedOutput else {
                await router.stopIncoming(); incomingRunning = false
                // macOS may briefly have no default output while headphones
                // disconnect. Keep Follow Mac output armed for its replacement.
                incomingWaiting = outputSelection == .system && incomingWanted
                if !incomingWaiting && !incomingRefreshPending { incomingWanted = false }
                incomingError = outputSelection == .system
                    ? "Waiting for a supported Mac output device. Original app audio has been restored."
                    : "The listening device disconnected. Choose another device or Follow Mac output. Original app audio has been restored."
                return
            }
            // Keep the feature armed while apps are idle, and resolve their live
            // audio processes when playback starts or a selected app launches.
            guard apps.contains(where: { $0.isOutputActive }), !AudioApplicationGroup(applications: apps).processIDs.isEmpty else {
                await router.stopIncoming()
                incomingRunning = false; incomingWaiting = true
                return
            }
            incomingWaiting = false
            do {
                try await router.startIncoming(engine: incomingEngine, apps: apps, output: output.id, bypass: incomingBypass, voiceLeveling: incomingVoiceLeveling,
                    strength: Float(incomingReduction), voiceMode: incomingVoices)
                guard incomingOperation == operation else { await router.stopIncoming(); return }
                incomingRunning = true
                await router.setIncomingStrength(Float(incomingReduction))
                await router.setIncomingLeveling(incomingVoiceLeveling)
            } catch {
                incomingRunning = false
                if !incomingRefreshPending { incomingWanted = false }
                incomingError = error.localizedDescription
            }
        }
    }
    func setOutgoing(_ enabled: Bool) {
        guard !outgoingBusy else { return }
        if !enabled {
            if outgoingRunning { setOutgoingBypass(true) }
            return
        }
        if outgoingRunning { setOutgoingBypass(false); return }
        outgoingBypass = false
        reconnectOutgoing()
    }
    private func reconnectOutgoing() {
        guard !outgoingBusy else { return }
        outgoingOperation &+= 1
        let operation = outgoingOperation
        outgoingBusy = true; outgoingError = nil
        Task {
            defer {
                outgoingBusy = false
                if hardwareRefreshPending { refresh() }
            }
            guard let input = selectedInput, let virtual = virtualMicrophone else {
                outgoingError = "Install Noise Microphone, then choose your physical microphone."; return
            }
            let allowed = await AVCaptureDevice.requestAccess(for: .audio)
            guard outgoingOperation == operation else { return }
            guard allowed else { outgoingError = "Allow Noise to use your microphone in System Settings → Privacy & Security → Microphone."; return }
            do {
                try await router.startOutgoing(engine: outgoingEngine, input: input.id, virtualMicrophone: virtual.id, bypass: outgoingBypass, voiceLeveling: outgoingVoiceLeveling,
                    strength: Float(outgoingReduction), voiceMode: microphoneVoices)
                guard outgoingOperation == operation else { await router.stopOutgoing(); return }
                outgoingRunning = true
                await router.setOutgoingStrength(Float(outgoingReduction))
                await router.setOutgoingLeveling(outgoingVoiceLeveling)
                UserDefaults.standard.set(input.uid, forKey: "outgoing.input")
            } catch { outgoingRunning = false; outgoingError = error.localizedDescription }
        }
    }
    func incomingEngineChanged() {
        UserDefaults.standard.set(incomingEngine.rawValue, forKey: "incoming.engine")
        incomingRouteChanged()
    }
    func outgoingEngineChanged() {
        UserDefaults.standard.set(outgoingEngine.rawValue, forKey: "outgoing.engine")
        if outgoingRunning { reconnectOutgoing() }
    }
    func incomingRouteChanged() { if incomingWanted { setIncoming(hasSelectedApps) } }
    func outgoingRouteChanged() { if outgoingRunning { reconnectOutgoing() } }
    func setIncomingBypass(_ value: Bool) { incomingBypass = value; Task { await router.setIncomingBypass(value) } }
    func setOutgoingBypass(_ value: Bool) { outgoingBypass = value; Task { await router.setOutgoingBypass(value) } }
    func stopAll() async {
        incomingOperation &+= 1; outgoingOperation &+= 1
        incomingWanted = false; incomingRefreshPending = false
        await router.stopAll()
        incomingRunning = false; incomingWaiting = false; outgoingRunning = false
    }

    func installDriver() {
        guard !installing else { return }
        installing = true; driverMessage = nil
        Task {
            await stopAll()
            do {
                guard let resources = Bundle.main.resourceURL else { throw AudioFailure("Open the bundled Noise.app first.") }
                let script = resources.appendingPathComponent("install_microphone.sh")
                let driver = resources.appendingPathComponent("NoiseMicrophone.driver")
                guard FileManager.default.fileExists(atPath: script.path), FileManager.default.fileExists(atPath: driver.path) else {
                    throw AudioFailure("The driver is missing. Rebuild with script/build_and_run.sh.")
                }
                let result = await Task.detached { () -> (Int32, String) in
                    // AppleScript receives an escaped literal, never user-supplied shell commands.
                    func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
                    let command = shellQuote(script.path) + " " + shellQuote(driver.path)
                    let literal = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                    process.arguments = ["-e", "do shell script \"\(literal)\" with administrator privileges"]
                    let errors = Pipe(); process.standardError = errors
                    do {
                        try process.run()
                        let text = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                        process.waitUntilExit()
                        return (process.terminationStatus, text)
                    } catch { return (-1, error.localizedDescription) }
                }.value
                if result.0 != 0 { throw AudioFailure(result.1.isEmpty ? "Installation was cancelled." : result.1) }
                // coreaudiod restarts asynchronously; refresh until the new device appears.
                for _ in 0..<12 {
                    try? await Task.sleep(for: .milliseconds(500))
                    refresh()
                    if virtualMicrophone != nil { break }
                }
                driverMessage = virtualMicrophone == nil
                    ? "Installed. If Noise Microphone is not listed yet, restart Noise or sign out and back in."
                    : "Ready. Select Noise Microphone as the microphone in Teams, Zoom or your call app."
            } catch { driverMessage = error.localizedDescription }
            installing = false
        }
    }
    func openAudioPrivacy() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture") { NSWorkspace.shared.open(url) }
    }

}
