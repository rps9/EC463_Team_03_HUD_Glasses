import Foundation
import NaturalLanguage

final class HUDOpenAISuggestionService {
    private let client: HUDOpenAIClient

    init(apiKey: String, model: String = "gpt-4o-mini", urlSession: URLSession = .shared) {
        self.client = HUDOpenAIClient(apiKey: apiKey, model: model, urlSession: urlSession)
    }

    struct Suggestion {
        let phonetic: String
        let english: String
    }

    func suggestion(for text: String) async throws -> Suggestion {
        let language = detectLanguageCode(for: text)
        let payload = try await generateCombinedSuggestion(for: text, languageCode: language)

        return Suggestion(
            phonetic: HUDPhoneticResponseFormatter.clean(payload.reply_phonetic),
            english: payload.reply_english.trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }

    private func detectLanguageCode(for text: String) -> String {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        if let lang = recognizer.dominantLanguage {
            return lang.rawValue
        }
        return Locale.current.language.languageCode?.identifier ?? "en"
    }

    private struct CombinedSuggestion: Decodable {
        let reply_native: String
        let reply_phonetic: String
        let reply_english: String
    }

    private func generateCombinedSuggestion(for message: String, languageCode: String) async throws -> CombinedSuggestion {
        let systemPrompt = """
        You are Ryan, replying to someone in conversation. Respond naturally in the user's language, and include both a phonetic rewrite and an English translation.
        Respond with JSON ONLY in this exact shape:
        {"reply_native":"...", "reply_phonetic":"...", "reply_english":"..."}

        Requirements:
        - reply_native: one friendly sentence in the requested language (standard spelling).
        - reply_phonetic: the same text rewritten phonetically using ASCII letters, spaces, commas, apostrophes, hyphens, periods, and question marks so an English speaker can read it aloud.
        - reply_english: a natural English translation of the same sentence.
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
        guard let data = raw.trimmingCharacters(in: .whitespacesAndNewlines).data(using: .utf8) else {
            throw HUDOpenAIClient.Error.emptyReply
        }
        do {
            return try JSONDecoder().decode(CombinedSuggestion.self, from: data)
        } catch {
            throw TranslationError.other("Failed to parse suggestion JSON")
        }
    }
}
