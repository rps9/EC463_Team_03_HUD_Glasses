import Foundation

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

