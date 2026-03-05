import Foundation

@MainActor
final class HUDTranscriptionTranslationPipeline {
    struct Output {
        let transcript: String
        let renderedText: String
        let isFinal: Bool
        let wasTranslated: Bool
    }

    enum PipelineError: LocalizedError {
        case transcription(Error)
        case translation(Error)

        var errorDescription: String? {
            switch self {
            case .transcription(let error), .translation(let error):
                if let localized = error as? LocalizedError, let description = localized.errorDescription {
                    return description
                }
                return error.localizedDescription
            }
        }
    }

    private let transcriptionService: HUDTranscriptionService
    private let translationClient: HUDTranslationClient
    private var translationTask: Task<Void, Never>?
    private var latestRequestID = UUID()

    init(
        transcriptionService: HUDTranscriptionService? = nil,
        translationClient: HUDTranslationClient? = nil
    ) {
        if let transcriptionService {
            self.transcriptionService = transcriptionService
        } else {
            self.transcriptionService = HUDTranscriptionService()
        }

        if let translationClient {
            self.translationClient = translationClient
        } else {
            self.translationClient = HUDTranslationClient()
        }
    }

    func requestPermissions() async -> HUDTranscriptionService.PermissionsStatus {
        await transcriptionService.requestPermissions()
    }

    @discardableResult
    func start(
        listeningLanguageCode: String,
        targetLanguageCode: String,
        onUpdate: @escaping (Output) -> Void,
        onError: ((PipelineError) -> Void)? = nil
    ) -> Bool {
        do {
            _ = try transcriptionService.setListeningLanguage(listeningLanguageCode)
        } catch {
            onError?(.transcription(error))
            return false
        }

        let started = transcriptionService.start { [weak self] update in
            guard let self else { return }
            self.handleUpdate(
                update,
                listeningLanguageCode: listeningLanguageCode,
                targetLanguageCode: targetLanguageCode,
                onUpdate: onUpdate,
                onError: onError
            )
        } onError: { [weak self] error in
            self?.cancelTranslation()
            onError?(.transcription(error))
        }

        if !started {
            cancelTranslation()
        }
        return started
    }

    func stop() {
        transcriptionService.stop()
        cancelTranslation()
    }

    private func handleUpdate(
        _ update: HUDTranscriptionService.Update,
        listeningLanguageCode: String,
        targetLanguageCode: String,
        onUpdate: @escaping (Output) -> Void,
        onError: ((PipelineError) -> Void)? = nil
    ) {
        let transcript = update.text
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            onUpdate(Output(transcript: transcript, renderedText: "", isFinal: update.isFinal, wasTranslated: false))
            return
        }

        if shouldBypassTranslation(source: listeningLanguageCode, target: targetLanguageCode) {
            onUpdate(Output(transcript: transcript, renderedText: transcript, isFinal: update.isFinal, wasTranslated: false))
            return
        }

        let requestID = UUID()
        latestRequestID = requestID
        translationTask?.cancel()
        translationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let translated = try await translationClient.translate(
                    text: trimmed,
                    source: listeningLanguageCode,
                    target: targetLanguageCode
                )
                guard !Task.isCancelled else { return }
                guard self.latestRequestID == requestID else { return }
                onUpdate(Output(transcript: transcript, renderedText: translated, isFinal: update.isFinal, wasTranslated: true))
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                guard self.latestRequestID == requestID else { return }
                onError?(.translation(error))
            }
        }
    }

    private func cancelTranslation() {
        latestRequestID = UUID()
        translationTask?.cancel()
        translationTask = nil
    }

    private func shouldBypassTranslation(source: String, target: String) -> Bool {
        normalizedLanguageCode(source) == normalizedLanguageCode(target)
    }

    private func normalizedLanguageCode(_ code: String) -> String {
        let cleaned = code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !cleaned.isEmpty else { return cleaned }

        if let firstDash = cleaned.firstIndex(of: "-") {
            return String(cleaned[..<firstDash])
        }

        if let firstUnderscore = cleaned.firstIndex(of: "_") {
            return String(cleaned[..<firstUnderscore])
        }

        return cleaned
    }
}
