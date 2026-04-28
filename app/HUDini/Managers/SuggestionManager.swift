import Foundation

final class HUDOpenAISuggestionService {
    private let urlSession: URLSession

    struct SuggestionReply {
        let native: String
        let phonetic: String
    }

    struct PhoneticResult {
        let phonetic: String
    }

    init(urlSession: URLSession = .shared) {
        self.urlSession = urlSession
    }

    func generateReply(
        for text: String,
        languageCode: String,
        profile: [String: String]?
    ) async throws -> SuggestionReply {
        struct Body: Encodable {
            let text: String
            let language_code: String
            let profile: [String: String]?
        }
        struct Reply: Decodable {
            let reply_native: String
            let reply_phonetic: String
        }

        let body = Body(text: text, language_code: languageCode, profile: profile)
        let reply: Reply = try await postJSON(path: "/ai/suggestion", body: body)
        return SuggestionReply(
            native: reply.reply_native,
            phonetic: HUDPhoneticResponseFormatter.clean(reply.reply_phonetic)
        )
    }

    func generatePhonetic(
        for text: String,
        languageCode: String
    ) async throws -> PhoneticResult {
        struct Body: Encodable {
            let text: String
            let language_code: String
        }
        struct Reply: Decodable {
            let phonetic: String
        }

        let body = Body(text: text, language_code: languageCode)
        let reply: Reply = try await postJSON(path: "/ai/phonetic", body: body)
        return PhoneticResult(phonetic: HUDPhoneticResponseFormatter.clean(reply.phonetic))
    }

    private func postJSON<Body: Encodable, Reply: Decodable>(
        path: String,
        body: Body
    ) async throws -> Reply {
        guard let url = URL(string: "\(APIConfig.baseURL)\(path)") else {
            throw TranslationError.other("Invalid AI endpoint URL")
        }
        guard let token = KeychainHelper.loadToken() else {
            throw TranslationError.other("Not authenticated")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await urlSession.data(for: request)

        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            throw TranslationError.other("AI API error \(code): \(bodyText)")
        }

        return try JSONDecoder().decode(Reply.self, from: data)
    }
}
