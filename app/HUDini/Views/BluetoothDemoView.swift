import SwiftUI

struct BluetoothDemoView: View {
    @EnvironmentObject private var manager: FrameBluetoothManager

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                summaryCard
                statusCard
                preferencesCard
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
        }
        .hudScreen()
    }

    private var summaryCard: some View {
        HUDCard {
            VStack(alignment: .leading, spacing: 16) {
                HUDSectionHeader(
                    eyebrow: "Bluetooth",
                    title: "Connect the Frame glasses.",
                    detail: "This path uses Frame's BLE service and raw-message protocol instead of the old custom HUD peripheral. Install `hardware/frame/main.lua` on Frame once before using it."
                )

                HStack(spacing: 12) {
                    detailChip(title: "State", value: connectionStateLabel)
                    detailChip(title: "Devices", value: "\(manager.discoveredDevices.count)")
                }

                HStack(spacing: 12) {
                    detailChip(title: "Firmware", value: manager.frameFirmwareVersion.isEmpty ? "Unknown" : manager.frameFirmwareVersion)
                    detailChip(title: "Payload", value: manager.framePayloadLimit > 0 ? "\(manager.framePayloadLimit) B" : "Unknown")
                }
            }
        }
    }

    private var statusCard: some View {
        HUDCard {
            VStack(alignment: .leading, spacing: 14) {
                Text("Current Status")
                    .font(.system(.headline, design: .rounded, weight: .semibold))
                    .foregroundStyle(HUDTheme.ink)

                Text(statusDisplayText)
                    .font(.system(.body, design: .rounded))
                    .foregroundStyle(HUDTheme.inkMuted)

                detailChip(title: "BLE Stage", value: manager.connectionDebugStage)

                if !manager.peripheralStatus.isEmpty {
                    Text("Frame: \(manager.peripheralStatus)")
                        .font(.system(.footnote, design: .rounded, weight: .medium))
                        .foregroundStyle(HUDTheme.accent)
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Discovered Devices")
                        .font(.system(.subheadline, design: .rounded, weight: .semibold))
                        .foregroundStyle(HUDTheme.ink)

                    if manager.discoveredDevices.isEmpty {
                        Text("No devices discovered yet. Tap Scan to find the Frame glasses.")
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
                                        Image(systemName: "eyeglasses")
                                            .foregroundStyle(HUDTheme.accent)
                                    }

                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(device.name)
                                            .font(.system(.body, design: .rounded, weight: .semibold))
                                            .foregroundStyle(HUDTheme.ink)
                                        Text("RSSI \(device.rssi.intValue) dBm")
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
                    HStack(spacing: 12) {
                        Button("Ping") {
                            manager.ping()
                        }
                        .buttonStyle(HUDSecondaryButtonStyle(tint: HUDTheme.accent))

                        Button("Reset App") {
                            manager.rebootRunningFrameApp()
                        }
                        .buttonStyle(HUDSecondaryButtonStyle(tint: HUDTheme.amber))
                    }

                    Button("Disconnect") {
                        manager.disconnect()
                    }
                    .buttonStyle(HUDSecondaryButtonStyle(tint: HUDTheme.rose))
                }
            }
        }
    }

    private var preferencesCard: some View {
        HUDCard {
            VStack(alignment: .leading, spacing: 16) {
                Text("Frame Display")
                    .font(.system(.headline, design: .rounded, weight: .semibold))
                    .foregroundStyle(HUDTheme.ink)

                HStack(spacing: 12) {
                    detailChip(title: "Brightness", value: "\(manager.preferences.brightness)")
                    detailChip(title: "Partials", value: manager.preferences.showsLivePartials ? "On" : "Off")
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Phone Install")
                        .font(.system(.subheadline, design: .rounded, weight: .semibold))
                        .foregroundStyle(HUDTheme.ink)

                    Text(manager.installStatus)
                        .font(.system(.body, design: .rounded))
                        .foregroundStyle(HUDTheme.inkMuted)

                    Button(manager.isInstallingApp ? "Installing…" : "Install / Update HUDini On Frame") {
                        manager.installOrUpdateHUDiniApp()
                    }
                    .buttonStyle(HUDPrimaryButtonStyle(tint: HUDTheme.mint))
                    .disabled(!isConnected || manager.isInstallingApp)

                    if !manager.installerOutput.isEmpty {
                        ScrollView {
                            Text(manager.installerOutput)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(HUDTheme.inkMuted)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(minHeight: 90, maxHeight: 150)
                        .padding(12)
                        .background(.white.opacity(0.7), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                }

                Stepper(value: $manager.preferences.brightness, in: -2 ... 2) {
                    Text("Brightness")
                        .font(.system(.body, design: .rounded, weight: .semibold))
                        .foregroundStyle(HUDTheme.ink)
                }

                Toggle("Show live partial captions", isOn: $manager.preferences.showsLivePartials)
                    .font(.system(.body, design: .rounded))
                    .tint(HUDTheme.accent)

                Button("Save Preferences To Frame") {
                    manager.applyPreferences()
                }
                .buttonStyle(HUDPrimaryButtonStyle(tint: HUDTheme.accent))
                .disabled(!isConnected)
            }
        }
    }

    private var isConnected: Bool {
        if case .connected = manager.state { return true }
        return false
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
            .environmentObject(FrameBluetoothManager())
    }
}
