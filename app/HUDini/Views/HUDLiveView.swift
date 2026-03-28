import SwiftUI

struct HUDLiveView: View {
    @StateObject private var transcriptionManager = TranscriptionManager()
    @StateObject private var suggestionManager = HUDSuggestionManager()
    @State private var targetLanguage: String = "en"
    @State private var listeningLanguageCode: String = HUDLiveView.defaultListeningLanguageCode
    @State private var installedLanguages: [TranslationLanguageOption] = TranslationLanguages.supported
    @State private var suggestionRefreshTask: Task<Void, Never>?

    private let hudCharacterLimit: Int = 260
    private static let suggestionDebounceNanoseconds: UInt64 = 450_000_000

    var body: some View {
        VStack(spacing: 24) {
            Spacer(minLength: 0)

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

            suggestionCard

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
                        ForEach(installedLanguages) { option in
                            Text(option.name).tag(option.code)
                        }
                    }
                } label: {
                    Label(languageLabel(for: targetLanguage), systemImage: "globe")
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
            scheduleDebouncedSuggestionRefresh(for: newValue)
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
                translatingTo: targetLanguage
            )
        }
    }

    private func scheduleDebouncedSuggestionRefresh(for text: String) {
        suggestionRefreshTask?.cancel()
        let delay = Self.suggestionDebounceNanoseconds
        let lang = targetLanguage
        suggestionRefreshTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            suggestionManager.refreshSuggestion(for: text, languageCode: lang)
        }
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

    private func languageLabel(for code: String) -> String {
        installedLanguages.first(where: { $0.code == code })?.name ?? TranslationLanguages.displayName(for: code)
    }

    private func listeningLanguageLabel(for code: String) -> String {
        installedLanguages.first(where: { $0.code == code })?.name ?? TranslationLanguages.displayName(for: code)
    }

    private func loadInstalledLanguages() async {
        let installed = await TranslationLanguages.installedTargetOptions()
        installedLanguages = installed
        if !installed.contains(where: { $0.code == listeningLanguageCode }) {
            listeningLanguageCode = installed.first?.code ?? "en"
        }
        if !installed.contains(where: { $0.code == targetLanguage }) {
            targetLanguage = installed.first?.code ?? "en"
        }
    }
}

#Preview { HUDLiveView() }

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
