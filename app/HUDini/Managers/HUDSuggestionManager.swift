import Foundation
import Combine
import UIKit

@MainActor
final class HUDSuggestionManager: ObservableObject {
    @Published var suggestionPhonetic: String = ""
    @Published var suggestionEnglish: String = ""   // natural English meaning
    @Published var suggestionNative: String = ""    // target-language text (e.g. Spanish)
    @Published var isGenerating: Bool = false
    @Published var generationStage: String = ""

    private var task: Task<Void, Never>?
    private var inFlightSource: (text: String, language: String)?
    private let service = HUDOpenAISuggestionService()
    private var profileSnapshot: () -> [String: String]?

    init(profileSnapshot: @escaping () -> [String: String]? = { nil }) {
        self.profileSnapshot = profileSnapshot
    }

    func setProfileSnapshotProvider(_ provider: @escaping () -> [String: String]?) {
        self.profileSnapshot = provider
    }

    func refreshSuggestion(for text: String, languageCode: String) {
        task?.cancel()

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            suggestionPhonetic = ""
            suggestionEnglish = ""
            suggestionNative = ""
            inFlightSource = nil
            isGenerating = false
            generationStage = ""
            return
        }

        if let current = inFlightSource, current.text == trimmed, current.language == languageCode {
            return
        }
        inFlightSource = (trimmed, languageCode)

        let bgID = UIApplication.shared.beginBackgroundTask(withName: "hudini.suggestion")

        task = Task { [weak self] in
            await self?.generateSuggestion(for: trimmed, languageCode: languageCode)
            if bgID != .invalid {
                UIApplication.shared.endBackgroundTask(bgID)
            }
        }
    }

    func setCustomResponse(translatedNative: String, languageCode: String) {
        task?.cancel()

        let trimmed = translatedNative.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            suggestionPhonetic = ""
            suggestionEnglish = ""
            suggestionNative = ""
            inFlightSource = nil
            isGenerating = false
            generationStage = ""
            return
        }

        // `translatedNative` is target-language text the user typed; we don't
        // have an English meaning for it (would need a separate translate call).
        suggestionNative = trimmed
        suggestionEnglish = ""
        suggestionPhonetic = ""
        inFlightSource = (trimmed, languageCode)

        let bgID = UIApplication.shared.beginBackgroundTask(withName: "hudini.phonetic")

        task = Task { [weak self] in
            await self?.generatePhoneticOnly(for: trimmed, languageCode: languageCode)
            if bgID != .invalid {
                UIApplication.shared.endBackgroundTask(bgID)
            }
        }
    }

    func clearSuggestion() {
        task?.cancel()
        suggestionPhonetic = ""
        suggestionEnglish = ""
        suggestionNative = ""
        inFlightSource = nil
        isGenerating = false
        generationStage = ""
    }

    deinit {
        task?.cancel()
    }

    private func generateSuggestion(for text: String, languageCode: String) async {
        defer {
            if let current = inFlightSource,
               current.text == text,
               current.language == languageCode {
                inFlightSource = nil
            }
            isGenerating = false
            generationStage = ""
        }

        guard !Task.isCancelled else { return }

        isGenerating = true
        generationStage = "Thinking…"

        do {
            let reply = try await service.generateReply(
                for: text,
                languageCode: languageCode,
                profile: profileSnapshot()
            )
            guard !Task.isCancelled else { return }
            suggestionNative = reply.native
            suggestionEnglish = reply.english
            suggestionPhonetic = reply.phonetic
            print("[Suggestion] success: native=\(reply.native) phonetic=\(reply.phonetic) english=\(reply.english)")
        } catch {
            guard !Task.isCancelled else { return }
            print("[Suggestion] error: \(error)")
            suggestionNative = ""
            suggestionEnglish = ""
            suggestionPhonetic = "Error: \(error.localizedDescription)"
        }
    }

    private func generatePhoneticOnly(for text: String, languageCode: String) async {
        defer {
            if let current = inFlightSource,
               current.text == text,
               current.language == languageCode {
                inFlightSource = nil
            }
            isGenerating = false
            generationStage = ""
        }

        guard !Task.isCancelled else { return }

        isGenerating = true
        generationStage = "Phonetic…"

        do {
            let phonetic = try await service.generatePhonetic(for: text, languageCode: languageCode)
            guard !Task.isCancelled else { return }
            suggestionPhonetic = phonetic.phonetic
            print("[Suggestion] custom phonetic: \(phonetic.phonetic)")
        } catch {
            guard !Task.isCancelled else { return }
            print("[Suggestion] custom phonetic error: \(error)")
            suggestionPhonetic = "Phonetic unavailable"
        }
    }
}
