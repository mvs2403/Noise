import SwiftUI
import NoiseAudio

struct ContentView: View {
    @Bindable var store: AudioStore
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                header
                HStack(alignment: .top, spacing: 18) {
                    incomingCard.frame(maxWidth: .infinity)
                    outgoingCard.frame(maxWidth: .infinity)
                }
                comparisonGuide
                HStack(spacing: 8) {
                    Image(systemName: "lock.shield")
                    Text("Audio is processed on this Mac. Nothing is uploaded.")
                    Spacer()
                    SettingsLink { Image(systemName: "gearshape") }
                        .help("Settings and setup")
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            .padding(30)
        }
        .toolbar {
            ToolbarItemGroup {
                Button { store.refresh() } label: { Label("Refresh Apps & Devices", systemImage: "arrow.clockwise") }
                    .help("Refresh running apps and audio devices")
                Button { Task { await store.stopAll() } } label: { Label("Stop All", systemImage: "stop.circle") }
                    .disabled(!store.canStop)
            }
        }
        .sheet(isPresented: $store.showDriverInstall) { DriverInstallSheet(store: store) }
    }
    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 8) {
                Label("NOISE", systemImage: "waveform")
                    .font(.system(size: 12, weight: .semibold)).tracking(2).foregroundStyle(.secondary)
                Text("Clear calls. Both ways.").font(.system(size: 32, weight: .semibold, design: .rounded))
                Text("Clean what you hear and what they hear, independently.")
                    .font(.body).foregroundStyle(.secondary)
            }
            Spacer()
            Label(store.incomingWaiting ? store.incomingWaitingLabel : (store.anyFiltering ? "Filtering on device" : (store.anyRunning ? "Original audio connected" : "Ready when you are")), systemImage: store.anyFiltering ? "checkmark.circle.fill" : "circle")
                .font(.caption.weight(.medium)).foregroundStyle(store.anyFiltering ? .green : .secondary)
                .padding(.top, 8)
        }
    }
    private var incomingCard: some View {
        AudioCard(title: "What you hear", subtitle: "Remove their background noise", icon: "ear", isRunning: store.incomingEnabled, isBusy: store.incomingBusy, onToggle: store.setIncoming) {
            VStack(alignment: .leading, spacing: 16) {
                field("Applications") {
                    ApplicationSelectionButton(store: store)
                }
                field("Listen through") {
                    Picker("Listening device", selection: $store.outputSelection) {
                        Text("Follow Mac output").tag(AudioOutputSelection.system)
                        Divider()
                        if case .device = store.outputSelection, store.selectedOutput == nil {
                            Text("Unavailable device").tag(store.outputSelection)
                        }
                        ForEach(store.outputs) { Text($0.name).tag(AudioOutputSelection.device($0.uid)) }
                    }.labelsHidden().disabled(store.incomingBusy)
                    if store.outputSelection == .system {
                        Text("Currently: \(store.systemOutput?.name ?? "No supported output device")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if store.incomingVoices == .mainSpeaker {
                    Label("Main speaker · Automatic", systemImage: "person.wave.2")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    EnginePicker(selection: $store.incomingEngine, runtime: store.runtime).disabled(store.incomingBusy)
                }
                VoiceLevelingControl(enabled: $store.incomingVoiceLeveling,
                                     processing: store.incomingRunning && !store.incomingBypass,
                                     gainDB: store.incomingStats.voiceGainDB)
                ComparisonControl(bypass: Binding(get: { store.incomingBypass }, set: store.setIncomingBypass), enabled: store.incomingRunning && !store.incomingBusy)
                StreamMeter(statistics: store.incomingStats, running: store.incomingRunning, bypass: store.incomingBypass,
                            waiting: store.incomingWaiting, waitingLabel: store.incomingWaitingLabel)
                if let error = store.incomingError { ErrorNotice(text: error) }
                if store.incomingConnectionDelayed {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("macOS is still connecting audio. Respond to any audio-recording permission dialog, or check Audio Privacy settings.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Audio Privacy…") { store.openAudioPrivacy() }.controlSize(.small)
                    }
                }
                Text("Selected apps share one engine. Turn this off to restore their normal audio.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    private var outgoingCard: some View {
        AudioCard(title: "What they hear", subtitle: "Remove your background noise", icon: "mic", isRunning: store.outgoingRunning && !store.outgoingBypass, isBusy: store.outgoingBusy, onToggle: store.setOutgoing) {
            VStack(alignment: .leading, spacing: 16) {
                field("Your microphone") {
                    Picker("Your microphone", selection: $store.selectedInputUID) {
                        if store.selectedInput == nil { Text("Choose a microphone…").tag(store.selectedInputUID) }
                        ForEach(store.inputs) { Text($0.name).tag($0.uid) }
                    }.labelsHidden().disabled(store.outgoingBusy)
                }
                field("Microphone in your call app") {
                    HStack(spacing: 6) {
                        Image(systemName: store.virtualMicrophone == nil ? "circle.dashed" : "checkmark.circle.fill")
                            .foregroundStyle(store.virtualMicrophone == nil ? Color.secondary : .green)
                        Text("Noise Microphone").font(.callout)
                        Spacer()
                        if store.virtualMicrophone == nil {
                            Button("Set up…") { store.showDriverInstall = true }.controlSize(.small)
                        }
                    }.frame(height: 22)
                }
                if store.microphoneVoices == .mainSpeaker {
                    Label("Main speaker · Automatic", systemImage: "person.wave.2")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    EnginePicker(selection: $store.outgoingEngine, runtime: store.runtime).disabled(store.outgoingBusy)
                }
                VoiceLevelingControl(enabled: $store.outgoingVoiceLeveling,
                                     processing: store.outgoingRunning && !store.outgoingBypass,
                                     gainDB: store.outgoingStats.voiceGainDB)
                ComparisonControl(bypass: Binding(get: { store.outgoingBypass }, set: store.setOutgoingBypass), enabled: store.outgoingRunning && !store.outgoingBusy)
                StreamMeter(statistics: store.outgoingStats, running: store.outgoingRunning, bypass: store.outgoingBypass)
                if let error = store.outgoingError { ErrorNotice(text: error) }
                Text("Select Noise Microphone in your call app. Switching cancellation off passes your original voice through. Keep Noise open while it is selected.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    @ViewBuilder private func field<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.medium)).foregroundStyle(.secondary)
            content().frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private var comparisonGuide: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Find the right engine for your calls", systemImage: "slider.horizontal.3")
                    .font(.headline)
                Spacer()
                Text("3 engines").font(.caption).foregroundStyle(.secondary)
            }
            Text("Choose an engine in either panel. While filtering is on, switch between Original and Cleaned to compare. Changing an engine reconnects that audio path.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: 18) {
                ForEach(NoiseEngine.allCases) { engine in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(engine.name).font(.callout.weight(.semibold))
                        Text(engine.detail).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Divider()
            Text("Speech is kept; background sounds are reduced. Other voices, heavy distortion and noise already baked into the call may remain. Calls are processed in mono.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 14))
    }
}
