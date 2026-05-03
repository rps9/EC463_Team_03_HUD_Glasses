import Foundation
import Combine
import CoreBluetooth
import AVFoundation
import Speech
import SwiftUI

@MainActor
final class ESP32BluetoothManager: NSObject, ObservableObject {
    struct DevLogEntry: Identifiable {
        let id = UUID()
        let timestamp: Date
        let direction: String   // APP / OUT / IN / AUDIO / TIMING / TEST
        let message: String
    }

    private static let service = CBUUID(string: "9A1D0001-7E54-4B1A-8B64-3A8F2C1D0001")
    private static let audioDataCharacteristic = CBUUID(string: "9A1D0002-7E54-4B1A-8B64-3A8F2C1D0001")
    private static let controlCharacteristic = CBUUID(string: "9A1D0003-7E54-4B1A-8B64-3A8F2C1D0001")
    private static let statusCharacteristic = CBUUID(string: "9A1D0004-7E54-4B1A-8B64-3A8F2C1D0001")

    private static let streamSampleRate: Double = 8_000
    // Firmware MTU is 185 bytes. Leave headroom for the verb prefix and BLE
    // framing overhead, then round to a safe payload size.
    private static let singleShotCommandLimit = 170
    private static let chunkPayloadSize = 150
    private static let centralRestoreIdentifier = "com.hudini.esp32.central"
    // Cap log so we don't blow memory in long admin sessions.
    private static let maxDevLogEntries = 2_000

    @Published private(set) var state: FrameBluetoothManager.ConnectionState = .idle {
        didSet {
            guard oldValue != state else { return }
            appendDevLog(direction: "APP", message: "state \(String(describing: oldValue)) -> \(String(describing: state))")
        }
    }
    @Published private(set) var discoveredDevices: [FrameBluetoothManager.DiscoveredDevice] = []
    @Published private(set) var statusMessage: String = "Checking Bluetooth…" {
        didSet {
            guard oldValue != statusMessage else { return }
            appendDevLog(direction: "APP", message: "statusMessage = \(statusMessage)")
        }
    }
    @Published private(set) var liveTranscript: String = "" {
        didSet {
            guard oldValue != liveTranscript else { return }
            appendDevLog(direction: "APP", message: "liveTranscript = \(liveTranscript)")
        }
    }
    @Published private(set) var renderedText: String = "" {
        didSet {
            guard oldValue != renderedText else { return }
            appendDevLog(direction: "APP", message: "renderedText = \(renderedText)")
        }
    }
    @Published private(set) var isStreaming: Bool = false {
        didSet {
            guard oldValue != isStreaming else { return }
            appendDevLog(direction: "APP", message: "isStreaming = \(isStreaming)")
        }
    }
    @Published private(set) var selectedLanguageCode: String = TranslationLanguages.defaultListeningLanguageCode {
        didSet {
            guard oldValue != selectedLanguageCode else { return }
            appendDevLog(direction: "APP", message: "selectedLanguageCode = \(selectedLanguageCode)")
        }
    }
    @Published private(set) var targetLanguageCode: String = "en" {
        didSet {
            guard oldValue != targetLanguageCode else { return }
            appendDevLog(direction: "APP", message: "targetLanguageCode = \(targetLanguageCode)")
        }
    }
    @Published private(set) var devLogEntries: [DevLogEntry] = []

    private var central: CBCentralManager!
    private var connectedPeripheral: CBPeripheral?
    private var audioDataChar: CBCharacteristic?
    private var controlChar: CBCharacteristic?
    private var statusChar: CBCharacteristic?
    private var shouldScanWhenReady = false

    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var recognizer: SFSpeechRecognizer?

    private let translationClient = HUDTranslationClient()
    private var translationTask: Task<Void, Never>?
    private var latestTranslationRequestID = UUID()
    private var lastPartialTranslationAt: Date = .distantPast
    private let partialTranslationInterval: TimeInterval = 0.10
    private var latestTranscriptSnapshot: String = ""
    private var lastPartialTranslationText: String = ""
    private var lastSentCaptionFinal: String = ""
    private var lastSentCaptionPartial: String = ""
    private var lastSentSuggestionPhonetic: String = ""
    private var lastSentSuggestionEnglish: String = ""
    // Firmware sends "MIC_REQUEST:<seq>" with retries for delivery
    // robustness; we dedupe by seq so a single press toggles exactly once.
    private var lastButtonSeq: UInt16 = 0

    // Audio diagnostics — accumulated per packet, emitted as one [AUDIO]
    // log line every `audioStatsLogInterval` packets so the log stays
    // readable even at ~138 packets/sec.
    private static let audioStatsLogInterval = 256
    private var audioPacketCount: Int = 0
    private var audioBytesAccum: Int = 0
    private var audioPeakAbs: Int32 = 0
    private var audioSumAbs: Int64 = 0
    private var audioSampleCount: Int = 0
    private var audioSilentWindows: Int = 0
    private var audioWindowsSinceLog: Int = 0
    private var audioLastSeq: UInt16 = 0
    private var audioSeqGapCount: Int = 0
    private var lastAudioPacketAt: Date = .distantPast
    private var lastRecognitionResultAt: Date = .distantPast

    private lazy var streamFormat: AVAudioFormat = {
        AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Self.streamSampleRate,
            channels: 1,
            interleaved: false
        )!
    }()

    override init() {
        super.init()
        selectedLanguageCode = TranslationLanguages.preferredListeningLanguageCode()
        recognizer = SFSpeechRecognizer(locale: Locale(identifier: selectedLanguageCode))
        central = CBCentralManager(
            delegate: self,
            queue: nil,
            options: [CBCentralManagerOptionRestoreIdentifierKey: Self.centralRestoreIdentifier]
        )
        appendDevLog(direction: "APP", message: "ESP32BluetoothManager init streamSampleRate=\(Self.streamSampleRate)")
    }

    // MARK: - Dev log

    func clearDevLog() {
        devLogEntries = []
    }

    private func appendDevLog(direction: String, message: String) {
        let normalized = message
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
        devLogEntries.append(DevLogEntry(timestamp: Date(), direction: direction, message: normalized))
        if devLogEntries.count > Self.maxDevLogEntries {
            devLogEntries.removeFirst(devLogEntries.count - Self.maxDevLogEntries)
        }
    }

    private func logDecision(_ message: String) {
        appendDevLog(direction: "APP", message: message)
    }

    // MARK: - Scanning / Connection

    func beginScanning() {
        guard central.state == .poweredOn else {
            shouldScanWhenReady = true
            statusMessage = "Waiting for Bluetooth…"
            return
        }
        startScan()
    }

    func stopScanning() {
        central.stopScan()
        if case .scanning = state { state = .idle }
    }

    func connect(to device: FrameBluetoothManager.DiscoveredDevice) {
        stopScanning()
        state = .connecting(device.name)
        statusMessage = "Connecting to \(device.name)…"
        central.connect(device.peripheral, options: nil)
    }

    func disconnect() {
        stopListening()
        guard let peripheral = connectedPeripheral else {
            resetConnectionState(message: "Disconnected")
            return
        }
        central.cancelPeripheralConnection(peripheral)
    }

    private func startScan() {
        shouldScanWhenReady = false
        discoveredDevices = []
        central.scanForPeripherals(
            withServices: [Self.service],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
        state = .scanning
        statusMessage = "Scanning for ESP32…"
    }

    private func resetConnectionState(message: String) {
        controlChar = nil
        audioDataChar = nil
        statusChar = nil
        connectedPeripheral = nil
        discoveredDevices = []
        state = .idle
        statusMessage = message
        stopRecognition()
        isStreaming = false
    }

    // MARK: - Transcription

    func startTranscribing(listeningLanguage: String, translatingTo targetLanguage: String) {
        setRecognitionLanguage(listeningLanguage)
        setTargetLanguage(targetLanguage)
        guard connectedPeripheral != nil, let controlChar else {
            statusMessage = "Connect to ESP32 first"
            return
        }
        // Flip immediately so a rapid second button press during the await
        // below sees isStreaming=true and routes through stopListening
        // instead of double-starting the recognizer.
        isStreaming = true
        Task { @MainActor in
            let auth = await requestSpeechAuthorization()
            guard auth == .authorized else {
                isStreaming = false
                statusMessage = "Allow Speech Recognition in Settings"
                return
            }
            guard startRecognition() else {
                isStreaming = false
                return
            }
            writeControl("START", char: controlChar)
            statusMessage = "Streaming and transcribing…"
        }
    }

    func stopListening() {
        if let controlChar {
            writeControl("STOP", char: controlChar)
        } else {
            logDecision("stopListening called but no controlChar")
        }
        stopRecognition()
        isStreaming = false
    }

    private func toggleListeningFromPeripheralButton() {
        if isStreaming {
            stopListening()
        } else {
            startTranscribing(listeningLanguage: selectedLanguageCode, translatingTo: targetLanguageCode)
        }
    }

    func setRecognitionLanguage(_ code: String) {
        guard !code.isEmpty, code != selectedLanguageCode else { return }
        selectedLanguageCode = code
        recognizer = SFSpeechRecognizer(locale: Locale(identifier: code))
    }

    func setTargetLanguage(_ code: String) {
        guard !code.isEmpty, code != targetLanguageCode else { return }
        targetLanguageCode = code
    }

    private func startRecognition() -> Bool {
        resetAudioStats(reason: "startRecognition")
        logDecision("startRecognition invoked locale=\(selectedLanguageCode)")
        guard let recognizer, recognizer.isAvailable else {
            statusMessage = "Speech recognizer unavailable"
            logDecision("startRecognition failed — recognizer unavailable")
            return false
        }
        recognitionTask?.cancel()
        recognitionTask = nil

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        recognitionRequest = request
        logDecision("recognitionRequest created shouldReportPartialResults=true taskHint=dictation")

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            Task { @MainActor in
                if let result {
                    let transcript = result.bestTranscription.formattedString
                    let now = Date()
                    let sinceLastResult = now.timeIntervalSince(self.lastRecognitionResultAt)
                    let sinceLastAudio = now.timeIntervalSince(self.lastAudioPacketAt)
                    self.lastRecognitionResultAt = now
                    let preview = transcript.count > 80 ? String(transcript.prefix(80)) + "…" : transcript
                    self.appendDevLog(
                        direction: "TIMING",
                        message: "result isFinal=\(result.isFinal) sinceLastResult=\(Int(sinceLastResult * 1000))ms sinceLastAudio=\(Int(sinceLastAudio * 1000))ms pkts=\(self.audioPacketCount) transcript=\(preview)"
                    )
                    if !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        self.liveTranscript = transcript
                        self.handleTranscriptUpdate(text: transcript, isFinal: result.isFinal)
                    } else {
                        self.logDecision("recognitionTask ignored empty transcript result")
                    }
                }
                if let error {
                    self.logDecision("recognitionTask error: \(error.localizedDescription)")
                    if self.isStreaming {
                        self.statusMessage = "Recognition ended: \(error.localizedDescription)"
                    }
                }
            }
        }
        return true
    }

    private func stopRecognition() {
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        cancelTranslation()
    }

    private func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    // MARK: - Translation

    private func handleTranscriptUpdate(text: String, isFinal: Bool) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        latestTranscriptSnapshot = trimmed

        if shouldBypassTranslation(source: selectedLanguageCode, target: targetLanguageCode) {
            renderedText = trimmed
            sendHUDText(trimmed, isPartial: !isFinal)
            return
        }

        if !isFinal {
            guard trimmed.count >= 2, trimmed != lastPartialTranslationText else { return }
            let now = Date()
            guard now.timeIntervalSince(lastPartialTranslationAt) >= partialTranslationInterval else { return }
            lastPartialTranslationAt = now
            lastPartialTranslationText = trimmed
        } else {
            lastPartialTranslationText = trimmed
        }

        let requestID = UUID()
        latestTranslationRequestID = requestID
        let snapshot = trimmed
        translationTask?.cancel()
        translationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let translated = try await translationClient.translate(
                    text: snapshot,
                    source: selectedLanguageCode,
                    target: targetLanguageCode
                )
                guard !Task.isCancelled,
                      latestTranslationRequestID == requestID else { return }
                if !isFinal, latestTranscriptSnapshot != snapshot { return }
                renderedText = translated
                sendHUDText(translated, isPartial: !isFinal)
            } catch {
                return
            }
        }
    }

    private func cancelTranslation() {
        latestTranslationRequestID = UUID()
        translationTask?.cancel()
        translationTask = nil
        lastPartialTranslationText = ""
    }

    private func shouldBypassTranslation(source: String, target: String) -> Bool {
        normalizedLanguageCode(source) == normalizedLanguageCode(target)
    }

    private func normalizedLanguageCode(_ code: String) -> String {
        let cleaned = code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !cleaned.isEmpty else { return cleaned }
        if let dash = cleaned.firstIndex(of: "-") { return String(cleaned[..<dash]) }
        if let under = cleaned.firstIndex(of: "_") { return String(cleaned[..<under]) }
        return cleaned
    }

    // MARK: - Display writes

    func sendHUDText(_ text: String, isPartial: Bool) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if isPartial {
            guard trimmed != lastSentCaptionPartial else { return }
            lastSentCaptionPartial = trimmed
            sendVerb("CAPTION:partial", payload: trimmed)
        } else {
            guard trimmed != lastSentCaptionFinal else { return }
            lastSentCaptionFinal = trimmed
            lastSentCaptionPartial = ""
            sendVerb("CAPTION:final", payload: trimmed)
        }
    }

    func clearHUDText() {
        lastSentCaptionFinal = ""
        lastSentCaptionPartial = ""
        sendCommand("CLEAR:caption")
    }

    func sendSuggestion(phonetic: String, english: String) {
        let trimmedPhonetic = phonetic.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedEnglish = english.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedPhonetic.isEmpty, trimmedPhonetic != lastSentSuggestionPhonetic {
            lastSentSuggestionPhonetic = trimmedPhonetic
            sendVerb("SUGGEST_PH", payload: trimmedPhonetic)
        }
        if !trimmedEnglish.isEmpty, trimmedEnglish != lastSentSuggestionEnglish {
            lastSentSuggestionEnglish = trimmedEnglish
            sendVerb("SUGGEST_EN", payload: trimmedEnglish)
        }
    }

    func clearSuggestion() {
        lastSentSuggestionPhonetic = ""
        lastSentSuggestionEnglish = ""
        sendCommand("CLEAR:suggestion")
    }

    private func sendCommand(_ command: String) {
        guard let controlChar else { return }
        writeControl(command, char: controlChar)
    }

    private func sendVerb(_ verb: String, payload: String) {
        guard let controlChar else { return }
        let single = "\(verb):\(payload)"
        if single.utf8.count <= Self.singleShotCommandLimit {
            writeControl(single, char: controlChar)
            return
        }
        writeControl("CHUNK_BEGIN:\(verb)", char: controlChar)
        for chunk in utf8SafeChunks(payload, maxBytes: Self.chunkPayloadSize) {
            writeControl("CHUNK:\(chunk)", char: controlChar)
        }
        writeControl("CHUNK_END", char: controlChar)
    }

    /// Splits `text` into chunks of at most `maxBytes` UTF-8 bytes each,
    /// without splitting in the middle of a multi-byte scalar.
    private func utf8SafeChunks(_ text: String, maxBytes: Int) -> [String] {
        var out: [String] = []
        let utf8 = text.utf8
        var idx = utf8.startIndex
        while idx < utf8.endIndex {
            var end = utf8.index(idx, offsetBy: maxBytes, limitedBy: utf8.endIndex) ?? utf8.endIndex
            // Back up while `end` lands on a UTF-8 continuation byte (0b10xx_xxxx).
            while end > idx, end < utf8.endIndex, (utf8[end] & 0b1100_0000) == 0b1000_0000 {
                end = utf8.index(before: end)
            }
            // Defensive: if backing up consumed the whole window (shouldn't
            // happen for valid UTF-8 with a sane maxBytes), force one byte
            // forward to make progress and accept the malformed split.
            if end == idx {
                end = utf8.index(after: idx)
            }
            let piece = String(decoding: utf8[idx..<end], as: UTF8.self)
            out.append(piece)
            idx = end
        }
        return out
    }

    private func writeControl(_ command: String, char: CBCharacteristic) {
        guard let peripheral = connectedPeripheral, let data = command.data(using: .utf8) else {
            appendDevLog(direction: "APP", message: "writeControl dropped — no peripheral or encoding failed (cmd prefix=\(command.prefix(40)))")
            return
        }
        let writeType: CBCharacteristicWriteType = char.properties.contains(.write) ? .withResponse : .withoutResponse
        let logPayload = command.count > 60 ? String(command.prefix(60)) + "…" : command
        appendDevLog(direction: "OUT", message: "\(logPayload) (\(data.count)B, \(writeType == .withResponse ? "wResp" : "noResp"))")
        peripheral.writeValue(data, for: char, type: writeType)
    }

    // MARK: - Audio

    private func appendAudioPacket(_ data: Data) {
        guard data.count >= 6 else {
            appendDevLog(direction: "IN", message: "audio packet too short (\(data.count)B)")
            return
        }
        let version = data[0]
        guard version == 1 else {
            appendDevLog(direction: "IN", message: "audio packet bad version \(version)")
            return
        }
        // Bit depth: 8 = int8 signed PCM (Frame-style), 16 = int16 PCM.
        // Firmware ships 8 since 2026-05; older firmware sent 16. Both
        // codepaths sign-extend into Int16 LE for the recognizer.
        let bitDepth = data[1]
        let bytesPerSample: Int
        switch bitDepth {
        case 8: bytesPerSample = 1
        case 16: bytesPerSample = 2
        default:
            appendDevLog(direction: "IN", message: "audio packet bad bitDepth \(bitDepth)")
            return
        }
        let seq = UInt16(data[2]) | (UInt16(data[3]) << 8)
        let sampleCount = Int(UInt16(data[4]) | (UInt16(data[5]) << 8))
        let payloadBytes = sampleCount * bytesPerSample
        guard data.count >= 6 + payloadBytes, payloadBytes > 0 else {
            appendDevLog(direction: "IN", message: "audio packet length mismatch bitDepth=\(bitDepth) sampleCount=\(sampleCount) data=\(data.count)B")
            return
        }
        let payload = data.subdata(in: 6 ..< 6 + payloadBytes)

        if audioPacketCount == 0 {
            appendDevLog(direction: "IN", message: "first audio packet received seq=\(seq) samples=\(sampleCount) bitDepth=\(bitDepth)")
        } else {
            let expected = audioLastSeq &+ 1
            if seq != expected {
                audioSeqGapCount += 1
                appendDevLog(direction: "IN", message: "audio seq gap expected=\(expected) got=\(seq) totalGaps=\(audioSeqGapCount)")
            }
        }
        audioLastSeq = seq
        audioPacketCount += 1
        audioBytesAccum += data.count
        lastAudioPacketAt = Date()

        // Per-packet stats at int16 scale (-32768..32767). Both wire formats
        // contribute on the same scale so the firmware's [AUDIO] line matches
        // ours: int8 samples are normalized × 256 to int16 magnitudes.
        if bitDepth == 8 {
            payload.withUnsafeBytes { raw in
                guard let src = raw.bindMemory(to: Int8.self).baseAddress else { return }
                var sumAbs: Int64 = 0
                var peak: Int32 = 0
                for i in 0 ..< sampleCount {
                    let a = abs(Int32(src[i])) << 8
                    sumAbs += Int64(a)
                    if a > peak { peak = a }
                }
                audioSumAbs += sumAbs
                audioSampleCount += sampleCount
                if peak > audioPeakAbs { audioPeakAbs = peak }
                let mean = sampleCount > 0 ? Int(sumAbs / Int64(sampleCount)) : 0
                if mean < 50 { audioSilentWindows += 1 }
            }
            appendPCM8(payload)
        } else {
            payload.withUnsafeBytes { raw in
                guard let src = raw.bindMemory(to: Int16.self).baseAddress else { return }
                var sumAbs: Int64 = 0
                var peak: Int32 = 0
                for i in 0 ..< sampleCount {
                    let a = abs(Int32(src[i]))
                    sumAbs += Int64(a)
                    if a > peak { peak = a }
                }
                audioSumAbs += sumAbs
                audioSampleCount += sampleCount
                if peak > audioPeakAbs { audioPeakAbs = peak }
                let mean = sampleCount > 0 ? Int(sumAbs / Int64(sampleCount)) : 0
                if mean < 50 { audioSilentWindows += 1 }
            }
            appendPCM16(payload)
        }
        audioWindowsSinceLog += 1
        flushAudioStatsIfDue()
    }

    /// Sign-extend each int8 byte to Int16 LE (`<< 8`) and feed to the
    /// recognizer. This mirrors `FrameBluetoothManager.appendPCM8` exactly,
    /// which is the wire format SFSpeechRecognizer transcribes well.
    private func appendPCM8(_ payload: Data) {
        guard let request = recognitionRequest else { return }
        let sampleCount = payload.count
        guard sampleCount > 0 else { return }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: streamFormat, frameCapacity: AVAudioFrameCount(sampleCount)),
              let dst = buffer.int16ChannelData?[0] else { return }
        payload.withUnsafeBytes { raw in
            guard let src = raw.bindMemory(to: Int8.self).baseAddress else { return }
            for i in 0 ..< sampleCount {
                dst[i] = Int16(src[i]) << 8
            }
        }
        buffer.frameLength = AVAudioFrameCount(sampleCount)
        request.append(buffer)
    }

    private func appendPCM16(_ payload: Data) {
        guard let request = recognitionRequest else { return }
        let sampleCount = payload.count / MemoryLayout<Int16>.size
        guard sampleCount > 0 else { return }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: streamFormat, frameCapacity: AVAudioFrameCount(sampleCount)),
              let dst = buffer.int16ChannelData?[0] else { return }
        payload.withUnsafeBytes { srcRaw in
            guard let src = srcRaw.baseAddress else { return }
            memcpy(dst, src, payload.count)
        }
        buffer.frameLength = AVAudioFrameCount(sampleCount)
        request.append(buffer)
    }

    /// Emit one [AUDIO] line every `audioStatsLogInterval` packets.
    /// Fields at int16 scale (-32768..32767) regardless of wire bit depth, so
    /// numbers are directly comparable to the firmware's [AUDIO] line.
    ///   pkts:  cumulative audio packets received this session
    ///   peak:  max |sample| in window (≥1500 audible, ≥10000 loud, ≥30000 clipping)
    ///   avg:   mean |sample| in window (typical speech: 500–3000)
    ///   silR:  % of packets whose mean was <50 (true silence)
    ///   bytes: bytes received over the window
    ///   gaps:  cumulative dropped/out-of-order packet events this session
    /// Triage:
    ///   peak < 500 → mic dead OR DC subtract over-aggressive; check firmware
    ///   silR > 80  → recognizer hears no signal (room quiet OR mic broken)
    ///   peak ≥ 30000 → clipping; back off mic distance
    ///   gaps > 0  → BLE dropouts; check RSSI / proximity
    private func flushAudioStatsIfDue() {
        guard audioWindowsSinceLog >= Self.audioStatsLogInterval else { return }
        let windowSamples = max(audioSampleCount, 1)
        let avg = Int(audioSumAbs / Int64(windowSamples))
        let silR = audioWindowsSinceLog > 0
            ? Int((100.0 * Double(audioSilentWindows)) / Double(audioWindowsSinceLog))
            : 0
        appendDevLog(
            direction: "AUDIO",
            message: "pkts=\(audioPacketCount) peak=\(audioPeakAbs) avg=\(avg) silR=\(silR)% bytes=\(audioBytesAccum) gaps=\(audioSeqGapCount)"
        )
        audioPeakAbs = 0
        audioSumAbs = 0
        audioSampleCount = 0
        audioSilentWindows = 0
        audioWindowsSinceLog = 0
        audioBytesAccum = 0
    }

    private func resetAudioStats(reason: String) {
        appendDevLog(direction: "AUDIO", message: "stats reset (\(reason))")
        audioPacketCount = 0
        audioBytesAccum = 0
        audioPeakAbs = 0
        audioSumAbs = 0
        audioSampleCount = 0
        audioSilentWindows = 0
        audioWindowsSinceLog = 0
        audioLastSeq = 0
        audioSeqGapCount = 0
        lastAudioPacketAt = .distantPast
        lastRecognitionResultAt = Date()
    }

    // MARK: - Lifecycle

    func warmUp() {
        Task { _ = try? await translationClient.translate(text: "hello", source: "en", target: "es") }
    }

    func handleScenePhaseChange(_ phase: ScenePhase) {
        switch phase {
        case .background:
            // Intentionally keep BLE + listening alive when the app is backgrounded.
            // The bluetooth-central UIBackgroundMode keeps the central manager alive
            // so audio/captions continue to flow while the phone is locked.
            break
        default:
            break
        }
    }
}

// MARK: - HUDDeviceManager conformance

extension ESP32BluetoothManager: HUDDeviceManager {
    var kind: HUDDeviceKind { .esp32 }
}

// MARK: - CBCentralManagerDelegate

extension ESP32BluetoothManager: CBCentralManagerDelegate {
    nonisolated func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        let restored = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
        Task { @MainActor in
            guard let peripheral = restored.first else { return }
            self.connectedPeripheral = peripheral
            peripheral.delegate = self
            self.state = .connected(peripheral.name ?? "ESP32")
            if peripheral.state == .connected {
                peripheral.discoverServices([Self.service])
            }
        }
    }

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            switch central.state {
            case .poweredOn:
                self.statusMessage = "Bluetooth ready"
                if self.shouldScanWhenReady { self.startScan() }
            case .poweredOff:
                self.resetConnectionState(message: "Turn on Bluetooth to start")
            case .unauthorized:
                self.resetConnectionState(message: "Allow Bluetooth in Settings")
            case .unsupported:
                self.resetConnectionState(message: "Bluetooth unsupported")
            case .resetting:
                self.statusMessage = "Bluetooth resetting…"
            default:
                self.statusMessage = "Waiting for Bluetooth…"
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any],
                                    rssi RSSI: NSNumber) {
        Task { @MainActor in
            let name = peripheral.name ?? "Unnamed"
            if self.discoveredDevices.contains(where: { $0.peripheral == peripheral }) { return }
            self.discoveredDevices.append(
                FrameBluetoothManager.DiscoveredDevice(name: name, peripheral: peripheral, rssi: RSSI)
            )
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            self.connectedPeripheral = peripheral
            peripheral.delegate = self
            self.state = .connected(peripheral.name ?? "ESP32")
            self.statusMessage = "Connected. Discovering service…"
            peripheral.discoverServices([Self.service])
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didFailToConnect peripheral: CBPeripheral,
                                    error: Error?) {
        Task { @MainActor in
            self.resetConnectionState(
                message: "Failed to connect: \(error?.localizedDescription ?? "Unknown error")"
            )
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didDisconnectPeripheral peripheral: CBPeripheral,
                                    error: Error?) {
        Task { @MainActor in
            if let error {
                self.resetConnectionState(message: "Disconnected: \(error.localizedDescription)")
            } else {
                self.resetConnectionState(message: "Disconnected")
            }
        }
    }
}

// MARK: - CBPeripheralDelegate

extension ESP32BluetoothManager: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        Task { @MainActor in
            guard error == nil, let services = peripheral.services else {
                self.statusMessage = "Service discovery failed"
                return
            }
            for service in services where service.uuid == Self.service {
                peripheral.discoverCharacteristics(
                    [Self.audioDataCharacteristic, Self.controlCharacteristic, Self.statusCharacteristic],
                    for: service
                )
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didDiscoverCharacteristicsFor service: CBService,
                                error: Error?) {
        Task { @MainActor in
            guard error == nil, let chars = service.characteristics else {
                self.statusMessage = "Characteristic discovery failed"
                return
            }
            for char in chars {
                switch char.uuid {
                case Self.audioDataCharacteristic:
                    self.audioDataChar = char
                    peripheral.setNotifyValue(true, for: char)
                case Self.controlCharacteristic:
                    self.controlChar = char
                case Self.statusCharacteristic:
                    self.statusChar = char
                    peripheral.setNotifyValue(true, for: char)
                default:
                    break
                }
            }
            self.statusMessage = "ESP32 ready"
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didUpdateValueFor characteristic: CBCharacteristic,
                                error: Error?) {
        if let error {
            Task { @MainActor in
                self.appendDevLog(direction: "IN", message: "characteristic update error \(characteristic.uuid): \(error.localizedDescription)")
            }
            return
        }
        guard let value = characteristic.value else { return }
        let uuid = characteristic.uuid
        Task { @MainActor in
            if uuid == Self.audioDataCharacteristic {
                self.appendAudioPacket(value)
            } else if uuid == Self.statusCharacteristic {
                if let text = String(data: value, encoding: .utf8) {
                    if text.hasPrefix("MIC_REQUEST") {
                        let seq = text.split(separator: ":").last
                            .flatMap { UInt16($0) } ?? 0
                        let dedup = (seq != 0 && seq == self.lastButtonSeq)
                        self.appendDevLog(
                            direction: "IN",
                            message: "MIC_REQUEST seq=\(seq) \(dedup ? "(dedup, ignored)" : "(toggled)")"
                        )
                        if seq == 0 || seq != self.lastButtonSeq {
                            self.lastButtonSeq = seq
                            self.toggleListeningFromPeripheralButton()
                        }
                        return
                    }
                    self.appendDevLog(direction: "IN", message: "STATUS \(text)")
                    self.statusMessage = "ESP32: \(text)"
                } else {
                    self.appendDevLog(direction: "IN", message: "STATUS non-utf8 (\(value.count)B)")
                }
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didWriteValueFor characteristic: CBCharacteristic,
                                error: Error?) {
        if let error {
            Task { @MainActor in
                self.appendDevLog(direction: "OUT", message: "write error on \(characteristic.uuid): \(error.localizedDescription)")
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didUpdateNotificationStateFor characteristic: CBCharacteristic,
                                error: Error?) {
        Task { @MainActor in
            if let error {
                self.appendDevLog(direction: "IN", message: "notify state error \(characteristic.uuid): \(error.localizedDescription)")
            } else {
                self.appendDevLog(
                    direction: "IN",
                    message: "notify=\(characteristic.isNotifying) for \(self.shortName(for: characteristic.uuid))"
                )
            }
        }
    }

    private func shortName(for uuid: CBUUID) -> String {
        switch uuid {
        case Self.audioDataCharacteristic: return "audio"
        case Self.controlCharacteristic:   return "control"
        case Self.statusCharacteristic:    return "status"
        default:                           return uuid.uuidString
        }
    }
}
