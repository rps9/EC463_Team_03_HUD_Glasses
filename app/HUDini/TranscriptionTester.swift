import Foundation
import SwiftUI
import Combine
import AVFoundation
import AVFAudio
import Speech

struct TestMetrics {
    let recognized: String
    let accuracy: Double          // 0...1
    let finalizeDelayMS: Double   // time from Stop-press to final transcript
}

@MainActor
final class TranscriptionTester: ObservableObject {
    // UI state
    @Published var targetSentence: String = ""
    @Published var liveTranscript: String = ""
    @Published var status: String = ""
    @Published var isRunning: Bool = false          // a test session is active
    @Published var micStopped: Bool = false         // user pressed Stop (audio snipped)

    // Last run + session stats
    @Published var lastMetrics: TestMetrics?
    @Published var runs: Int = 0
    @Published var avgAccuracy: Double = 0
    @Published var avgDelayMS: Double = 0

    // Speech/audio
    private let audioEngine = AVAudioEngine()
    private let audioSession = AVAudioSession.sharedInstance()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let recognizer = SFSpeechRecognizer(locale: Locale.current)

    // Timing
    private var stopPressedAt: Date?
    private var finalResultAt: Date?
    private var finalizeFallbackTask: Task<Void, Never>?

    // Tunables
    private let finalizeFallbackSeconds: Double = 3.0 // demo-friendly: if no "final" by then, use last partial

    // MARK: Permissions

    func requestPermissions() async -> Bool {
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
        return speechAuth == .authorized && micGranted
    }

    // MARK: Control

    func pickRandomSentence(from pool: [String]) {
        guard !pool.isEmpty else { return }
        targetSentence = pool.randomElement()!
        liveTranscript = ""
        lastMetrics = nil
        status = "Ready"
    }

    func start() {
        guard !isRunning else { return }
        guard let recognizer, recognizer.isAvailable else { status = "Recognizer unavailable"; return }
        guard !targetSentence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { status = "Pick a sentence first"; return }

        // Reset run state
        isRunning = true
        micStopped = false
        liveTranscript = ""
        lastMetrics = nil
        stopPressedAt = nil
        finalResultAt = nil
        cancelFallback()

        // Configure audio
        do {
            try audioSession.setCategory(.record, mode: .measurement, options: [.duckOthers])
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            status = "Audio session: \(error.localizedDescription)"
            isRunning = false
            return
        }

        // Request + engine
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        // request.requiresOnDeviceRecognition = true // toggle if you want local-only where supported
        recognitionRequest = request

        let input = audioEngine.inputNode
        let fmt = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: fmt) { [weak self] buf, _ in
            self?.recognitionRequest?.append(buf)
        }

        do {
            audioEngine.prepare()
            try audioEngine.start()
        } catch {
            status = "Audio engine: \(error.localizedDescription)"
            cleanupAudioOnly()
            isRunning = false
            return
        }

        status = "Listening…"

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }

            if let result {
                self.liveTranscript = result.bestTranscription.formattedString

                if result.isFinal {
                    // Final transcript arrived. If user pressed Stop earlier, measure delay.
                    self.finalResultAt = Date()
                    self.finalize(usedFallback: false)
                }
            }

            if let error {
                // If we already pressed Stop, try to finalize with what we have; else bail.
                self.status = "Error: \(error.localizedDescription)"
                if self.micStopped {
                    self.finalize(usedFallback: true)
                } else {
                    self.abortNow()
                }
            }
        }
    }

    /// User taps Stop: snip mic, let recognition continue to a final result.
    func stopMicOnly() {
        guard isRunning, !micStopped else { return }
        micStopped = true
        stopPressedAt = Date()

        // Stop feeding audio, but DO NOT cancel the recognition task.
        recognitionRequest?.endAudio()
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        status = "Finalizing…"

        // Demo safety net: if no final result within N seconds, finalize with last partial.
        cancelFallback()
        finalizeFallbackTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(finalizeFallbackSeconds * 1_000_000_000))
            if self.isRunning, self.finalResultAt == nil {
                self.finalize(usedFallback: true)
            }
        }
    }

    /// Emergency abort if something goes sideways before Stop.
    func abortNow() {
        recognitionTask?.cancel()
        cleanup()
        status = "Aborted"
    }

    /// Reset aggregate stats for the session (not persistent).
    func resetStats() {
        runs = 0
        avgAccuracy = 0
        avgDelayMS = 0
        status = "Cleared stats"
    }

    // MARK: Internals

    private func finalize(usedFallback: Bool) {
        guard isRunning else { return }
        // If we never recorded final time, set it now (fallback path).
        if finalResultAt == nil { finalResultAt = Date() }

        // Compute accuracy (1 - WER) vs target
        let acc = 1.0 - wordErrorRate(ref: targetSentence, hyp: liveTranscript)

        // Compute delay from user Stop to final transcript
        let delayMS: Double = {
            guard let stop = stopPressedAt, let fin = finalResultAt else { return .nan }
            return max(0, fin.timeIntervalSince(stop) * 1000.0)
        }()

        let metrics = TestMetrics(
            recognized: liveTranscript,
            accuracy: max(0, min(1, acc)),
            finalizeDelayMS: delayMS
        )
        lastMetrics = metrics

        // Running averages
        runs += 1
        avgAccuracy = ((avgAccuracy * Double(runs - 1)) + metrics.accuracy) / Double(runs)
        avgDelayMS  = ((avgDelayMS  * Double(runs - 1)) + metrics.finalizeDelayMS) / Double(runs)

        // Clean up
        cleanup()
        status = usedFallback ? "Finalized (fallback)" : "Finalized"
    }

    private func cleanup() {
        cancelFallback()
        recognitionTask = nil
        recognitionRequest = nil
        isRunning = false
        micStopped = false
        stopPressedAt = nil
        finalResultAt = nil
        do { try audioSession.setActive(false, options: .notifyOthersOnDeactivation) } catch { }
    }

    private func cleanupAudioOnly() {
        recognitionRequest = nil
        do { try audioSession.setActive(false, options: .notifyOthersOnDeactivation) } catch { }
    }

    private func cancelFallback() {
        finalizeFallbackTask?.cancel()
        finalizeFallbackTask = nil
    }

    // MARK: Metrics helpers

    // Word Error Rate (WER): Levenshtein distance on word tokens
    private func wordErrorRate(ref: String, hyp: String) -> Double {
        let r = tokenize(ref)
        let h = tokenize(hyp)
        if r.isEmpty { return h.isEmpty ? 0 : 1 }

        let n = r.count, m = h.count
        var dp = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in 0...n { dp[i][0] = i }
        for j in 0...m { dp[0][j] = j }
        for i in 1...n {
            for j in 1...m {
                let cost = (r[i-1] == h[j-1]) ? 0 : 1
                dp[i][j] = min(
                    dp[i-1][j] + 1,       // deletion
                    dp[i][j-1] + 1,       // insertion
                    dp[i-1][j-1] + cost   // substitution
                )
            }
        }
        return Double(dp[n][m]) / Double(n)
    }

    private func tokenize(_ s: String) -> [String] {
        // Lowercase, strip punctuation, split on whitespace
        let lowered = s.lowercased()
        let cleaned = lowered.replacingOccurrences(of: "[^a-z0-9\\s]", with: " ", options: .regularExpression)
        return cleaned.split(whereSeparator: \.isWhitespace).map(String.init)
    }
}
