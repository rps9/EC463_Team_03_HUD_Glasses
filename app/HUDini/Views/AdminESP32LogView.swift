import SwiftUI
import UIKit

struct AdminESP32LogView: View {
    @EnvironmentObject private var esp32Manager: ESP32BluetoothManager
    @State private var copyStatusMessage: String = ""
    @State private var manualMessage: String = ""

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
                        Text("ESP32 Dev Log")
                            .font(.system(.headline, design: .rounded, weight: .semibold))
                            .foregroundStyle(HUDTheme.ink)

                        Text("Outbound BLE writes, inbound notifications, audio stats, and recognition timing for the ESP32 peripheral.")
                            .font(.system(.body, design: .rounded))
                            .foregroundStyle(HUDTheme.inkMuted)

                        HStack(spacing: 12) {
                            Button("Copy Log") {
                                UIPasteboard.general.string = exportedLogText
                                copyStatusMessage = "Copied \(esp32Manager.devLogEntries.count) log entries."
                            }
                            .buttonStyle(HUDPrimaryButtonStyle(tint: HUDTheme.accent))

                            Button("Clear Log") {
                                esp32Manager.clearDevLog()
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
                    if esp32Manager.devLogEntries.isEmpty {
                        Text("No ESP32 events logged yet.")
                            .font(.system(.body, design: .rounded))
                            .foregroundStyle(HUDTheme.inkMuted)
                    } else {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(esp32Manager.devLogEntries.reversed()) { entry in
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("\(entry.direction) \(Self.timestampFormatter.string(from: entry.timestamp))")
                                        .font(.system(.caption, design: .monospaced, weight: .semibold))
                                        .foregroundStyle(color(for: entry.direction))

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
        .navigationTitle("ESP32 Admin")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func color(for direction: String) -> Color {
        switch direction {
        case "OUT":    return HUDTheme.accent
        case "IN":     return HUDTheme.mint
        case "AUDIO":  return HUDTheme.amber
        case "TIMING": return HUDTheme.rose
        default:       return HUDTheme.inkMuted
        }
    }

    private var exportedLogText: String {
        esp32Manager.devLogEntries.map { entry in
            "\(Self.timestampFormatter.string(from: entry.timestamp)) [\(entry.direction)] \(entry.message)"
        }
        .joined(separator: "\n")
    }
}
