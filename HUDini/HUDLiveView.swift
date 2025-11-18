import SwiftUI

/// Minimal HUD-style view that streams live translations while speech is still coming in.
struct HUDLiveView: View {
    @StateObject private var transcription = TranscriptionManager()
    @StateObject private var translator = TranslationManager()
    @StateObject private var suggestionManager = HUDSuggestionManager()
    @State private var queuedTask: Task<Void, Never>? = nil
    @State private var targetLanguage: String = "en"
    @State private var listeningLanguageCode: String = HUDLiveView.defaultListeningLanguageCode
    @State private var lastTranslatedInput: String = ""
    @State private var hudBuffer: String = ""
    @State private var previousFullTranslation: String = ""
    private let hudCharacterLimit: Int = 260

    var body: some View {
        VStack(spacing: 24) {
            Spacer(minLength: 0)

            Text(hudBuffer.isEmpty ? "…" : hudBuffer)
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
                        ForEach(TranslationLanguages.supported) { option in
                            Text(option.name).tag(option.code)
                        }
                    }
                    .onChange(of: listeningLanguageCode, initial: false) { _, newValue in
                        transcription.setListeningLanguage(newValue)
                        translator.setSourceLanguage(newValue)
                    }
                } label: {
                    Label(listeningLanguageLabel(for: listeningLanguageCode), systemImage: "ear")
                        .labelStyle(.titleAndIcon)
                }
                .menuOrder(.fixed)
                .tint(.secondary)

                Menu {
                    Picker("Target language", selection: $targetLanguage) {
                        ForEach(TranslationLanguages.targetOptions) { option in
                            Text(option.name).tag(option.code)
                        }
                    }
                    .onChange(of: targetLanguage, initial: false) { _, newValue in
                        translator.setTargetLanguage(newValue)
                        scheduleTranslation(for: transcription.transcript)
                    }
                } label: {
                    Label(languageLabel(for: targetLanguage), systemImage: "globe")
                        .labelStyle(.titleAndIcon)
                }
                .menuOrder(.fixed)
                .tint(.secondary)

                Button(transcription.isTranscribing ? "Stop" : "Start") {
                    transcription.isTranscribing ? stopListening() : startListening()
                }
                .buttonStyle(.borderedProminent)
                .tint(transcription.isTranscribing ? .red : .accentColor)
                .font(.title3)
            }

            Spacer(minLength: 0)
        }
        .padding(32)
        .background(Color.black.opacity(0.02))
        .task { await transcription.requestPermissions() }
        .onAppear {
            transcription.setListeningLanguage(listeningLanguageCode)
            translator.setSourceLanguage(listeningLanguageCode)
            translator.setTargetLanguage(targetLanguage)
        }
        .onDisappear {
            queuedTask?.cancel()
        }
        .onChange(of: transcription.transcript, initial: false) { _, newValue in
            scheduleTranslation(for: newValue)
        }
    }

    private func startListening() {
        translator.clear()
        lastTranslatedInput = ""
        previousFullTranslation = ""
        hudBuffer = ""
        suggestionManager.suggestionPhonetic = ""
        suggestionManager.suggestionEnglish = ""
        transcription.start()
    }

    private func stopListening() {
        transcription.stop()
        queuedTask?.cancel()
        queuedTask = nil
    }

    private func scheduleTranslation(for text: String) {
        queuedTask?.cancel()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            queuedTask = nil
            return
        }
        guard trimmed != lastTranslatedInput else { return }

        queuedTask = Task { [trimmed] in
            do {
                try await Task.sleep(nanoseconds: 150_000_000)
                await translator.translate(trimmed)
                lastTranslatedInput = trimmed
                integrateLatestTranslation()
                suggestionManager.refreshSuggestion(for: trimmed)
            } catch {
                if !(error is CancellationError) {
                    let message = (error as NSError).localizedDescription
                    translator.statusMessage = "Translation error: \(message)"
                }
            }
        }
    }

    private func integrateLatestTranslation() {
        let latest = translator.translatedText
        guard !latest.isEmpty else { return }

        let addition: String
        if latest.hasPrefix(previousFullTranslation) {
            addition = String(latest.dropFirst(previousFullTranslation.count))
        } else {
            addition = latest
            hudBuffer = ""
        }

        previousFullTranslation = latest

        let trimmedAddition = addition.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedAddition.isEmpty else { return }

        hudBuffer.append(hudBuffer.isEmpty ? trimmedAddition : " " + trimmedAddition)
        if hudBuffer.count > hudCharacterLimit {
            hudBuffer = String(hudBuffer.suffix(hudCharacterLimit))
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
        TranslationLanguages.targetOptions.first(where: { $0.code == code })?.name ?? code.uppercased()
    }

    private func listeningLanguageLabel(for code: String) -> String {
        TranslationLanguages.supported.first(where: { $0.code == code })?.name ?? code.uppercased()
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
