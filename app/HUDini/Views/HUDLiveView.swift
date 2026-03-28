import SwiftUI

struct HUDLiveView: View {
    @EnvironmentObject private var bluetoothManager: BluetoothDemoManager
    @AppStorage(wrappedValue: true, APIConfig.AppStorageKey.hudSuggestionEnabled) private var suggestionEnabled: Bool
    @StateObject private var transcriptionManager = TranscriptionManager()
    @StateObject private var suggestionManager = HUDSuggestionManager()
    /// HUD only translates into English; target picker stays in UI with a single option (independent of downloaded packs).
    @State private var targetLanguage: String = "en"
    @State private var listeningLanguageCode: String = HUDLiveView.defaultListeningLanguageCode
    @State private var installedLanguages: [TranslationLanguageOption] = TranslationLanguages.supported
    @State private var suggestionRefreshTask: Task<Void, Never>?
    @State private var lastSentBLEText: String = ""

    private let hudCharacterLimit: Int = 260
    private static let suggestionDebounceNanoseconds: UInt64 = 450_000_000
    private static let hudTargetLanguageCode = "en"
    private static var hudTargetLanguageOptions: [TranslationLanguageOption] {
        TranslationLanguages.supported.filter { $0.code == hudTargetLanguageCode }
    }

    var body: some View {
        VStack(spacing: 24) {
            Spacer(minLength: 0)

            VStack(alignment: .leading, spacing: 8) {
                Text("Translated Result")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(hudDisplayText.isEmpty ? "…" : hudDisplayText)
                    .font(.system(size: 40, weight: .semibold, design: .rounded))
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.6)
                    .lineLimit(6)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity)
                    .padding(24)
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 20))
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if suggestionEnabled {
                suggestionCard
            }

            HStack(spacing: 16) {
                Menu {
                    Picker("Listening language", selection: $listeningLanguageCode) {
                        ForEach(installedLanguages) { option in
                            Text(option.name).tag(option.code)
                        }
                    }
                } label: {
                    Label(listeningLanguageLabel(for: listeningLanguageCode), systemImage: "ear")
                        .labelStyle(.titleAndIcon)
                }
                .menuOrder(.fixed)
                .tint(.secondary)

                Menu {
                    Picker("Target language", selection: $targetLanguage) {
                        ForEach(Self.hudTargetLanguageOptions) { option in
                            Text(option.name).tag(option.code)
                        }
                    }
                } label: {
                    Label(targetLanguageLabel, systemImage: "globe")
                        .labelStyle(.titleAndIcon)
                }
                .menuOrder(.fixed)
                .tint(.secondary)

                Button(transcriptionManager.isTranscribing ? "Stop" : "Start") {
                    toggleListening()
                }
                .buttonStyle(.borderedProminent)
                .tint(transcriptionManager.isTranscribing ? .red : .accentColor)
                .font(.title3)
            }

            if !transcriptionManager.statusMessage.isEmpty {
                Text(transcriptionManager.statusMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            Text(isTransceiverConnected
                 ? "Transceiver connected — translated text is sent over BLE when it updates."
                 : "No BLE transceiver connected — connect in Settings → Bluetooth to send text to the device.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 8)

            Spacer(minLength: 0)
        }
        .padding(32)
        .background(Color.black.opacity(0.02))
        .task {
            await transcriptionManager.requestPermissions()
            await loadInstalledLanguages()
        }
        .onChange(of: listeningLanguageCode, initial: false) { _, newValue in
            transcriptionManager.setListeningLanguage(newValue)
        }
        .onChange(of: targetLanguage, initial: false) { _, newValue in
            transcriptionManager.setTargetLanguage(newValue)
        }
        .onChange(of: transcriptionManager.renderedText, initial: false) { _, newValue in
            scheduleDebouncedHUDSideEffects(for: newValue)
        }
        .onChange(of: bluetoothManager.state, initial: false) { _, newState in
            if !isTransceiverConnected(state: newState) {
                lastSentBLEText = ""
            }
        }
        .onChange(of: suggestionEnabled, initial: false) { _, enabled in
            if !enabled {
                suggestionRefreshTask?.cancel()
                suggestionRefreshTask = nil
                suggestionManager.clearSuggestion()
            }
        }
        .onDisappear {
            suggestionRefreshTask?.cancel()
            suggestionRefreshTask = nil
            transcriptionManager.stop()
            suggestionManager.clearSuggestion()
        }
    }

    private var hudDisplayText: String {
        let raw = transcriptionManager.renderedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return "" }
        if raw.count > hudCharacterLimit {
            return String(raw.suffix(hudCharacterLimit))
        }
        return raw
    }

    private func toggleListening() {
        if transcriptionManager.isTranscribing {
            transcriptionManager.stop()
            suggestionRefreshTask?.cancel()
            suggestionRefreshTask = nil
            suggestionManager.clearSuggestion()
        } else {
            transcriptionManager.startTranscribing(
                listeningLanguage: listeningLanguageCode,
                translatingTo: Self.hudTargetLanguageCode
            )
        }
    }

    private var isTransceiverConnected: Bool {
        isTransceiverConnected(state: bluetoothManager.state)
    }

    private func isTransceiverConnected(state: BluetoothDemoManager.ConnectionState) -> Bool {
        if case .connected = state { return true }
        return false
    }

    private func scheduleDebouncedHUDSideEffects(for text: String) {
        suggestionRefreshTask?.cancel()
        let delay = Self.suggestionDebounceNanoseconds
        suggestionRefreshTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            if suggestionEnabled {
                suggestionManager.refreshSuggestion(for: text, languageCode: Self.hudTargetLanguageCode)
            }
            pushTranslatedTextToTransceiverIfNeeded(text)
        }
    }

    private func pushTranslatedTextToTransceiverIfNeeded(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard isTransceiverConnected else { return }
        guard trimmed != lastSentBLEText else { return }
        lastSentBLEText = trimmed
        bluetoothManager.sendHUDTextToTransceiver(trimmed, updateStatus: false)
    }

    private var suggestionCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Suggested reply")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                Text(suggestionManager.suggestionPhonetic.isEmpty ? "Suggestions appear while listening." : suggestionManager.suggestionPhonetic)
                    .font(.title3)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if !suggestionManager.suggestionEnglish.isEmpty {
                    Text(suggestionManager.suggestionEnglish)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .background(Color(.tertiarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 16))
        }
    }

    private var targetLanguageLabel: String {
        Self.hudTargetLanguageOptions.first?.name
            ?? TranslationLanguages.displayName(for: Self.hudTargetLanguageCode)
    }

    private func listeningLanguageLabel(for code: String) -> String {
        installedLanguages.first(where: { $0.code == code })?.name ?? TranslationLanguages.displayName(for: code)
    }

    private func loadInstalledLanguages() async {
        let installed = await TranslationLanguages.installedTargetOptions()
        installedLanguages = installed
        if !installed.contains(where: { $0.code == listeningLanguageCode }) {
            listeningLanguageCode = installed.first?.code ?? Self.hudTargetLanguageCode
        }
        targetLanguage = Self.hudTargetLanguageCode
    }
}

#Preview {
    HUDLiveView()
        .environmentObject(BluetoothDemoManager())
}

private extension HUDLiveView {
    static var defaultListeningLanguageCode: String {
        if #available(iOS 16.0, *) {
            if let current = Locale.current.language.languageCode?.identifier,
               TranslationLanguages.supported.contains(where: { $0.code == current }) {
                return current
            }
        }

        let identifier = Locale.current.identifier
        if let prefix = identifier.split(separator: "_").first,
           TranslationLanguages.supported.contains(where: { $0.code == String(prefix) }) {
            return String(prefix)
        }

        return "en"
    }
}
