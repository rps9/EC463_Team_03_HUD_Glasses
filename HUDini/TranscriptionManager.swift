import Foundation
import AVFoundation
import AVFAudio
import Speech
import Combine

@MainActor
final class TranscriptionManager: ObservableObject {
    @Published var transcript: String = ""
    @Published var isTranscribing: Bool = false
    @Published var statusMessage: String = ""

    private let audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let recognizer = SFSpeechRecognizer(locale: Locale.current)
    private let audioSession = AVAudioSession.sharedInstance()

    // MARK: - Permissions

    func requestPermissions() async {
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

        var issues: [String] = []
        switch speechAuth {
        case .authorized: break
        case .denied: issues.append("Speech: denied")
        case .restricted: issues.append("Speech: restricted")
        case .notDetermined: issues.append("Speech: not determined")
        @unknown default: issues.append("Speech: unknown")
        }
        if !micGranted { issues.append("Microphone: denied") }

        statusMessage = issues.isEmpty ? "Permissions OK" : issues.joined(separator: " · ")
    }

    // MARK: - Control

    func start() {
        guard !isTranscribing else { return }
        guard let recognizer, recognizer.isAvailable else {
            statusMessage = "Speech recognizer unavailable"
            return
        }

        // End any prior session
        recognitionTask?.cancel()
        recognitionTask = nil

        // Configure audio
        do {
            try audioSession.setCategory(.record,
                                         mode: .measurement,
                                         options: [.duckOthers]) // no BT flags needed
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            statusMessage = "Audio session error: \(error.localizedDescription)"
            return
        }

        // Build request
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        // request.requiresOnDeviceRecognition = true // enable if you want on-device where available
        recognitionRequest = request

        // Wire mic to request
        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            self?.recognitionRequest?.append(buffer)
        }

        // Start engine
        do {
            audioEngine.prepare()
            try audioEngine.start()
        } catch {
            statusMessage = "Audio engine error: \(error.localizedDescription)"
            cleanupAudioOnly()
            return
        }

        isTranscribing = true
        statusMessage = "Listening…"

        // Start recognition
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }

            if let result {
                // Update live text; stop does NOT clear this.
                self.transcript = result.bestTranscription.formattedString

                // Continuous mode: do not auto-stop on final segments.
                if result.isFinal {
                    self.statusMessage = "Finalized segment"
                }
            }

            if let error {
                self.statusMessage = "Recognition error: \(error.localizedDescription)"
                // Clean up but keep whatever transcript we had.
                self.stop()
            }
        }
    }

    func stop() {
        guard isTranscribing else { return }

        // Gracefully end audio into the request
        recognitionRequest?.endAudio()

        // Stop engine and tear down tap
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)

        // Cancel the task to end promptly (does not touch transcript)
        recognitionTask?.cancel()

        cleanup()
    }

    func resetTranscript() {
        transcript = ""
        statusMessage = ""
    }

    // MARK: - Internals

    private func cleanup() {
        recognitionTask = nil
        recognitionRequest = nil
        isTranscribing = false
        do {
            try audioSession.setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            // non-fatal
        }
    }

    private func cleanupAudioOnly() {
        recognitionRequest = nil
        do {
            try audioSession.setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            // non-fatal
        }
    }
}
