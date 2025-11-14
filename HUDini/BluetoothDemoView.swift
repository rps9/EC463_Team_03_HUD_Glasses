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

                instructionsCard

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

    private var instructionsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("How to demo")
                .font(.subheadline).bold()
            Text("Mac setup (LightBlue 4.x):\n• Open LightBlue, switch to the Virtual Devices tab, and press “Create Virtual Peripheral.”\n• Pick “Blank,” then add a Primary service with UUID 6E400001-B5A3-F393-E0A9-E50E24DCCA9E.\n• Inside that service add two characteristics: (1) UUID 6E400002… with Write + Write Without Response, (2) UUID 6E400003… with Notify enabled.\n• Save, click “Start Advertising,” and open the Console for that virtual device so the RX log is visible—LightBlue prints every UTF-8 payload it receives.\n\niPhone steps: pair your AirPods so transcription still uses that mic, open this tab, tap “Scan for devices,” and connect to the LightBlue peripheral. Type a sentence and send it—the Mac console will immediately show the characters just like a HUD display would.")
                .font(.footnote)
            Text("Tip: the Mac is the peripheral here—no need to connect LightBlue to your iPhone. Instead, let HUDini find the virtual device you just advertised.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
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
