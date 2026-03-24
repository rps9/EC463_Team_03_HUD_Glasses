import SwiftUI

struct BluetoothDemoView: View {
    @StateObject private var manager = BluetoothDemoManager()

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Text("HUDini • Bluetooth Audio")
                    .font(.headline)

                statusCard
                discoverySection
                streamSection
                transcriptSection
            }
            .padding()
        }
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Status")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text(manager.statusMessage)
                .font(.body)

            if case let .connected(name) = manager.state {
                Text("Connected to: \(name)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if !manager.peripheralStatus.isEmpty {
                Text("Device: \(manager.peripheralStatus)")
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

    private var streamSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Streaming")
                .font(.subheadline)

            Picker("Input Language", selection: languageBinding) {
                ForEach(TranslationLanguages.supported) { language in
                    Text(language.name).tag(language.code)
                }
            }
            .pickerStyle(.menu)

            Picker("Target Language", selection: targetLanguageBinding) {
                ForEach(TranslationLanguages.targetOptions) { language in
                    Text(language.name).tag(language.code)
                }
            }
            .pickerStyle(.menu)

            HStack(spacing: 12) {
                Button("Start Transcription") {
                    manager.startTranscribing(
                        listeningLanguage: manager.selectedLanguageCode,
                        translatingTo: manager.targetLanguageCode
                    )
                }
                .buttonStyle(.borderedProminent)
                .disabled(!isConnected || manager.isStreaming)

                Button("Stop") {
                    manager.stopAudioStream()
                }
                .buttonStyle(.bordered)
                .disabled(!manager.isStreaming)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var transcriptSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Live Transcript")
                .font(.subheadline)

            ScrollView {
                Text(manager.liveTranscript.isEmpty ? "Speech from the Bluetooth stream will appear here." : manager.liveTranscript)
                    .font(.body.monospaced())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(minHeight: 120)
            .background(Color(.tertiarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12))

            HStack {
                Spacer()
                Button("Clear") {
                    manager.clearTranscript()
                }
                .buttonStyle(.bordered)
            }

            Text("Rendered Output")
                .font(.subheadline)

            ScrollView {
                Text(manager.renderedText.isEmpty ? "Translated output appears here." : manager.renderedText)
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(minHeight: 120)
            .background(Color(.tertiarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .padding()
    }

    private var isConnected: Bool {
        if case .connected = manager.state {
            return true
        }
        return false
    }

    private var languageBinding: Binding<String> {
        Binding(
            get: { manager.selectedLanguageCode },
            set: { manager.setRecognitionLanguage($0) }
        )
    }

    private var targetLanguageBinding: Binding<String> {
        Binding(
            get: { manager.targetLanguageCode },
            set: { manager.setTargetLanguage($0) }
        )
    }
}

#Preview {
    BluetoothDemoView()
}
