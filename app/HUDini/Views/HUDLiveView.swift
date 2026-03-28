import SwiftUI

struct HUDLiveView: View {
    @EnvironmentObject private var bluetoothManager: BluetoothDemoManager
    @StateObject private var transcriptionManager = TranscriptionManager()
    @StateObject private var suggestionManager = HUDSuggestionManager()
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
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 20) {
                displayCard
                suggestionCard
                controlsCard
                connectionCard
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 30)
        }
        .hudScreen()
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text("Live HUD")
                    .font(.system(.headline, design: .rounded, weight: .semibold))
                    .foregroundStyle(HUDTheme.ink)
            }
        }
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
        .onDisappear {
            suggestionRefreshTask?.cancel()
            suggestionRefreshTask = nil
            transcriptionManager.stop()
            suggestionManager.clearSuggestion()
        }
    }

    private var displayCard: some View {
        HUDCard(padding: 18) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Translated Output")
                        .font(.system(.headline, design: .rounded, weight: .semibold))
                        .foregroundStyle(HUDTheme.ink)

                    Spacer()

                    HUDStatusPill(
                        text: "\(hudDisplayText.count) chars",
                        tint: HUDTheme.accent
                    )
                }

                Text(hudDisplayText.isEmpty ? "Translation output appears here as speech is processed." : hudDisplayText)
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .minimumScaleFactor(0.58)
                    .lineLimit(hudDisplayText.isEmpty ? 4 : 6)
                    .foregroundStyle(HUDTheme.ink)
                    .frame(maxWidth: .infinity, minHeight: 220, alignment: .center)
                    .multilineTextAlignment(.center)
                    .padding(24)
                    .background(
                        LinearGradient(
                            colors: [Color.white.opacity(0.98), HUDTheme.backgroundTop.opacity(0.9)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        in: RoundedRectangle(cornerRadius: 26, style: .continuous)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 26, style: .continuous)
                            .stroke(HUDTheme.strokeStrong.opacity(0.7), lineWidth: 1)
                    }
            }
        }
    }

    private var suggestionCard: some View {
        HUDCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Suggested Reply")
                        .font(.system(.headline, design: .rounded, weight: .semibold))
                        .foregroundStyle(HUDTheme.ink)

                    Spacer()

                    Image(systemName: "quote.bubble")
                        .foregroundStyle(HUDTheme.inkMuted)
                }

                Text(suggestionManager.suggestionPhonetic.isEmpty ? "Suggestions appear while the live stream is running." : suggestionManager.suggestionPhonetic)
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                    .foregroundStyle(HUDTheme.ink)

                if !suggestionManager.suggestionEnglish.isEmpty {
                    Text(suggestionManager.suggestionEnglish)
                        .font(.system(.body, design: .rounded))
                        .foregroundStyle(HUDTheme.inkMuted)
                }
            }
        }
    }

    private var controlsCard: some View {
        HUDCard {
            VStack(alignment: .leading, spacing: 18) {
                Text("Session Controls")
                    .font(.system(.headline, design: .rounded, weight: .semibold))
                    .foregroundStyle(HUDTheme.ink)

                HStack(spacing: 14) {
                    languagePickerCard(
                        title: "Listening Language",
                        value: listeningLanguageLabel(for: listeningLanguageCode),
                        icon: "globe.badge.chevron.backward",
                        selection: $listeningLanguageCode,
                        options: installedLanguages
                    )

                    languagePickerCard(
                        title: "Display Language",
                        value: targetLanguageLabel,
                        icon: "globe.badge.chevron.forward",
                        selection: $targetLanguage,
                        options: Self.hudTargetLanguageOptions
                    )
                }

                Button {
                    toggleListening()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: transcriptionManager.isTranscribing ? "stop.fill" : "mic.fill")
                        Text(transcriptionManager.isTranscribing ? "Stop Listening" : "Start Listening")
                    }
                }
                .buttonStyle(
                    HUDPrimaryButtonStyle(
                        tint: transcriptionManager.isTranscribing ? HUDTheme.rose : HUDTheme.ink
                    )
                )

                if !transcriptionManager.statusMessage.isEmpty {
                    Text(transcriptionManager.statusMessage)
                        .font(.system(.footnote, design: .rounded))
                        .foregroundStyle(HUDTheme.inkMuted)
                }
            }
        }
    }

    private var connectionCard: some View {
        HUDCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Device Sync")
                        .font(.system(.headline, design: .rounded, weight: .semibold))
                        .foregroundStyle(HUDTheme.ink)
                    Spacer()
                    HUDStatusPill(
                        text: isTransceiverConnected ? "Ready to send" : "Not connected",
                        tint: isTransceiverConnected ? HUDTheme.mint : HUDTheme.amber,
                        icon: "antenna.radiowaves.left.and.right"
                    )
                }

                Text(isTransceiverConnected
                     ? "Translated output is mirrored to the BLE transceiver automatically whenever the rendered text changes."
                     : "Connect the HUD transceiver from Settings > Bluetooth to send rendered output to the device.")
                    .font(.system(.body, design: .rounded))
                    .foregroundStyle(HUDTheme.inkMuted)
            }
        }
    }

    private func languagePickerCard(
        title: String,
        value: String,
        icon: String,
        selection: Binding<String>,
        options: [TranslationLanguageOption]
    ) -> some View {
        Menu {
            Picker(title, selection: selection) {
                ForEach(options) { option in
                    Text(option.name).tag(option.code)
                }
            }
        } label: {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Image(systemName: icon)
                    Text(title)
                }
                .font(.system(.caption, design: .rounded, weight: .semibold))
                .foregroundStyle(HUDTheme.inkMuted)

                HStack {
                    Text(value)
                        .font(.system(.body, design: .rounded, weight: .semibold))
                        .foregroundStyle(HUDTheme.ink)
                        .lineLimit(1)
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(HUDTheme.inkMuted)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.82), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(HUDTheme.strokeStrong, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .menuOrder(.fixed)
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
            suggestionManager.refreshSuggestion(for: text, languageCode: Self.hudTargetLanguageCode)
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
    NavigationStack {
        HUDLiveView()
            .environmentObject(BluetoothDemoManager())
    }
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
