import SwiftUI

/// Minimal HUD-style view that streams live translations while speech is still coming in.
struct HUDLiveView: View {
    @StateObject private var transcription = TranscriptionManager()
    @StateObject private var translator = TranslationManager()
    @StateObject private var suggestionManager = HUDSuggestionManager()
    @State private var queuedTask: Task<Void, Never>? = nil
    @State private var targetLanguage: String = "es"
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
        suggestionManager.suggestion = ""
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

            Text(suggestionManager.suggestion.isEmpty ? "Suggestions appear while listening." : suggestionManager.suggestion)
                .font(.title3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(18)
                .background(Color(.tertiarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 16))
        }
    }

    private func languageLabel(for code: String) -> String {
        TranslationLanguages.targetOptions.first(where: { $0.code == code })?.name ?? code.uppercased()
    }
}

#Preview { HUDLiveView() }
