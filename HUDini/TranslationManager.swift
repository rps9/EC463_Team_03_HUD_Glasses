import Foundation
import Combine

// MARK: - Translation Service Abstraction

public protocol TranslationService {
    func translate(text: String, source: String?, target: String) async throws -> String
}

public enum TranslationError: LocalizedError, Equatable {
    case emptyInput
    case invalidResponse
    case httpStatus(Int)
    case decoding
    case other(String)

    public var errorDescription: String? {
        switch self {
        case .emptyInput:
            return "Input text is empty"
        case .invalidResponse:
            return "Invalid translation response"
        case .httpStatus(let code):
            return "Translation service HTTP status: \(code)"
        case .decoding:
            return "Failed to decode translation response"
        case .other(let message):
            return message
        }
    }
}

// MARK: - Default Service: LibreTranslate (self-hostable, no key by default)

public struct LibreTranslateService: TranslationService {
    public struct Configuration {
        public var baseURL: URL
        public var apiKey: String?

        public init(baseURL: URL = URL(string: "https://libretranslate.com")!, apiKey: String? = nil) {
            self.baseURL = baseURL
            self.apiKey = apiKey
        }
    }

    private let config: Configuration
    private let urlSession: URLSession

    public init(config: Configuration = .init(), urlSession: URLSession = .shared) {
        self.config = config
        self.urlSession = urlSession
    }

    public func translate(text: String, source: String?, target: String) async throws -> String {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TranslationError.emptyInput
        }

        var request = URLRequest(url: config.baseURL.appendingPathComponent("translate"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        struct Body: Encodable { let q: String; let source: String; let target: String; let format: String; let api_key: String? }
        let body = Body(
            q: text,
            source: source ?? "auto",
            target: target,
            format: "text",
            api_key: config.apiKey
        )
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw TranslationError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw TranslationError.httpStatus(http.statusCode) }

        struct Reply: Decodable { let translatedText: String }
        do {
            let reply = try JSONDecoder().decode(Reply.self, from: data)
            return reply.translatedText
        } catch {
            throw TranslationError.decoding
        }
    }
}

// MARK: - Manager

@MainActor
final class TranslationManager: ObservableObject {
    @Published var translatedText: String = ""
    @Published var isTranslating: Bool = false
    @Published var statusMessage: String = ""

    /// ISO 639-1 language code (e.g., "en", "es"). Use `nil` to auto-detect when supported by the service.
    @Published var sourceLanguageCode: String? = nil
    /// ISO 639-1 language code for the output (e.g., "en", "es"). Default is English.
    @Published var targetLanguageCode: String = "en"

    private let service: TranslationService

    init(service: TranslationService? = nil) {
        if let service {
            self.service = service
        } else if #available(iOS 26.0, *) {
            self.service = AppleTranslationService()
        } else {
            self.service = UnsupportedAppleTranslationService()
        }
    }

    func setTargetLanguage(_ code: String) {
        targetLanguageCode = code
    }

    func setSourceLanguage(_ code: String?) {
        sourceLanguageCode = code
    }

    func clear() {
        translatedText = ""
        statusMessage = ""
    }

    func translate(_ text: String) async {
        guard !isTranslating else { return }
        isTranslating = true
        statusMessage = "Translating…"
        defer { isTranslating = false }

        do {
            let result = try await service.translate(
                text: text,
                source: sourceLanguageCode,
                target: targetLanguageCode
            )
            translatedText = result
            statusMessage = ""
        } catch {
            translatedText = ""
            if let e = error as? LocalizedError, let msg = e.errorDescription {
                statusMessage = msg
            } else {
                statusMessage = "Translation failed"
            }
        }
    }
}


