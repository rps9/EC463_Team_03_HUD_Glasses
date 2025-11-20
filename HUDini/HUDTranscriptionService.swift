import Foundation
import AVFoundation
import AVFAudio
import Speech

@MainActor
final class HUDTranscriptionService {
    struct PermissionsStatus {
        let speechStatus: SFSpeechRecognizerAuthorizationStatus
        let microphoneGranted: Bool

        var issuesDescription: String {
            var issues: [String] = []
            switch speechStatus {
            case .authorized: break
            case .denied: issues.append("Speech: denied")
            case .restricted: issues.append("Speech: restricted")
            case .notDetermined: issues.append("Speech: not determined")
            @unknown default: issues.append("Speech: unknown")
            }
            if !microphoneGranted { issues.append("Microphone: denied") }
            return issues.isEmpty ? "Permissions OK" : issues.joined(separator: " · ")
        }
    }

    struct Update {
        let text: String
        let isFinal: Bool
    }

    private let audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var recognizer: SFSpeechRecognizer?
    private let audioSession = AVAudioSession.sharedInstance()
    private let audioBufferSize: AVAudioFrameCount = 512
    private(set) var localeIdentifier: String
    private(set) var isTranscribing: Bool = false

    init(localeIdentifier: String = Locale.current.identifier) {
        self.localeIdentifier = localeIdentifier
        self.recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier))
    }

    func requestPermissions() async -> PermissionsStatus {
        let speechAuth = await withCheckedContinuation { (c: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) }
        }

        let micGranted: Bool
        if #available(iOS 17.0, *) {
            micGranted = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
                AVAudioApplication.requestRecordPermission { c.resume(returning: $0) }
            }
        } else {
            micGranted = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
                audioSession.requestRecordPermission { c.resume(returning: $0) }
            }
        }

        return PermissionsStatus(speechStatus: speechAuth, microphoneGranted: micGranted)
    }

    @discardableResult
    func start(onResult: @escaping (Update) -> Void, onError: ((Error) -> Void)? = nil) -> Bool {
        guard !isTranscribing else { return true }
        guard let recognizer, recognizer.isAvailable else {
            onError?(HUDTranscriptionError.recognizerUnavailable)
            return false
        }

        recognitionTask?.cancel()
        recognitionTask = nil

        do {
            try audioSession.setCategory(.record, mode: .measurement, options: [.duckOthers])
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            onError?(error)
            return false
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        recognitionRequest = request

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: audioBufferSize, format: format) { [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)
        }

        do {
            audioEngine.prepare()
            try audioEngine.start()
        } catch {
            onError?(error)
            cleanupAudioOnly()
            return false
        }

        isTranscribing = true

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }

            if let result {
                let update = Update(text: result.bestTranscription.formattedString, isFinal: result.isFinal)
                onResult(update)
            }

            if let error {
                onError?(error)
                self.stop()
            }
        }
        return true
    }

    func stop() {
        guard isTranscribing else { return }
        recognitionRequest?.endAudio()
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionTask?.cancel()
        cleanup()
    }

    @discardableResult
    func setListeningLanguage(_ code: String) throws -> String {
        guard code != localeIdentifier else { return localeIdentifier }

        let normalized = code.isEmpty ? Locale.current.identifier : code
        guard let newRecognizer = SFSpeechRecognizer(locale: Locale(identifier: normalized)) else {
            throw HUDTranscriptionError.unsupportedLanguage(code)
        }

        localeIdentifier = normalized
        recognizer = newRecognizer
        return normalized
    }

    private func cleanup() {
        recognitionTask = nil
        recognitionRequest = nil
        isTranscribing = false
        do {
            try audioSession.setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            // swallow
        }
    }

    private func cleanupAudioOnly() {
        recognitionRequest = nil
        do {
            try audioSession.setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            // swallow
        }
    }
}

enum HUDTranscriptionError: LocalizedError {
    case recognizerUnavailable
    case unsupportedLanguage(String)

    var errorDescription: String? {
        switch self {
        case .recognizerUnavailable:
            return "Speech recognizer unavailable"
        case .unsupportedLanguage(let code):
            return "Speech not supported for \(code.uppercased())"
        }
    }
}
