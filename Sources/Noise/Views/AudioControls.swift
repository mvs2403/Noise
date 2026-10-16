import SwiftUI
import NoiseAudio

struct AudioCard<Content: View>: View {
    let title: String
    let subtitle: String
    let icon: String
    let isRunning: Bool
    let isBusy: Bool
    let onToggle: (Bool) -> Void
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: icon).font(.system(size: 22, weight: .medium)).foregroundStyle(.tint)
                    .frame(width: 32, height: 36)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.title3.weight(.semibold))
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if isBusy { ProgressView().controlSize(.small).frame(width: 36, height: 24) }
                else {
                    Toggle(title, isOn: Binding(get: { isRunning }, set: onToggle))
                        .labelsHidden().toggleStyle(.switch).controlSize(.small)
                        .accessibilityLabel("Filter \(title.lowercased())")
                }
            }
            Divider()
            content()
        }
        .padding(20)
        .background(.background, in: RoundedRectangle(cornerRadius: 16))
        .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(.primary.opacity(isRunning ? 0.23 : 0.12)) }
    }
}

struct EnginePicker: View {
    @Binding var selection: NoiseEngine
    let runtime: RuntimePaths
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Noise cancellation engine").font(.caption.weight(.medium)).foregroundStyle(.secondary)
            Picker("Noise cancellation engine", selection: $selection) {
                ForEach(NoiseEngine.allCases) { engine in
                    Text(engine.name + (runtime.isAvailable(engine) ? "" : " · not installed"))
                        .tag(engine).disabled(!runtime.isAvailable(engine))
                }
            }.labelsHidden().frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct ComparisonControl: View {
    @Binding var bypass: Bool
    let enabled: Bool
    var body: some View {
        Picker("Audio comparison", selection: $bypass) {
            Text("Original").tag(true)
            Text("Cleaned").tag(false)
        }
        .pickerStyle(.segmented).disabled(!enabled)
        .accessibilityHint("Compare the unfiltered audio with the selected noise cancellation engine")
    }
}

struct StreamMeter: View {
    let statistics: StreamStatistics
    let running: Bool
    let bypass: Bool
    var waiting = false
    var waitingLabel = "Waiting for app audio"
    private var status: String {
        if waiting { return waitingLabel }
        if !running { return "Off" }
        if bypass { return "Original audio" }
        return statistics.inputPeak > 0.00005 ? "Filtering" : "Waiting for audio"
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Label(status, systemImage: running ? "circle.fill" : "circle")
                    .foregroundStyle(running ? Color.green : .secondary)
                Spacer()
                if running && statistics.inputFrames > 0 {
                    Text(String(format: "%.1f ms / 10 ms", statistics.processingMilliseconds))
                        .monospacedDigit().help("Measured filtering and voice-leveling time for each 10 milliseconds of audio. Device and buffering latency are additional.")
                }
            }.font(.caption)
            meter("In", level: running ? statistics.inputPeak : 0)
            meter("Out", level: running ? statistics.outputPeak : 0)
        }
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }
    private func meter(_ name: String, level: Float) -> some View {
        HStack(spacing: 10) {
            Text(name).font(.caption2).foregroundStyle(.secondary).frame(width: 24, alignment: .leading)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.primary.opacity(0.06))
                    Capsule().fill(level > 0.98 ? Color.orange : .accentColor)
                        .frame(width: geometry.size.width * CGFloat(min(1, max(0, (20 * log10(max(level, 0.0001)) + 60) / 60))))
                }
            }.frame(height: 5)
        }
    }
}

struct ErrorNotice: View {
    let text: String
    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle")
            .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }
}
