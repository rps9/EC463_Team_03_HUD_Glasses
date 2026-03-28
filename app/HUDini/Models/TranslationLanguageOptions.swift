import Foundation
#if canImport(Translation)
import Translation
#endif

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

    /// Returns only languages that are installed (downloaded) for Apple Translate. Use for Translation and HUDini pickers.
    /// When Translation framework is unavailable (e.g. simulator), returns full supported list.
    static func installedTargetOptions() async -> [TranslationLanguageOption] {
        #if canImport(Translation)
        if #available(iOS 26.0, *) {
            return await _installedTargetOptionsFromAvailability()
        }
        #endif
        return supported
    }

    /// Source options for translation: Auto Detect + installed languages only.
    static func installedSourceOptions() async -> [TranslationLanguageOption] {
        let installed = await installedTargetOptions()
        return [.init(code: autoCode, name: "Auto Detect")] + installed
    }
}

#if canImport(Translation)
@available(iOS 26.0, *)
private func _installedTargetOptionsFromAvailability() async -> [TranslationLanguageOption] {
    let availability = LanguageAvailability()
    let reference = Locale.Language(identifier: "en")
    let supported = await availability.supportedLanguages
    var result: [TranslationLanguageOption] = []
    let locale = Locale.current
    for lang in supported {
        let id = lang.minimalIdentifier
        if id == "en" {
            result.append(.init(code: "en", name: "English"))
            continue
        }
        let status = await availability.status(from: reference, to: lang)
        if status == .installed {
            let name = locale.localizedString(forLanguageCode: lang.languageCode?.identifier ?? id) ?? TranslationLanguages.supported.first(where: { $0.code == id })?.name ?? id
            result.append(.init(code: id, name: name))
        }
    }
    return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
}
#endif

