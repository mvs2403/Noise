import AppKit
import SwiftUI

struct MenuBarPanel: View {
    @Bindable var store: AudioStore
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss
    @State private var tab: AudioTab = .speaker

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 9) {
                Image(systemName: "waveform").font(.title2).foregroundStyle(.tint)
                Text("Noise").font(.headline)
                Spacer()
                SettingsLink { Image(systemName: "gearshape") }
                    .buttonStyle(.plain).help("Noise settings")
                    .accessibilityLabel("Noise settings")
            }

            Picker("Audio direction", selection: $tab) {
                ForEach(AudioTab.allCases) { tab in
                    Label(tab.title, systemImage: tab.icon)
                        .labelStyle(.iconOnly)
                        .help(tab.title)
                        .tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.regular)

            VStack(alignment: .leading, spacing: 5) {
                Text(tab == .speaker ? "What you hear" : "What they hear")
                    .font(.headline)
                context
            }

            VStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Noise cancellation")
                        Spacer()
                        if busy { ProgressView().controlSize(.small) }
                        Toggle("Noise cancellation", isOn: filtering)
                            .labelsHidden()
                            .disabled(busy || !canEnable)
                    }
                    if filtering.wrappedValue {
                        VStack(spacing: 3) {
                            HStack {
                                Text("Noise reduction")
                                Spacer()
                                Text(reduction.wrappedValue, format: .percent.precision(.fractionLength(0)))
                                    .monospacedDigit()
                            }.font(.caption).foregroundStyle(.secondary)
                            Slider(value: reduction, in: 0...1, step: 0.05) {
                                Text("Noise reduction strength")
                            }
                            .labelsHidden()
                            .accessibilityLabel("\(tab.title) noise reduction strength")
                            .accessibilityValue("\(Int((reduction.wrappedValue * 100).rounded())) percent")
                            .disabled(busy)
                        }
                    }
                }
                HStack {
                    Text("Voice leveling")
                        .foregroundStyle(filtering.wrappedValue ? .primary : .tertiary)
                    Spacer()
                    Toggle("Voice leveling", isOn: leveling)
                        .labelsHidden()
                        .help("Quiet voices up. Loud voices down. Applies when noise cancellation is on.")
                }
                .disabled(!filtering.wrappedValue || busy)
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            if hasError {
                Button(action: openMainWindow) {
                    Label("Open Noise to resolve an issue", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(.orange)
                }.buttonStyle(.plain)
            }

            Divider()
            HStack {
                Button("Open Noise", action: openMainWindow).buttonStyle(.plain)
                Spacer()
                Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                    .buttonStyle(.plain).help("Quit Noise").accessibilityLabel("Quit Noise")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(18)
        .frame(width: 300)
    }

    private var filtering: Binding<Bool> {
        if tab == .speaker {
            Binding(get: { store.incomingEnabled && !store.incomingBypass }, set: store.setIncomingFiltering)
        } else {
            Binding(get: { store.outgoingRunning && !store.outgoingBypass }, set: store.setOutgoing)
        }
    }

    private var leveling: Binding<Bool> {
        // Show the effective state while preserving the user's preference for
        // the next time cancellation is enabled.
        Binding(get: {
            filtering.wrappedValue && (tab == .speaker ? store.incomingVoiceLeveling : store.outgoingVoiceLeveling)
        }, set: { enabled in
            if tab == .speaker { store.incomingVoiceLeveling = enabled }
            else { store.outgoingVoiceLeveling = enabled }
        })
    }

    private var reduction: Binding<Double> {
        tab == .speaker ? $store.incomingReduction : $store.outgoingReduction
    }

    private var busy: Bool { tab == .speaker ? store.incomingBusy : store.outgoingBusy }
    private var canEnable: Bool {
        tab == .speaker
            ? store.incomingEnabled || (store.hasSelectedApps && store.selectedOutput != nil)
            : store.outgoingRunning || (store.virtualMicrophone != nil && store.selectedInput != nil)
    }
    private var hasError: Bool {
        tab == .speaker ? store.incomingError != nil || store.incomingConnectionDelayed : store.outgoingError != nil
    }

    @ViewBuilder private var context: some View {
        if tab == .microphone && store.virtualMicrophone == nil {
            Button("Set up microphone…") {
                openMainWindow()
                store.showDriverInstall = true
            }.buttonStyle(.link).font(.caption)
        } else if tab == .speaker {
            ApplicationSelectionButton(store: store, expanded: true, didOpen: { dismiss() })
                .buttonStyle(.bordered).controlSize(.regular)
        } else {
            Text(store.selectedInput?.name ?? "Choose a microphone in Noise")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    private func openMainWindow() {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
        dismiss()
    }
}

private enum AudioTab: String, CaseIterable, Identifiable {
    case speaker, microphone
    var id: Self { self }
    var title: String { self == .speaker ? "Speaker" : "Microphone" }
    var icon: String { self == .speaker ? "speaker.wave.2.fill" : "mic.fill" }
}
