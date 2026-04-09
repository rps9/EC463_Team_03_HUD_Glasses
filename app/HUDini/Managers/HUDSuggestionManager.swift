import Foundation
import Combine

@MainActor
final class HUDSuggestionManager: ObservableObject {
    @Published var suggestionPhonetic: String = ""
    @Published var suggestionEnglish: String = ""

    private var task: Task<Void, Never>?
    private var inFlightSource: (text: String, language: String)?
    private let service = HUDOpenAISuggestionService()

    func refreshSuggestion(for text: String, languageCode: String) {
        task?.cancel()

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            suggestionPhonetic = ""
            suggestionEnglish = ""
            inFlightSource = nil
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

    func clearSuggestion() {
        task?.cancel()
        suggestionPhonetic = ""
        suggestionEnglish = ""
        inFlightSource = nil
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
        }

        guard !Task.isCancelled else { return }

        do {
            let reply = try await service.suggestion(for: text, languageCode: languageCode)
            guard !Task.isCancelled else { return }
            print("[Suggestion] success: phonetic=\(reply.phonetic) english=\(reply.english)")
            suggestionPhonetic = reply.phonetic
            suggestionEnglish = reply.english
        } catch {
            guard !Task.isCancelled else { return }
            print("[Suggestion] error: \(error)")
            suggestionPhonetic = "Error: \(error.localizedDescription)"
            suggestionEnglish = ""
        }
    }
}
