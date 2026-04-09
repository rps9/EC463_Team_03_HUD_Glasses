import Foundation

final class HUDOpenAISuggestionService {
    private let urlSession: URLSession

    struct Suggestion {
        let phonetic: String
        let english: String
    }

    init(urlSession: URLSession = .shared) {
        self.urlSession = urlSession
    }

    func suggestion(for text: String, languageCode: String) async throws -> Suggestion {
        guard let url = URL(string: "\(APIConfig.baseURL)/ai/suggestion") else {
            throw TranslationError.other("Invalid suggestion URL")
        }
        guard let token = KeychainHelper.loadToken() else {
            throw TranslationError.other("Not authenticated")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        struct Body: Encodable {
            let text: String
            let language_code: String
        }
        request.httpBody = try JSONEncoder().encode(Body(text: text, language_code: languageCode))

        let (data, response) = try await urlSession.data(for: request)

        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let body = String(data: data, encoding: .utf8) ?? ""
            throw TranslationError.other("Suggestion API error \(code): \(body)")
        }

        struct Reply: Decodable {
            let reply_native: String
            let reply_phonetic: String
        }

        let reply = try JSONDecoder().decode(Reply.self, from: data)
        return Suggestion(
            phonetic: HUDPhoneticResponseFormatter.clean(reply.reply_phonetic),
            english: reply.reply_native
        )
    }
}
