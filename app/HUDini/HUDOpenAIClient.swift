import Foundation

struct HUDOpenAIChatMessage: Encodable {
    let role: String
    let content: String
}

final class HUDOpenAIClient {
    enum Error: LocalizedError {
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

    private let apiKey: String
    private let model: String
    private let urlSession: URLSession

    init(apiKey: String, model: String = "gpt-4o-mini", urlSession: URLSession = .shared) {
        self.apiKey = apiKey
        self.model = model
        self.urlSession = urlSession
    }

    func complete(messages: [HUDOpenAIChatMessage], maxTokens: Int, temperature: Double) async throws -> String {
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        struct Body: Encodable {
            let model: String
            let messages: [HUDOpenAIChatMessage]
            let max_tokens: Int
            let temperature: Double
        }

        let body = Body(model: model, messages: messages, max_tokens: maxTokens, temperature: temperature)
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await urlSession.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw Error.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? ""
            throw Error.httpFailure(code: http.statusCode, body: message)
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
            throw Error.emptyReply
        }

        return content
    }
}
