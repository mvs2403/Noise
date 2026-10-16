import SwiftUI

struct VoiceLevelingControl: View {
    @Binding var enabled: Bool
    let processing: Bool
    let gainDB: Float
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Toggle("Voice leveling", isOn: $enabled).toggleStyle(.switch)
                .font(.callout)
                .help("Raise quiet speech and soften loud speech after noise removal. Original audio bypasses leveling too.")
            HStack {
                Text("Quiet voices up. Loud voices down.")
                Spacer(minLength: 4)
                if processing && enabled {
                    Text(String(format: "%+.1f dB", gainDB)).monospacedDigit()
                        .help("Current level adjustment, including peak limiting")
                }
            }.font(.caption).foregroundStyle(.secondary)
        }
    }
}
