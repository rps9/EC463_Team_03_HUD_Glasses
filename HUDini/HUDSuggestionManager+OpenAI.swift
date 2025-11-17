import Foundation
import NaturalLanguage

final class HUDOpenAISuggestionService {
    private let urlSession: URLSession
    private let apiKey: String
    private let model: String

    init(apiKey: String, model: String = "gpt-4o-mini", urlSession: URLSession = .shared) {
        self.apiKey = apiKey
        self.model = model
        self.urlSession = urlSession
    }

    func suggestion(for text: String) async throws -> String {
        let language = detectLanguageCode(for: text)
        let prompt = buildPrompt(for: text, languageCode: language)

        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        struct Body: Encodable {
            struct Message: Encodable { let role: String; let content: String }
            let model: String
            let messages: [Message]
            let max_tokens: Int
        }

        let body = Body(
            model: model,
            messages: [Body.Message(role: "user", content: prompt)],
            max_tokens: 80
        )
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw OpenAIError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? ""
            throw OpenAIError.httpFailure(code: http.statusCode, body: message)
        }

        struct Reply: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable { let content: String }
                let message: Message
            }
            let choices: [Choice]
        }
        let decoded = try JSONDecoder().decode(Reply.self, from: data)
        guard let content = decoded.choices.first?.message.content else {
            throw OpenAIError.emptyReply
        }
        return cleanResponse(content)
    }

    private func detectLanguageCode(for text: String) -> String {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        if let lang = recognizer.dominantLanguage {
            return lang.rawValue
        }
        return Locale.current.language.languageCode?.identifier ?? "en"
    }

    private func buildPrompt(for message: String, languageCode: String) -> String {
        """
        Provide exactly one polite short sentence (max 10 words) responding to the following message. Make it very simple and spelled phonetically. Also, the person reading this response is named Ryan. So, if the message is "what's your name?" the reply should be "my name is Ryan, what's your name?" Reply strictly in language code \(languageCode). Do not prefix explanations or bullet points.
        Message: \(message)
        """
    }

    private func cleanResponse(_ response: String) -> String {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        if let sentence = trimmed.split(separator: "\n").first {
            return String(sentence)
        }
        return trimmed
    }

    enum OpenAIError: LocalizedError {
        case invalidResponse
        case httpFailure(code: Int, body: String)
        case emptyReply

        var errorDescription: String? {
            switch self {
            case .invalidResponse:
                return "OpenAI returned an invalid response."
            case .httpFailure(let code, let body):
                return "OpenAI HTTP \(code): \(body)"
            case .emptyReply:
                return "OpenAI returned an empty reply."
            }
        }
    }
}
