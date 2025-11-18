import Foundation

struct TranslationLanguageOption: Identifiable, Hashable {
    let code: String
    let name: String

    var id: String { code }
}

enum TranslationLanguages {
    static let autoCode = "auto"

    static let supported: [TranslationLanguageOption] = [
        .init(code: "en", name: "English"),
        .init(code: "es", name: "Spanish"),
        .init(code: "fr", name: "French"),
        .init(code: "ar", name: "Arabic"),
        .init(code: "de", name: "German"),
        .init(code: "hi", name: "Hindi"),
        .init(code: "ja", name: "Japanese"),
        .init(code: "ko", name: "Korean"),
        .init(code: "pt", name: "Portuguese"),
        .init(code: "ru", name: "Russian"),
        .init(code: "zh", name: "Chinese (Simplified)"),
        .init(code: "zh-Hant", name: "Chinese (Traditional)")
    ]

    static let sourceOptions: [TranslationLanguageOption] = [
        .init(code: autoCode, name: "Auto Detect")
    ] + supported

    static let targetOptions: [TranslationLanguageOption] = supported

    static func displayName(for code: String?) -> String {
        let normalized = code ?? autoCode
        if normalized == autoCode {
            return sourceOptions.first(where: { $0.code == autoCode })?.name ?? "Auto"
        }
        return supported.first(where: { $0.code == normalized })?.name ?? normalized.uppercased()
    }
}

