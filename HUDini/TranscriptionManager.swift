import Foundation
import Combine

@MainActor
final class TranscriptionManager: ObservableObject {
    @Published var transcript: String = ""
    @Published var isTranscribing: Bool = false
    @Published var statusMessage: String = ""

    private let service: HUDTranscriptionService

    init(service: HUDTranscriptionService? = nil) {
        if let service {
            self.service = service
        } else {
            self.service = HUDTranscriptionService()
        }
    }

    func requestPermissions() async {
        let permissions = await service.requestPermissions()
        statusMessage = permissions.issuesDescription
    }

    func start() {
        guard !isTranscribing else { return }
        let started = service.start { [weak self] update in
            guard let self else { return }
            self.transcript = update.text
            if update.isFinal {
                self.statusMessage = "Finalized segment"
            }
        } onError: { [weak self] error in
            guard let self else { return }
            self.statusMessage = "Recognition error: \(error.localizedDescription)"
            self.stop()
        }

        isTranscribing = started
        if started {
            statusMessage = "Listening…"
        } else if statusMessage.isEmpty {
            statusMessage = "Speech recognizer unavailable"
        }
    }

    func stop() {
        guard isTranscribing else { return }
        service.stop()
        isTranscribing = false
    }

    func resetTranscript() {
        transcript = ""
        statusMessage = ""
    }

    func setListeningLanguage(_ code: String) {
        do {
            let normalized = try service.setListeningLanguage(code)
            if isTranscribing {
                statusMessage = "Language updated — restart listening."
            } else {
                statusMessage = "Listening language set to \(TranslationLanguages.displayName(for: normalized))."
            }
        } catch {
            statusMessage = error.localizedDescription
        }
    }
}
