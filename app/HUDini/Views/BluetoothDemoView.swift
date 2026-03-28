import SwiftUI

struct BluetoothDemoView: View {
    @EnvironmentObject private var manager: BluetoothDemoManager

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Text("HUDini • Bluetooth Audio")
                    .font(.headline)

                statusCard
                discoverySection
            }
            .padding()
        }
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Status")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text(statusDisplayText)
                .font(.body)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.tertiarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var statusDisplayText: String {
        if case .connected = manager.state {
            return "Connected"
        }
        return manager.statusMessage
    }

    private var discoverySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Devices")
                .font(.subheadline)

            if manager.discoveredDevices.isEmpty {
                Text("Tap scan to find the HUDini audio peripheral.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 8) {
                    ForEach(manager.discoveredDevices) { device in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(device.name)
                                    .font(.body)
                                Text("BLE audio peripheral")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Connect") {
                                manager.connect(to: device)
                            }
                            .buttonStyle(.bordered)
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(.secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                }
            }

            HStack(spacing: 12) {
                Button("Scan") {
                    manager.beginScanning()
                }
                .buttonStyle(.borderedProminent)

                Button("Stop Scan") {
                    manager.stopScanning()
                }
                .buttonStyle(.bordered)

                if case .connected = manager.state {
                    Button("Disconnect") {
                        manager.disconnect()
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

#Preview {
    BluetoothDemoView()
        .environmentObject(BluetoothDemoManager())
}
