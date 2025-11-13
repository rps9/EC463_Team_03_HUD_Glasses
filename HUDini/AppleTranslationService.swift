import Foundation
#if canImport(Translation)
import Translation
#endif
import NaturalLanguage

#if canImport(Translation)
@available(iOS 26.0, *)
public struct AppleTranslationService: TranslationService {
    public init() {}

    public func translate(text: String, source: String?, target: String) async throws -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw TranslationError.emptyInput
        }

        let targetLanguage = try resolveLanguage(code: target)
        let sourceLanguage = try sourceLanguage(from: trimmed, requestedCode: source)

        let session = TranslationSession(installedSource: sourceLanguage, target: targetLanguage)

        do {
            try await session.prepareTranslation()
            let response = try await session.translate(trimmed)
            return response.targetText
        } catch let error as Translation.TranslationError {
            throw map(error)
        } catch {
            throw TranslationError.other(error.localizedDescription)
        }
    }

    private func sourceLanguage(from text: String, requestedCode: String?) throws -> Locale.Language {
        if let code = requestedCode {
            return try resolveLanguage(code: code)
        }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        guard let dominant = recognizer.dominantLanguage else {
            throw TranslationError.other("Unable to detect source language")
        }
        return try resolveLanguage(code: dominant.rawValue)
    }

    private func resolveLanguage(code: String) throws -> Locale.Language {
        let language = Locale.Language(identifier: code)
        if language.languageCode == nil {
            throw TranslationError.other("Unsupported language code: \(code)")
        }
        return language
    }

    private func map(_ error: Translation.TranslationError) -> TranslationError {
        switch error {
        case .unsupportedSourceLanguage:
            return .other("Unsupported source language")
        case .unsupportedTargetLanguage:
            return .other("Unsupported target language")
        case .unsupportedLanguagePairing:
            return .other("Unsupported language pairing")
        case .unableToIdentifyLanguage:
            return .other("Unable to identify language")
        case .nothingToTranslate:
            return .emptyInput
        case .alreadyCancelled:
            return .other("Translation cancelled")
        case .notInstalled:
            return .other("Required translation language pack not installed")
        default:
            return .other("Apple Translation failed")
        }
    }
}
#endif

struct UnsupportedAppleTranslationService: TranslationService {
    func translate(text: String, source: String?, target: String) async throws -> String {
        throw TranslationError.other("Apple Translation requires iOS 26 or later")
    }
}

