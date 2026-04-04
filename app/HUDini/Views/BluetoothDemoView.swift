import SwiftUI

struct BluetoothDemoView: View {
    @EnvironmentObject private var manager: BluetoothDemoManager

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                HUDCard {
                    VStack(alignment: .leading, spacing: 16) {
                        HUDSectionHeader(
                            eyebrow: "Bluetooth",
                            title: "Connect the HUD transceiver.",
                            detail: "Scan for the MDBT42Q HUD device, connect once, and use the live peripheral status to confirm the BLE link."
                        )

                        HStack(spacing: 12) {
                            detailChip(title: "State", value: connectionStateLabel)
                            detailChip(title: "Devices", value: "\(manager.discoveredDevices.count)")
                        }
                    }
                }

                HUDCard {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Current Status")
                            .font(.system(.headline, design: .rounded, weight: .semibold))
                            .foregroundStyle(HUDTheme.ink)

                        Text(statusDisplayText)
                            .font(.system(.body, design: .rounded))
                            .foregroundStyle(HUDTheme.inkMuted)

                        if !manager.peripheralStatus.isEmpty {
                            Text("Peripheral: \(manager.peripheralStatus)")
                                .font(.system(.footnote, design: .rounded, weight: .medium))
                                .foregroundStyle(HUDTheme.accent)
                        }

                        HStack(spacing: 12) {
                            Button("Scan") {
                                manager.beginScanning()
                            }
                            .buttonStyle(HUDPrimaryButtonStyle(tint: HUDTheme.ink))

                            Button("Stop") {
                                manager.stopScanning()
                            }
                            .buttonStyle(HUDSecondaryButtonStyle(tint: HUDTheme.ink))
                        }

                        if case .connected = manager.state {
                            Button("Disconnect") {
                                manager.disconnect()
                            }
                            .buttonStyle(HUDSecondaryButtonStyle(tint: HUDTheme.rose))
                        }
                    }
                }

                HUDCard {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Available Devices")
                            .font(.system(.headline, design: .rounded, weight: .semibold))
                            .foregroundStyle(HUDTheme.ink)

                        if manager.discoveredDevices.isEmpty {
                            Text("No devices discovered yet. Start a scan to find the HUDini MDBT42Q BLE peripheral.")
                                .font(.system(.body, design: .rounded))
                                .foregroundStyle(HUDTheme.inkMuted)
                        } else {
                            VStack(spacing: 12) {
                                ForEach(manager.discoveredDevices) { device in
                                    HStack(spacing: 14) {
                                        ZStack {
                                            Circle()
                                                .fill(HUDTheme.accent.opacity(0.12))
                                                .frame(width: 42, height: 42)
                                            Image(systemName: "dot.radiowaves.left.and.right")
                                                .foregroundStyle(HUDTheme.accent)
                                        }

                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(device.name)
                                                .font(.system(.body, design: .rounded, weight: .semibold))
                                                .foregroundStyle(HUDTheme.ink)
                                            Text("HUD mic + display BLE peripheral")
                                                .font(.system(.caption, design: .rounded))
                                                .foregroundStyle(HUDTheme.inkMuted)
                                        }

                                        Spacer()

                                        Button("Connect") {
                                            manager.connect(to: device)
                                        }
                                        .buttonStyle(HUDSecondaryButtonStyle(tint: HUDTheme.accent))
                                        .frame(width: 124)
                                    }
                                    .padding(14)
                                    .background(.white.opacity(0.7), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
        }
        .hudScreen()
    }

    private var statusDisplayText: String {
        if case .connected(let name) = manager.state {
            return "Connected to \(name)"
        }
        return manager.statusMessage
    }

    private var connectionStateLabel: String {
        switch manager.state {
        case .idle:
            return "Idle"
        case .scanning:
            return "Scanning"
        case .connecting:
            return "Connecting"
        case .connected:
            return "Connected"
        }
    }

    private func detailChip(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.system(.caption2, design: .rounded, weight: .bold))
                .tracking(1)
                .foregroundStyle(HUDTheme.inkMuted)

            Text(value)
                .font(.system(.headline, design: .rounded, weight: .semibold))
                .foregroundStyle(HUDTheme.ink)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.72), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

#Preview {
    NavigationStack {
        BluetoothDemoView()
            .environmentObject(BluetoothDemoManager())
    }
}
