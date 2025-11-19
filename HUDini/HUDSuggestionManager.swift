import Foundation
import Combine

@MainActor
final class HUDSuggestionManager: ObservableObject {
    @Published var suggestionPhonetic: String = ""
    @Published var suggestionEnglish: String = ""

    private var task: Task<Void, Never>?
    private var inFlightSource: String?
    private let openAIService: HUDOpenAISuggestionService?

    init(openAIService: HUDOpenAISuggestionService? = nil) {
        if let provided = openAIService {
            self.openAIService = provided
            return
        }
        if let apiKey = ProcessInfo.processInfo.environment["OPENAI_API_KEY"], !apiKey.isEmpty {
            self.openAIService = HUDOpenAISuggestionService(apiKey: apiKey)
        } else {
            self.openAIService = nil
        }
    }

    func refreshSuggestion(for text: String) {
        task?.cancel()

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            suggestionPhonetic = ""
            suggestionEnglish = ""
            inFlightSource = nil
            return
        }

        guard trimmed != inFlightSource else { return }
        inFlightSource = trimmed

        task = Task { [weak self] in
            await self?.generateSuggestion(for: trimmed)
        }
    }

    // (factory helper removed)

    deinit {
        task?.cancel()
    }

    private func generateSuggestion(for text: String) async {
        defer {
            if inFlightSource == text {
                inFlightSource = nil
            }
        }

        guard !Task.isCancelled else { return }
        guard let openAIService else { return }

        do {
            let reply = try await openAIService.suggestion(for: text)
            guard !Task.isCancelled else { return }
            suggestionPhonetic = reply.phonetic
            suggestionEnglish = reply.english
        } catch {
            guard !Task.isCancelled else { return }
            suggestionPhonetic = "OpenAI error: \(error.localizedDescription)"
            suggestionEnglish = ""
        }
    }

}
