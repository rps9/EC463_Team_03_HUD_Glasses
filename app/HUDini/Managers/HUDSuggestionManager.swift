import Foundation
import Combine

@MainActor
final class HUDSuggestionManager: ObservableObject {
    @Published var suggestionPhonetic: String = ""
    @Published var suggestionEnglish: String = ""
    @Published var isGenerating: Bool = false
    @Published var generationStage: String = ""

    private var task: Task<Void, Never>?
    private var inFlightSource: (text: String, language: String)?
    private let service = HUDOpenAISuggestionService()
    private var profileSnapshot: () -> [String: String]?

    init(profileSnapshot: @escaping () -> [String: String]? = { nil }) {
        self.profileSnapshot = profileSnapshot
    }

    func setProfileSnapshotProvider(_ provider: @escaping () -> [String: String]?) {
        self.profileSnapshot = provider
    }

    func refreshSuggestion(for text: String, languageCode: String) {
        task?.cancel()

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            suggestionPhonetic = ""
            suggestionEnglish = ""
            inFlightSource = nil
            isGenerating = false
            generationStage = ""
            return
        }

        if let current = inFlightSource, current.text == trimmed, current.language == languageCode {
            return
        }
        inFlightSource = (trimmed, languageCode)

        task = Task { [weak self] in
            await self?.generateSuggestion(for: trimmed, languageCode: languageCode)
        }
    }

    func setCustomResponse(translatedNative: String, languageCode: String) {
        task?.cancel()

        let trimmed = translatedNative.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            suggestionPhonetic = ""
            suggestionEnglish = ""
            inFlightSource = nil
            isGenerating = false
            generationStage = ""
            return
        }

        suggestionEnglish = trimmed
        suggestionPhonetic = ""
        inFlightSource = (trimmed, languageCode)

        task = Task { [weak self] in
            await self?.generatePhoneticOnly(for: trimmed, languageCode: languageCode)
        }
    }

    func clearSuggestion() {
        task?.cancel()
        suggestionPhonetic = ""
        suggestionEnglish = ""
        inFlightSource = nil
        isGenerating = false
        generationStage = ""
    }

    deinit {
        task?.cancel()
    }

    private func generateSuggestion(for text: String, languageCode: String) async {
        defer {
            if let current = inFlightSource,
               current.text == text,
               current.language == languageCode {
                inFlightSource = nil
            }
            isGenerating = false
            generationStage = ""
        }

        guard !Task.isCancelled else { return }

        isGenerating = true
        generationStage = "Thinking…"

        do {
            let reply = try await service.generateReply(
                for: text,
                languageCode: languageCode,
                profile: profileSnapshot()
            )
            guard !Task.isCancelled else { return }
            suggestionEnglish = reply.native
            suggestionPhonetic = reply.phonetic
            print("[Suggestion] success: native=\(reply.native) phonetic=\(reply.phonetic)")
        } catch {
            guard !Task.isCancelled else { return }
            print("[Suggestion] error: \(error)")
            suggestionEnglish = ""
            suggestionPhonetic = "Error: \(error.localizedDescription)"
        }
    }

    private func generatePhoneticOnly(for text: String, languageCode: String) async {
        defer {
            if let current = inFlightSource,
               current.text == text,
               current.language == languageCode {
                inFlightSource = nil
            }
            isGenerating = false
            generationStage = ""
        }

        guard !Task.isCancelled else { return }

        isGenerating = true
        generationStage = "Phonetic…"

        do {
            let phonetic = try await service.generatePhonetic(for: text, languageCode: languageCode)
            guard !Task.isCancelled else { return }
            suggestionPhonetic = phonetic.phonetic
            print("[Suggestion] custom phonetic: \(phonetic.phonetic)")
        } catch {
            guard !Task.isCancelled else { return }
            print("[Suggestion] custom phonetic error: \(error)")
            suggestionPhonetic = "Phonetic unavailable"
        }
    }
}
