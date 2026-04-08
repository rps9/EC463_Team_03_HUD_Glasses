import SwiftUI
import UIKit

struct AdminFrameLogView: View {
    @EnvironmentObject private var frameManager: FrameBluetoothManager
    @State private var copyStatusMessage: String = ""

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                HUDCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Frame Dev Log")
                            .font(.system(.headline, design: .rounded, weight: .semibold))
                            .foregroundStyle(HUDTheme.ink)

                        Text("Admin-only log of outbound Frame commands and inbound Frame events.")
                            .font(.system(.body, design: .rounded))
                            .foregroundStyle(HUDTheme.inkMuted)

                        HStack(spacing: 12) {
                            Button("Copy Log") {
                                UIPasteboard.general.string = exportedLogText
                                copyStatusMessage = "Copied \(frameManager.devLogEntries.count) log entries."
                            }
                            .buttonStyle(HUDPrimaryButtonStyle(tint: HUDTheme.accent))

                            Button("Clear Log") {
                                frameManager.clearDevLog()
                                copyStatusMessage = ""
                            }
                            .buttonStyle(HUDSecondaryButtonStyle(tint: HUDTheme.rose))
                        }

                        if !copyStatusMessage.isEmpty {
                            Text(copyStatusMessage)
                                .font(.system(.caption, design: .rounded))
                                .foregroundStyle(HUDTheme.inkMuted)
                        }
                    }
                }

                HUDCard {
                    if frameManager.devLogEntries.isEmpty {
                        Text("No Frame events logged yet.")
                            .font(.system(.body, design: .rounded))
                            .foregroundStyle(HUDTheme.inkMuted)
                    } else {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(frameManager.devLogEntries.reversed()) { entry in
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("\(entry.direction) \(Self.timestampFormatter.string(from: entry.timestamp))")
                                        .font(.system(.caption, design: .monospaced, weight: .semibold))
                                        .foregroundStyle(entry.direction == "OUT" ? HUDTheme.accent : HUDTheme.mint)

                                    Text(entry.message)
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundStyle(HUDTheme.ink)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .padding(12)
                                .background(.white.opacity(0.72), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
        }
        .hudScreen()
        .navigationTitle("Admin")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var exportedLogText: String {
        frameManager.devLogEntries.map { entry in
            "\(Self.timestampFormatter.string(from: entry.timestamp)) [\(entry.direction)] \(entry.message)"
        }
        .joined(separator: "\n")
    }
}

#Preview {
    NavigationStack {
        AdminFrameLogView()
            .environmentObject(FrameBluetoothManager())
    }
}
