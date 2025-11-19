import SwiftUI

/// UI for the Bluetooth demo tab. Mirrors the clean, card-based layout used
/// elsewhere so the tab feels native to HUDini while exercising the new
/// Bluetooth manager.
struct BluetoothDemoView: View {
    @StateObject private var manager = BluetoothDemoManager()
    @State private var outgoingText: String = ""

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Text("HUDini • Bluetooth Demo")
                    .font(.headline)

                statusCard

                discoverySection

                if case .connected = manager.state {
                    messagingSection
                }

                receivedSection
            }
            .padding()
        }
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Status")
                .font(.subheadline).foregroundStyle(.secondary)
            Text(manager.statusMessage)
                .font(.body)
            if case let .connected(name) = manager.state {
                Text("Connected to: \(name)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.tertiarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var discoverySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Devices")
                .font(.subheadline)

            if manager.discoveredDevices.isEmpty {
                Text("Tap the scan button to search for LightBlue or another NUS peripheral.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 8) {
                    ForEach(manager.discoveredDevices) { device in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(device.name)
                                    .font(.body)
                                Text("Ready to connect")
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
                Button("Scan for devices") {
                    manager.beginScanning()
                }
                .buttonStyle(.borderedProminent)

                Button("Stop scan") {
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

    private var messagingSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Send text to HUD")
                .font(.subheadline)
            TextField("Type a message", text: $outgoingText, axis: .vertical)
                .textFieldStyle(.roundedBorder)
            Button("Send via Bluetooth") {
                manager.send(text: outgoingText)
            }
            .buttonStyle(.borderedProminent)
            .disabled(outgoingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

            if !manager.lastSentText.isEmpty {
                Text("Last sent: \(manager.lastSentText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var receivedSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Incoming text")
                .font(.subheadline)
            ScrollView {
                Text(manager.receivedText.isEmpty ? "Notifications from the peripheral will appear here." : manager.receivedText)
                    .font(.body.monospaced())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(minHeight: 100)
            .background(Color(.tertiarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12))

            HStack {
                Spacer()
                Button("Clear log") {
                    manager.clearTranscripts()
                }
                .buttonStyle(.bordered)
            }
        }
        .padding()
    }
}

#Preview {
    BluetoothDemoView()
}
