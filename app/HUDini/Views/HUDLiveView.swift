import SwiftUI

struct HUDLiveView: View {
    @EnvironmentObject private var frameManager: FrameBluetoothManager
    @EnvironmentObject private var conversationHistoryStore: HUDConversationHistoryStore
    @AppStorage(wrappedValue: true, APIConfig.AppStorageKey.hudSuggestionEnabled) private var suggestionEnabled: Bool
    @AppStorage(wrappedValue: TranslationLanguages.defaultListeningLanguageCode, APIConfig.AppStorageKey.hudListeningLanguageCode) private var storedListeningLanguageCode: String
    @StateObject private var transcriptionManager = TranscriptionManager()
    @StateObject private var suggestionManager = HUDSuggestionManager()
    @State private var targetLanguage: String = "en"
    @State private var listeningLanguageCode: String = TranslationLanguages.defaultListeningLanguageCode
    @State private var installedLanguages: [TranslationLanguageOption] = TranslationLanguages.supported
    @State private var renderedTextDebounceTask: Task<Void, Never>?
    @State private var lastSentBLEText: String = ""

    private let hudCharacterLimit: Int = 260
    private static let renderedTextDebounceNanoseconds: UInt64 = 450_000_000
    private static let hudTargetLanguageCode = "en"
    private static var hudTargetLanguageOptions: [TranslationLanguageOption] {
        TranslationLanguages.supported.filter { $0.code == hudTargetLanguageCode }
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 20) {
                displayCard
                if APIConfig.isSuggestionFeatureEnabled {
                    suggestionCard
                }
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
            applyInitialLanguageConfiguration()
        }
        .onChange(of: listeningLanguageCode, initial: false) { _, newValue in
            transcriptionManager.setListeningLanguage(newValue)
            frameManager.setRecognitionLanguage(newValue)
        }
        .onChange(of: targetLanguage, initial: false) { _, newValue in
            transcriptionManager.setTargetLanguage(newValue)
            frameManager.setTargetLanguage(newValue)
        }
        .onChange(of: transcriptionManager.renderedText, initial: false) { _, newValue in
            if !shouldUseFrameMic {
                scheduleDebouncedHUDSideEffects(for: newValue)
            }
        }
        .onChange(of: frameManager.renderedText, initial: false) { _, newValue in
            if shouldUseFrameMic {
                scheduleDebouncedHUDSideEffects(for: newValue)
            }
        }
        .onChange(of: frameManager.state, initial: false) { _, newState in
            if !isFrameConnected(state: newState) {
                lastSentBLEText = ""
            }
        }
        .onChange(of: suggestionManager.suggestionEnglish, initial: false) { _, _ in
            pushSuggestionToFrame()
        }
        .onChange(of: suggestionManager.suggestionPhonetic, initial: false) { _, _ in
            pushSuggestionToFrame()
        }
        .onChange(of: suggestionEnabled, initial: false) { _, enabled in
            guard APIConfig.isSuggestionFeatureEnabled else { return }
            if !enabled {
                renderedTextDebounceTask?.cancel()
                renderedTextDebounceTask = nil
                suggestionManager.clearSuggestion()
                frameManager.sendSuggestions([])
            }
        }
        .onDisappear {
            renderedTextDebounceTask?.cancel()
            renderedTextDebounceTask = nil
            if isListening {
                persistConversationSnapshotIfNonEmpty()
            }
            transcriptionManager.stop()
            if frameManager.isStreaming {
                frameManager.stopAudioStream()
            }
            if APIConfig.isSuggestionFeatureEnabled {
                suggestionManager.clearSuggestion()
                frameManager.sendSuggestions([])
            }
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
                        Image(systemName: isListening ? "stop.fill" : "mic.fill")
                        Text(isListening ? "Stop Listening" : "Start Listening")
                    }
                }
                .buttonStyle(
                    HUDPrimaryButtonStyle(
                        tint: isListening ? HUDTheme.rose : HUDTheme.ink
                    )
                )
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
                        text: isFrameConnected ? "Ready to send" : "Not connected",
                        tint: isFrameConnected ? HUDTheme.mint : HUDTheme.amber,
                        icon: "antenna.radiowaves.left.and.right"
                    )
                }

                Text(isFrameConnected
                     ? "Translated output is mirrored to the Frame glasses automatically whenever the rendered text changes."
                     : "Connect the Frame glasses from Settings > Bluetooth to send rendered output to the device.")
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
        let sourceText = shouldUseFrameMic ? frameManager.renderedText : transcriptionManager.renderedText
        let raw = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return "" }
        if raw.count > hudCharacterLimit {
            return String(raw.suffix(hudCharacterLimit))
        }
        return raw
    }

    private var activeTranscriptText: String {
        shouldUseFrameMic ? frameManager.liveTranscript : transcriptionManager.transcript
    }

    private var activeRenderedText: String {
        shouldUseFrameMic ? frameManager.renderedText : transcriptionManager.renderedText
    }

    private var shouldUseFrameMic: Bool {
        isFrameConnected
    }

    private var isListening: Bool {
        shouldUseFrameMic ? frameManager.isStreaming : transcriptionManager.isTranscribing
    }

    private func toggleListening() {
        if isListening {
            persistConversationSnapshotIfNonEmpty()
            if shouldUseFrameMic {
                frameManager.stopAudioStream()
            } else {
                transcriptionManager.stop()
            }
            renderedTextDebounceTask?.cancel()
            renderedTextDebounceTask = nil
            if APIConfig.isSuggestionFeatureEnabled {
                suggestionManager.clearSuggestion()
                frameManager.sendSuggestions([])
            }
        } else {
            if shouldUseFrameMic {
                frameManager.startTranscribing(
                    listeningLanguage: listeningLanguageCode,
                    translatingTo: Self.hudTargetLanguageCode
                )
            } else {
                transcriptionManager.startTranscribing(
                    listeningLanguage: listeningLanguageCode,
                    translatingTo: Self.hudTargetLanguageCode
                )
            }
        }
    }

    private var isFrameConnected: Bool {
        isFrameConnected(state: frameManager.state)
    }

    private func isFrameConnected(state: FrameBluetoothManager.ConnectionState) -> Bool {
        if case .connected = state { return true }
        return false
    }

    private func scheduleDebouncedHUDSideEffects(for text: String) {
        renderedTextDebounceTask?.cancel()
        let delay = Self.renderedTextDebounceNanoseconds
        renderedTextDebounceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            if APIConfig.isSuggestionFeatureEnabled, suggestionEnabled {
                suggestionManager.refreshSuggestion(for: text, languageCode: Self.hudTargetLanguageCode)
            }
            pushTranslatedTextToFrameIfNeeded(text)
        }
    }

    private func pushTranslatedTextToFrameIfNeeded(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard isFrameConnected else { return }
        guard trimmed != lastSentBLEText else { return }
        lastSentBLEText = trimmed
        frameManager.sendHUDTextToFrame(trimmed, isPartial: false, updateStatus: false)
    }

    private func pushSuggestionToFrame() {
        guard isFrameConnected else { return }
        guard APIConfig.isSuggestionFeatureEnabled, suggestionEnabled else { return }

        let suggestion = FrameSuggestionDisplay(
            text: suggestionManager.suggestionEnglish,
            phonetic: suggestionManager.suggestionPhonetic
        )
        if suggestion.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            frameManager.sendSuggestions([])
        } else {
            frameManager.sendSuggestions([suggestion])
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

    private func applyInitialLanguageConfiguration() {
        let resolvedListeningCode: String
        if installedLanguages.contains(where: { $0.code == storedListeningLanguageCode }) {
            resolvedListeningCode = storedListeningLanguageCode
        } else {
            resolvedListeningCode = listeningLanguageCode
        }

        listeningLanguageCode = resolvedListeningCode
        storedListeningLanguageCode = resolvedListeningCode
        transcriptionManager.setListeningLanguage(resolvedListeningCode)
        frameManager.setRecognitionLanguage(resolvedListeningCode)
        transcriptionManager.setTargetLanguage(targetLanguage)
        frameManager.setTargetLanguage(targetLanguage)
    }

    /// Saves the current HUD translation when a listening session ends (stop button or leaving Live while mic is on).
    private func persistConversationSnapshotIfNonEmpty() {
        let translated = activeRenderedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !translated.isEmpty else { return }
        let source = activeTranscriptText.trimmingCharacters(in: .whitespacesAndNewlines)
        let entry = HUDConversationHistoryEntry(
            id: UUID(),
            createdAt: Date(),
            sourceText: source,
            translatedText: translated,
            listeningLanguageCode: listeningLanguageCode,
            displayLanguageCode: targetLanguage
        )
        conversationHistoryStore.append(entry)
    }
}

#Preview {
    NavigationStack {
        HUDLiveView()
            .environmentObject(FrameBluetoothManager())
            .environmentObject(HUDConversationHistoryStore())
    }
}
