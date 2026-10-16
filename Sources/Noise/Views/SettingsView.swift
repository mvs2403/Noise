import AppKit
import SwiftUI
import NoiseAudio

struct SettingsView: View {
    @Bindable var store: AudioStore
    @State private var showDriverInstall = false
    var body: some View {
        Form {
            Section("Menu bar") {
                Toggle("Show controls in menu bar", isOn: $store.showMenuBar)
                    .toggleStyle(.switch)
                Text("Open the menu-bar icon for Speaker and Microphone tabs. Turn cancellation on to adjust noise reduction and voice leveling.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Noise keeps running when you close its windows, without a Dock icon. If you hide the menu-bar controls, Noise appears in the Dock so you can still reopen it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Incoming audio · What you hear") {
                Picker("Voices", selection: $store.incomingVoices) {
                    ForEach(VoiceMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }.pickerStyle(.segmented).disabled(store.incomingBusy)
                    .accessibilityLabel("Incoming voices")
                voiceDescription(store.incomingVoices)
                if store.incomingVoices == .mainSpeaker {
                    LabeledContent("Filter", value: "Hush · Automatic")
                } else {
                    enginePicker("Speaker engine", selection: $store.incomingEngine, busy: store.incomingBusy)
                }
                reductionSlider($store.incomingReduction, direction: "Incoming")
                Toggle("Voice leveling", isOn: $store.incomingVoiceLeveling).toggleStyle(.switch)
            }
            Section("Microphone · What they hear") {
                Picker("Voices", selection: $store.microphoneVoices) {
                    ForEach(VoiceMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }.pickerStyle(.segmented).disabled(store.outgoingBusy)
                    .accessibilityLabel("Microphone voices")
                voiceDescription(store.microphoneVoices)
                if store.microphoneVoices == .mainSpeaker {
                    LabeledContent("Filter", value: "Hush · Automatic")
                } else {
                    enginePicker("Microphone engine", selection: $store.outgoingEngine, busy: store.outgoingBusy)
                }
                reductionSlider($store.outgoingReduction, direction: "Microphone")
                Toggle("Voice leveling", isOn: $store.outgoingVoiceLeveling).toggleStyle(.switch)
            }
            Section("About voice filtering") {
                Text("Main speaker is experimental. It aims to keep the dominant foreground voice while reducing quieter background speech and room noise. No voice sample or saved identity is needed. It follows the audio as speakers change.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Main speaker uses Hush at speech bandwidth (16 kHz). It works best when the foreground voice is clearly stronger than the others. Similar-volume voices, strong overlap, and call apps that already equalized everyone can reduce its accuracy. It may also soften the intended voice; try it on your usual calls.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("All voices uses your chosen noise engine, with DPDFNet as the default. Voice leveling applies to the resulting speech. Lowering Noise reduction lets more background sound and voices through. Original audio skips all processing.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Outgoing microphone") {
                LabeledContent("Noise Microphone", value: store.virtualMicrophone == nil ? "Not installed" : "Installed")
                Button(store.virtualMicrophone == nil ? "Set Up Virtual Microphone…" : "Reinstall Virtual Microphone…") {
                    showDriverInstall = true
                }
                Text("The incoming audio filter works without this driver. The driver lets call apps receive your cleaned microphone.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Permissions") {
                Text("Incoming audio needs System Audio Recording access. Outgoing audio also needs Microphone access. macOS asks when you turn on each path.")
                    .font(.callout)
                Button("Open Audio Privacy Settings") { store.openAudioPrivacy() }
            }
            Section("Engine availability") {
                ForEach(NoiseEngine.allCases) { engine in
                    LabeledContent(engine.name, value: store.runtime.isAvailable(engine) ? "Ready" : "Missing runtime or model")
                }
                LabeledContent("Main speaker · Hush", value: store.runtime.mainSpeakerAvailable ? "Ready · on device" : "Missing runtime or model")
            }
            Section("Using Noise on a call") {
                Text("1. Select applications under What you hear. Use the checkboxes, Use current app, or Pick a window.\n2. Turn incoming filtering on. Follow Mac output routes to your current macOS speakers or headphones and follows device changes. Selected apps share one engine and voice leveler.\n3. For outgoing filtering, select your real microphone in Noise and Noise Microphone in the call app.\n4. Turn outgoing filtering on. Return to your real microphone in the call app before quitting Noise.")
                    .font(.callout).lineSpacing(5)
                Text("Headphones avoid speaker-to-microphone feedback. Noise suppression does not replace a call app’s acoustic echo cancellation.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped).frame(width: 560, height: 760)
        .sheet(isPresented: $showDriverInstall) { DriverInstallSheet(store: store) }
    }

    private func enginePicker(_ title: String, selection: Binding<NoiseEngine>, busy: Bool) -> some View {
        Picker(title, selection: selection) {
            ForEach(NoiseEngine.allCases) { engine in
                Text(engine.name + (store.runtime.isAvailable(engine) ? "" : " · not installed"))
                    .tag(engine).disabled(!store.runtime.isAvailable(engine))
            }
        }.disabled(busy)
    }

    private func voiceDescription(_ mode: VoiceMode) -> some View {
        Text(mode == .all
             ? "Reduce room noise without selecting a speaker. Voice leveling raises quiet speech and softens loud speech."
             : "Automatically favor the dominant foreground voice and reduce quieter background voices. Uses Hush; no sample needed.")
            .font(.caption).foregroundStyle(.secondary)
    }

    private func reductionSlider(_ selection: Binding<Double>, direction: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("Noise reduction")
                Spacer()
                Text(selection.wrappedValue, format: .percent.precision(.fractionLength(0)))
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: selection, in: 0...1, step: 0.05) { Text("Noise reduction strength") }
                .labelsHidden()
                .accessibilityLabel("\(direction) noise reduction strength")
                .accessibilityValue("\(Int((selection.wrappedValue * 100).rounded())) percent")
            HStack { Text("Original"); Spacer(); Text("Maximum") }
                .font(.caption).foregroundStyle(.secondary)
            Text("Lower values keep more room sound. Higher values remove more background noise.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding(.vertical, 4)
    }
}

struct DriverInstallSheet: View {
    @Bindable var store: AudioStore
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(systemName: "mic.badge.plus").font(.system(size: 34)).foregroundStyle(.tint)
            Text("Set up Noise Microphone").font(.title2.weight(.semibold))
            Text("This adds a virtual microphone to macOS so Teams and other call apps can hear your cleaned voice.")
            Text("macOS will ask for an administrator password. Installation restarts the Mac’s audio service and briefly interrupts audio. Install before joining a call.")
                .font(.callout).foregroundStyle(.secondary)
            if let message = store.driverMessage { Text(message).font(.callout).textSelection(.enabled) }
            HStack {
                if store.installing { ProgressView().controlSize(.small); Text("Installing…").font(.caption) }
                Spacer()
                Button(store.virtualMicrophone == nil ? "Cancel" : "Done") { dismiss() }.disabled(store.installing)
                Button("Install Microphone") { store.installDriver() }
                    .buttonStyle(.borderedProminent).disabled(store.installing)
            }
        }.padding(28).frame(width: 450)
    }
}
