import Foundation

final class HUDOpenAISuggestionService {
    private let client: HUDOpenAIClient
    private let translationClient: HUDTranslationClient

    init(
        apiKey: String,
        model: String = "gpt-4o-mini",
        urlSession: URLSession = .shared,
        translationClient: HUDTranslationClient? = nil
    ) {
        self.client = HUDOpenAIClient(apiKey: apiKey, model: model, urlSession: urlSession)
        if let translationClient {
            self.translationClient = translationClient
        } else {
            self.translationClient = HUDTranslationClient()
        }
    }

    struct Suggestion {
        let phonetic: String
        let english: String
        let rawPayload: String
    }

    func suggestion(for text: String, languageCode: String) async throws -> Suggestion {
        let (payload, rawPayload) = try await generateCombinedSuggestion(for: text, languageCode: languageCode)
        let englishTranslation = try await translationClient.translate(
            text: payload.reply_native,
            source: languageCode,
            target: "en"
        )

        return Suggestion(
            phonetic: HUDPhoneticResponseFormatter.clean(payload.reply_phonetic),
            english: englishTranslation,
            rawPayload: rawPayload
        )
    }

    private struct CombinedSuggestion: Decodable {
        let reply_native: String
        let reply_phonetic: String
    }

    private func generateCombinedSuggestion(for message: String, languageCode: String) async throws -> (CombinedSuggestion, String) {
        let systemPrompt = """
        You are Ryan, replying to someone in conversation. Respond naturally in the user's language, and include a phonetic rewrite.
        Respond with JSON ONLY in this exact shape:
        {"reply_native":"...", "reply_phonetic":"..."}

        Requirements:
        - reply_native: one friendly sentence in the requested language (standard spelling).
        - reply_phonetic: the same text rewritten phonetically using ASCII letters, spaces, commas, apostrophes, hyphens, periods, and question marks so an English speaker can read it aloud.
        - No explanations, no code fences, no commentary outside the JSON.
        - If asked for your name, say it is Ryan and ask for theirs politely in the target language.
        """

        let messages: [HUDOpenAIChatMessage] = [
            .init(role: "system", content: systemPrompt),
            .init(
                role: "user",
                content: "Language: \(languageCode)\nUser: \(message)"
            )
        ]

        let raw = try await client.complete(messages: messages, maxTokens: 220, temperature: 0.35)
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8) else {
            throw HUDOpenAIClient.Error.emptyReply
        }
        print("HUDOpenAISuggestionService raw payload:", trimmed)
        do {
            let suggestion = try JSONDecoder().decode(CombinedSuggestion.self, from: data)
            return (suggestion, trimmed)
        } catch {
            throw TranslationError.other("Failed to parse suggestion JSON")
        }
    }
}
