import SwiftUI

struct TranscriptionView: View {
    private enum AudioSource: String, CaseIterable, Identifiable {
        case iphoneMicrophone = "iPhone Microphone"
        case bluetooth = "Bluetooth Mic"

        var id: String { rawValue }
    }

    @StateObject private var mgr = TranscriptionManager()
    @StateObject private var bluetoothManager = BluetoothDemoManager()
    @State private var selectedListeningCode: String = "en"
    @State private var selectedTargetCode: String = "en"
    @State private var selectedAudioSource: AudioSource = .iphoneMicrophone

    var body: some View {
        VStack(spacing: 12) {
            Text("HUDini • Live Transcription")
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                Text("Audio source")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Picker("Audio source", selection: $selectedAudioSource) {
                    ForEach(AudioSource.allCases) { source in
                        Text(source.rawValue).tag(source)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: selectedAudioSource, initial: false) { _, _ in
                    stopActiveSource()
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Listening language")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Picker("Listening language", selection: $selectedListeningCode) {
                    ForEach(TranslationLanguages.supported) { option in
                        Text(option.name).tag(option.code)
                    }
                }
                .pickerStyle(.menu)
                .onChange(of: selectedListeningCode, initial: false) { _, newValue in
                    mgr.setListeningLanguage(newValue)
                    bluetoothManager.setRecognitionLanguage(newValue)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Translate to")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Picker("Target language", selection: $selectedTargetCode) {
                    ForEach(TranslationLanguages.targetOptions) { option in
                        Text(option.name).tag(option.code)
                    }
                }
                .pickerStyle(.menu)
                .onChange(of: selectedTargetCode, initial: false) { _, newValue in
                    mgr.setTargetLanguage(newValue)
                    bluetoothManager.setTargetLanguage(newValue)
                }
            }

            if selectedAudioSource == .bluetooth {
                bluetoothConnectionSection
            }

            ScrollView {
                Text(activeTranscript.isEmpty ? "…" : activeTranscript)
                    .font(.body.monospaced())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .accessibilityLabel("Transcript")
            }
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12))

            ScrollView {
                Text(activeRenderedText.isEmpty ? "Translated output appears here." : activeRenderedText)
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .accessibilityLabel("Rendered transcript")
            }
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12))

            HStack(spacing: 12) {
                Button(isRunning ? "Stop" : "Start") {
                    toggleStartStop()
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedAudioSource == .bluetooth && !isBluetoothConnected && !isRunning)

                Button("Clear") {
                    clearActiveTranscript()
                }
                .buttonStyle(.bordered)
            }

            if !activeStatusMessage.isEmpty {
                Text(activeStatusMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .task {
            // Ask once at view start
            await mgr.requestPermissions()
            syncFromManager()
        }
    }

    private func syncFromManager() {
        selectedListeningCode = mgr.listeningLanguageCode
        selectedTargetCode = mgr.targetLanguageCode
    }

    private var activeTranscript: String {
        switch selectedAudioSource {
        case .iphoneMicrophone:
            return mgr.transcript
        case .bluetooth:
            return bluetoothManager.liveTranscript
        }
    }

    private var activeRenderedText: String {
        switch selectedAudioSource {
        case .iphoneMicrophone:
            return mgr.renderedText
        case .bluetooth:
            return bluetoothManager.renderedText
        }
    }

    private var activeStatusMessage: String {
        switch selectedAudioSource {
        case .iphoneMicrophone:
            return mgr.statusMessage
        case .bluetooth:
            return bluetoothManager.statusMessage
        }
    }

    private var isRunning: Bool {
        switch selectedAudioSource {
        case .iphoneMicrophone:
            return mgr.isTranscribing
        case .bluetooth:
            return bluetoothManager.isStreaming
        }
    }

    private var isBluetoothConnected: Bool {
        if case .connected = bluetoothManager.state {
            return true
        }
        return false
    }

    private func toggleStartStop() {
        switch selectedAudioSource {
        case .iphoneMicrophone:
            if mgr.isTranscribing {
                mgr.stop()
            } else {
                mgr.startTranscribing(
                    listeningLanguage: selectedListeningCode,
                    translatingTo: selectedTargetCode
                )
            }
        case .bluetooth:
            if bluetoothManager.isStreaming {
                bluetoothManager.stopAudioStream()
            } else {
                bluetoothManager.startTranscribing(
                    listeningLanguage: selectedListeningCode,
                    translatingTo: selectedTargetCode
                )
            }
        }
    }

    private func stopActiveSource() {
        if mgr.isTranscribing {
            mgr.stop()
        }
        if bluetoothManager.isStreaming {
            bluetoothManager.stopAudioStream()
        }
    }

    private func clearActiveTranscript() {
        switch selectedAudioSource {
        case .iphoneMicrophone:
            mgr.resetTranscript()
        case .bluetooth:
            bluetoothManager.clearTranscript()
        }
    }

    private var bluetoothConnectionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Bluetooth connection")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if bluetoothManager.discoveredDevices.isEmpty {
                Text("Tap Scan to find a HUDini BLE mic.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 8) {
                    ForEach(bluetoothManager.discoveredDevices) { device in
                        HStack {
                            Text(device.name)
                                .font(.body)
                            Spacer()
                            Button("Connect") {
                                bluetoothManager.connect(to: device)
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
            }

            HStack(spacing: 10) {
                Button("Scan") {
                    bluetoothManager.beginScanning()
                }
                .buttonStyle(.bordered)

                Button("Stop Scan") {
                    bluetoothManager.stopScanning()
                }
                .buttonStyle(.bordered)

                if isBluetoothConnected {
                    Button("Disconnect") {
                        bluetoothManager.disconnect()
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

#Preview {
    TranscriptionView()
}
