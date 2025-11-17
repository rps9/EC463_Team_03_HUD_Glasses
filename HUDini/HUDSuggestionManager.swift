import Foundation
import Combine

@MainActor
final class HUDSuggestionManager: ObservableObject {
    @Published var suggestion: String = ""

    private var task: Task<Void, Never>?
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
            suggestion = ""
            return
        }

        task = Task { [weak self] in
            await self?.generateSuggestion(for: trimmed)
        }
    }

    // (factory helper removed)

    deinit {
        task?.cancel()
    }

    private func generateSuggestion(for text: String) async {
        guard !Task.isCancelled else { return }
        guard let openAIService else { return }

        do {
            let reply = try await openAIService.suggestion(for: text)
            guard !Task.isCancelled else { return }
            suggestion = reply
        } catch {
            guard !Task.isCancelled else { return }
            suggestion = "OpenAI error: \(error.localizedDescription)"
        }
    }

}
