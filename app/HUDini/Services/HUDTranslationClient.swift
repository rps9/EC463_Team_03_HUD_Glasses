import Foundation
#if canImport(Translation)
import Translation
#endif

struct HUDTranslationClient {
    private let service: TranslationService

    init(service: TranslationService? = nil) {
        if let service {
            self.service = service
        } else {
            self.service = HUDTranslationClient.makeDefaultService()
        }
    }

    func translate(text: String, source: String?, target: String) async throws -> String {
        try await service.translate(text: text, source: source, target: target)
    }

    static func translate(text: String, source: String?, target: String) async throws -> String {
        try await HUDTranslationClient().translate(text: text, source: source, target: target)
    }

    static func makeDefaultService() -> TranslationService {
#if canImport(Translation)
        if #available(iOS 26.0, *) {
            return AppleTranslationService()
        }
#endif
        return LibreTranslateService()
    }
}
