import Foundation
import Combine

@MainActor
final class TranscriptionManager: ObservableObject {
    @Published var transcript: String = ""
    @Published var renderedText: String = ""
    @Published var isTranscribing: Bool = false
    @Published var statusMessage: String = ""
    @Published var listeningLanguageCode: String
    @Published var targetLanguageCode: String

    private let pipeline: HUDTranscriptionTranslationPipeline

    init(pipeline: HUDTranscriptionTranslationPipeline? = nil) {
        self.listeningLanguageCode = Self.defaultListeningLanguageCode
        self.targetLanguageCode = "en"

        if let pipeline {
            self.pipeline = pipeline
        } else {
            self.pipeline = HUDTranscriptionTranslationPipeline()
        }
    }

    func requestPermissions() async {
        let permissions = await pipeline.requestPermissions()
        statusMessage = permissions.issuesDescription
    }

    func start() {
        startTranscribing(listeningLanguage: listeningLanguageCode, translatingTo: targetLanguageCode)
    }

    func startTranscribing(listeningLanguage: String, translatingTo targetLanguage: String) {
        guard !isTranscribing else { return }
        listeningLanguageCode = listeningLanguage
        targetLanguageCode = targetLanguage

        let started = pipeline.start(
            listeningLanguageCode: listeningLanguage,
            targetLanguageCode: targetLanguage
        ) { [weak self] update in
            guard let self else { return }
            self.transcript = update.transcript
            self.renderedText = update.renderedText
            if update.isFinal {
                self.statusMessage = "Finalized segment"
            }
        } onError: { [weak self] pipelineError in
            guard let self else { return }
            switch pipelineError {
            case .transcription(let error):
                self.statusMessage = "Recognition error: \(error.localizedDescription)"
                self.stop()
            case .translation(let error):
                self.statusMessage = "Translation error: \(error.localizedDescription)"
            }
        }

        isTranscribing = started
        if started {
            if shouldBypassTranslation {
                statusMessage = "Listening… (translation skipped)"
            } else {
                statusMessage = "Listening and translating…"
            }
        } else if statusMessage.isEmpty {
            statusMessage = "Speech recognizer unavailable"
        }
    }

    func stop() {
        guard isTranscribing else { return }
        pipeline.stop()
        isTranscribing = false
    }

    func resetTranscript() {
        transcript = ""
        renderedText = ""
        statusMessage = ""
    }

    func setListeningLanguage(_ code: String) {
        guard TranslationLanguages.supported.contains(where: { $0.code == code }) else {
            statusMessage = "Unsupported listening language: \(code)"
            return
        }

        listeningLanguageCode = code
        if isTranscribing {
            statusMessage = "Listening language updated — restart to apply."
        } else {
            statusMessage = "Listening language set to \(TranslationLanguages.displayName(for: code))."
        }
    }

    func setTargetLanguage(_ code: String) {
        guard TranslationLanguages.targetOptions.contains(where: { $0.code == code }) else {
            statusMessage = "Unsupported target language: \(code)"
            return
        }

        targetLanguageCode = code
        if isTranscribing {
            statusMessage = "Target language updated — restart to apply."
        } else {
            statusMessage = "Target language set to \(TranslationLanguages.displayName(for: code))."
        }
    }

    private var shouldBypassTranslation: Bool {
        normalizedLanguageCode(listeningLanguageCode) == normalizedLanguageCode(targetLanguageCode)
    }

    private func normalizedLanguageCode(_ code: String) -> String {
        let lowered = code.lowercased()
        if let dash = lowered.firstIndex(of: "-") {
            return String(lowered[..<dash])
        }
        if let underscore = lowered.firstIndex(of: "_") {
            return String(lowered[..<underscore])
        }
        return lowered
    }
}

private extension TranscriptionManager {
    static var defaultListeningLanguageCode: String {
        if #available(iOS 16.0, *) {
            if let current = Locale.current.language.languageCode?.identifier,
               TranslationLanguages.supported.contains(where: { $0.code == current }) {
                return current
            }
        }

        let identifier = Locale.current.identifier
        if let prefix = identifier.split(separator: "_").first,
           TranslationLanguages.supported.contains(where: { $0.code == String(prefix) }) {
            return String(prefix)
        }

        return "en"
    }
}
