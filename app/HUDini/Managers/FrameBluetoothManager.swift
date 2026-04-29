import Foundation
import Combine
import CoreBluetooth
import AVFoundation
import Speech
import SwiftUI

struct FrameDisplayPreferences: Equatable {
    var brightness: Int = 2
    var showsLivePartials: Bool = true

    func commandPayload() -> String {
        "brightness=\(brightness);partials=\(showsLivePartials ? 1 : 0)"
    }
}

@MainActor
final class FrameBluetoothManager: NSObject, ObservableObject {
    struct DevLogEntry: Identifiable {
        let id = UUID()
        let timestamp: Date
        let direction: String
        let message: String
    }

    struct DiscoveredDevice: Identifiable {
        let id = UUID()
        let name: String
        let peripheral: CBPeripheral
        let rssi: NSNumber
    }

    enum ConnectionState: Equatable {
        case idle
        case scanning
        case connecting(String)
        case connected(String)
    }

    private static let service = CBUUID(string: "7A230001-5475-A6A4-654C-8431F6AD49C4")
    private static let txCharacteristic = CBUUID(string: "7A230002-5475-A6A4-654C-8431F6AD49C4")
    private static let rxCharacteristic = CBUUID(string: "7A230003-5475-A6A4-654C-8431F6AD49C4")
    private static let rawPrefix: UInt8 = 0x01
    private static let breakSignal: UInt8 = 0x03
    private static let resetSignal: UInt8 = 0x04
    private static let audioDataNonFinal: UInt8 = 0x05
    private static let audioDataFinal: UInt8 = 0x06
    private static let tapEvent: UInt8 = 0x10
    // Frame mic is configured for 16 kHz / 8-bit signed mono (see start_mic
    // in main.lua / FrameEmbeddedApp.swift). `appendPCM8` sign-extends each
    // 8-bit sample into Int16 and feeds the recognizer at 16 kHz.
    private static let streamSampleRate: Double = 16_000
    private static let streamBitDepth: Int = 8
    private static let embeddedAppVersion = "2026.04.28.10"
    private static let savedPeripheralIDKey = "FrameBluetoothManager.lastPeripheralID"
    private static let centralRestoreIdentifier = "com.hudini.frame.central"
    private static let supportedFrameAppVersions: Set<String> = [embeddedAppVersion]

    @Published private(set) var state: ConnectionState = .idle {
        didSet {
            guard oldValue != state else { return }
            appendDevLog(direction: "APP", message: "state \(String(describing: oldValue)) -> \(String(describing: state))")
        }
    }
    @Published private(set) var discoveredDevices: [DiscoveredDevice] = []
    @Published private(set) var statusMessage: String = "Checking Bluetooth…" {
        didSet {
            guard oldValue != statusMessage else { return }
            appendDevLog(direction: "APP", message: "statusMessage = \(statusMessage)")
        }
    }
    @Published private(set) var peripheralStatus: String = "" {
        didSet {
            guard oldValue != peripheralStatus else { return }
            appendDevLog(direction: "APP", message: "peripheralStatus = \(peripheralStatus)")
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
    @Published private(set) var frameFirmwareVersion: String = ""
    @Published private(set) var frameAppVersion: String = ""
    @Published private(set) var framePayloadLimit: Int = 0
    @Published private(set) var frameBatteryLevel: Int? = nil
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
    @Published private(set) var connectionDebugStage: String = "Idle" {
        didSet {
            guard oldValue != connectionDebugStage else { return }
            appendDevLog(direction: "APP", message: "connectionDebugStage = \(connectionDebugStage)")
        }
    }
    @Published private(set) var isInstallingApp: Bool = false
    @Published private(set) var installStatus: String = "Not installed from phone yet"
    @Published private(set) var installerOutput: String = ""
    @Published private(set) var devLogEntries: [DevLogEntry] = []
    @Published var preferences: FrameDisplayPreferences = .init()

    private var central: CBCentralManager!
    private var connectedPeripheral: CBPeripheral?
    private var txChar: CBCharacteristic?
    private var rxChar: CBCharacteristic?
    private var shouldScanWhenReady = false
    private var shouldAttemptReconnect = false
    private var explicitDisconnectRequested = false
    private var lastConnectedPeripheralID: UUID?
    private var isAppActive = true
    private var hasReceivedFrameAppHeartbeat = false
    private var frameAppIsCompatible = false
    private var connectRetryCount = 0

    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var recognizer = SFSpeechRecognizer(locale: Locale.current)
    private let translationClient = HUDTranslationClient()
    private var translationTask: Task<Void, Never>?
    private var latestTranslationRequestID = UUID()
    private var lastPartialTranslationAt: Date = .distantPast
    private let partialTranslationInterval: TimeInterval = 0.10
    private var latestTranscriptSnapshot: String = ""
    private var lastPartialTranslationText: String = ""
    private var lastRecognitionResultAt: Date = .distantPast
    private var lastAudioPacketAt: Date = .distantPast
    private var audioPacketCount: Int = 0
    private var lastSentFinalCaption: String = ""
    private var lastSentPartialCaption: String = ""
    private var lastSentSuggestion: String = ""
    private var replTextBuffer: String = ""
    private var lastTapAt: Date = .distantPast
    private var keepaliveTask: Task<Void, Never>?
    private var audioEnergyAccumulator: Float = 0
    private var audioEnergySampleCount: Int = 0
    private var debugAudioFileHandle: FileHandle?
    private(set) var debugAudioFilePath: URL?
    @Published private(set) var debugAudioRecordings: [URL] = []
    private static let maxDebugRecordings = 10
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
        if let storedIdentifier = UserDefaults.standard.string(forKey: Self.savedPeripheralIDKey),
           let uuid = UUID(uuidString: storedIdentifier) {
            lastConnectedPeripheralID = uuid
        }
        selectedLanguageCode = TranslationLanguages.preferredListeningLanguageCode()
        recognizer = SFSpeechRecognizer(locale: Locale(identifier: selectedLanguageCode))
        central = CBCentralManager(
            delegate: self,
            queue: nil,
            options: [CBCentralManagerOptionRestoreIdentifierKey: Self.centralRestoreIdentifier]
        )
        handleState(central.state)
    }

    /// Auto-reconnect has been removed — connect is always user-initiated from the
    /// Device Sync sheet's Scan button. Kept as a no-op to preserve the call site.
    func unlockAutoReconnect() {}

    /// Pre-warms the translation client so the first user-facing translation isn't cold.
    /// Safe to call multiple times; the client caches internally.
    func warmUp() {
        Task { _ = try? await translationClient.translate(text: "hello", source: "en", target: "es") }
    }

    func beginScanning() {
        guard central.state == .poweredOn else {
            shouldScanWhenReady = true
            statusMessage = waitingMessage()
            return
        }
        startScan()
    }

    func stopScanning() {
        central.stopScan()
        if case .scanning = state {
            state = .idle
        }
    }

    func connect(to device: DiscoveredDevice) {
        if connectedPeripheral == device.peripheral {
            logDecision("connect(to:) ignored because peripheral is already connected")
            return
        }
        if case .connecting(let name) = state, name == device.name {
            logDecision("connect(to:) ignored because connection is already in progress")
            return
        }
        stopScanning()
        explicitDisconnectRequested = false
        shouldAttemptReconnect = false
        connectRetryCount = 0
        state = .connecting(device.name)
        connectionDebugStage = "Connect requested"
        statusMessage = "Connecting to \(device.name)…"
        central.connect(device.peripheral, options: nil)
    }

    func disconnect() {
        explicitDisconnectRequested = true
        shouldAttemptReconnect = false
        connectRetryCount = 0
        stopListening()
        guard let peripheral = connectedPeripheral else { return }
        central.cancelPeripheralConnection(peripheral)
        resetConnectionState(message: "Disconnected")
    }

    func handleScenePhaseChange(_ phase: ScenePhase) {
        switch phase {
        case .active:
            isAppActive = true
            if connectedPeripheral != nil, txChar != nil, hasReceivedFrameAppHeartbeat {
                bootstrapFrameSession(reason: "App active")
            }
        case .inactive:
            break
        case .background:
            isAppActive = false
            // Intentionally keep BLE + listening alive when the app is backgrounded.
            // The bluetooth-central UIBackgroundMode keeps the central manager
            // delivering BLE notifications so captions/suggestions on the Frame
            // continue to work when the phone is locked or in the user's pocket.
        @unknown default:
            break
        }
    }

    func ping() {
        sendRawCommand(["PING"], preferredType: .withResponse)
    }

    func rebootRunningFrameApp() {
        guard connectedPeripheral != nil else {
            statusMessage = "Connect to Frame first"
            return
        }
        sendControlByte(Self.resetSignal)
        statusMessage = "Sent Frame reset signal"
    }

    func resetFrame() {
        guard connectedPeripheral != nil else {
            statusMessage = "Connect to Frame first"
            return
        }
        stopListening()
        sendControlByte(Self.resetSignal)
        statusMessage = "Frame reset"
    }

    func breakRunningFrameApp() {
        guard connectedPeripheral != nil else {
            statusMessage = "Connect to Frame first"
            return
        }
        sendControlByte(Self.breakSignal)
        statusMessage = "Sent Frame break signal"
    }

    func installOrUpdateHUDiniApp() {
        guard connectedPeripheral != nil, txChar != nil else {
            statusMessage = "Connect to Frame first"
            installStatus = "Connect to Frame first"
            return
        }
        guard !isInstallingApp else { return }

        isInstallingApp = true
        installStatus = "Preparing upload…"
        installerOutput = ""
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performHUDiniInstall()
        }
    }

    func applyPreferences() {
        sendRawCommand(["SET_PREFS", preferences.commandPayload()], preferredType: .withResponse)
    }

    func setRecognitionLanguage(_ code: String) {
        guard TranslationLanguages.supported.contains(where: { $0.code == code }) else {
            statusMessage = "Unsupported language: \(code)"
            return
        }
        guard let newRecognizer = SFSpeechRecognizer(locale: Locale(identifier: code)) else {
            statusMessage = "Speech recognizer unavailable for \(TranslationLanguages.displayName(for: code))"
            return
        }

        selectedLanguageCode = code
        UserDefaults.standard.set(code, forKey: APIConfig.AppStorageKey.hudListeningLanguageCode)
        recognizer = newRecognizer

        if isStreaming {
            stopRecognition()
            if !startRecognition() {
                statusMessage = "Speech recognizer unavailable for \(TranslationLanguages.displayName(for: code))"
            } else {
                statusMessage = "Listening language set to \(TranslationLanguages.displayName(for: code))"
            }
        } else {
            statusMessage = "Listening language set to \(TranslationLanguages.displayName(for: code))"
        }
    }

    func setTargetLanguage(_ code: String) {
        guard TranslationLanguages.targetOptions.contains(where: { $0.code == code }) else {
            statusMessage = "Unsupported target language: \(code)"
            return
        }
        targetLanguageCode = code
        statusMessage = "Target language set to \(TranslationLanguages.displayName(for: code))"
    }

    func startTranscribing(
        listeningLanguage: String,
        translatingTo targetLanguage: String,
        triggeredByTap: Bool = false
    ) {
        setRecognitionLanguage(listeningLanguage)
        setTargetLanguage(targetLanguage)
        startListening(triggeredByTap: triggeredByTap)
    }

    func startListening(triggeredByTap: Bool = false) {
        guard connectedPeripheral != nil, txChar != nil else {
            statusMessage = "Connect to Frame first"
            return
        }
        guard !isStreaming else {
            statusMessage = triggeredByTap ? "Started from Frame tap" : "Listening…"
            return
        }

        lastPartialTranslationAt = .distantPast

        resetAudioConditioning()

        Task { @MainActor in
            let authorization = await requestSpeechAuthorization()
            guard authorization == .authorized else {
                statusMessage = "Allow Speech Recognition in Settings"
                return
            }

            if !self.startRecognition() {
                statusMessage = "Speech recognizer unavailable"
                return
            }
            self.setStreamingState(true)
            self.startDebugAudioCapture()
            self.sendRawCommand(["SYNC_STATE", "1", "listening"], preferredType: .withResponse)
            self.statusMessage = triggeredByTap ? "Started from Frame tap" : "Listening…"
        }
    }

    func stopListening() {
        stopDebugAudioCapture()
        stopRecognition()
        setStreamingState(false)
        sendRawCommand(["SYNC_STATE", "0", "idle"], preferredType: .withResponse)
        statusMessage = "Stopped"
    }

    func clearTranscript() {
        liveTranscript = ""
        renderedText = ""
        lastSentFinalCaption = ""
        lastSentPartialCaption = ""
        cancelTranslation()
        clearFrameDisplay()
    }

    func clearFrameDisplay() {
        lastSentFinalCaption = ""
        lastSentPartialCaption = ""
        sendRawCommand(["CLEAR_CAPTION"])
    }

    private func setStreamingState(_ enabled: Bool) {
        logDecision("setStreamingState(\(enabled))")
        isStreaming = enabled
    }

    private func bootstrapFrameSession(reason: String) {
        guard connectedPeripheral != nil, txChar != nil else { return }
        guard hasReceivedFrameAppHeartbeat else {
            ping()
            return
        }
        guard frameAppIsCompatible else {
            connectionDebugStage = "Frame app update required"
            statusMessage = "Connected to Frame. Install or update HUDini on Frame."
            return
        }
        connectionDebugStage = "Bootstrapping session"
        statusMessage = reason
        applyPreferences()
        sendRawCommand(["SYNC_STATE", isStreaming ? "1" : "0", isStreaming ? "listening" : "idle"], preferredType: .withResponse)
        if !lastSentFinalCaption.isEmpty {
            sendRawCommand(["SHOW_CAPTION", "final", lastSentFinalCaption])
        } else if !lastSentPartialCaption.isEmpty {
            sendRawCommand(["SHOW_CAPTION", "partial", lastSentPartialCaption])
        }
        startKeepalive()
    }

    private func startKeepalive() {
        keepaliveTask?.cancel()
        keepaliveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                if Task.isCancelled { return }
                await MainActor.run {
                    guard let self else { return }
                    guard self.connectedPeripheral != nil,
                          self.txChar != nil,
                          self.hasReceivedFrameAppHeartbeat else { return }
                    self.sendRawCommand(["PING"], preferredType: .withoutResponse)
                }
            }
        }
    }

    private func stopKeepalive() {
        keepaliveTask?.cancel()
        keepaliveTask = nil
    }

    private func clearRememberedPeripheral() {
        lastConnectedPeripheralID = nil
        UserDefaults.standard.removeObject(forKey: Self.savedPeripheralIDKey)
    }

    func sendHUDTextToFrame(_ text: String, isPartial: Bool = false, updateStatus: Bool = false) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        logDecision("sendHUDTextToFrame isPartial=\(isPartial) text=\(trimmed)")

        if isPartial {
            guard trimmed != lastSentPartialCaption else {
                logDecision("sendHUDTextToFrame skipped duplicate partial")
                return
            }
            lastSentPartialCaption = trimmed
            sendRawCommand(["SHOW_CAPTION", "partial", trimmed])
        } else {
            guard trimmed != lastSentFinalCaption else {
                logDecision("sendHUDTextToFrame skipped duplicate final")
                return
            }
            lastSentFinalCaption = trimmed
            lastSentPartialCaption = ""
            sendRawCommand(["SHOW_CAPTION", "final", trimmed])
        }

        if updateStatus {
            statusMessage = "Updated Frame display"
        }
    }

    func sendSuggestionToFrame(phonetic: String, english: String) {
        let trimmedPhonetic = phonetic.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedEnglish = english.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !(trimmedPhonetic.isEmpty && trimmedEnglish.isEmpty) else { return }
        let dedupKey = trimmedPhonetic + "\u{1F}" + trimmedEnglish
        guard dedupKey != lastSentSuggestion else { return }
        lastSentSuggestion = dedupKey
        logDecision("sendSuggestionToFrame phonetic=\(trimmedPhonetic) english=\(trimmedEnglish)")
        sendRawCommand(["SHOW_SUGGESTION", trimmedPhonetic, trimmedEnglish])
    }

    func clearSuggestionOnFrame() {
        lastSentSuggestion = ""
        sendRawCommand(["SHOW_SUGGESTION", "", ""])
    }

    func clearDevLog() {
        devLogEntries = []
    }

    private func appendDevLog(direction: String, message: String) {
        let normalized = message.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
        devLogEntries.append(DevLogEntry(timestamp: Date(), direction: direction, message: normalized))
    }

    private func logDecision(_ message: String) {
        appendDevLog(direction: "APP", message: message)
    }

    private func sendControlByte(_ value: UInt8) {
        guard let peripheral = connectedPeripheral, let txChar else { return }
        appendDevLog(direction: "OUT", message: "CONTROL 0x" + String(format: "%02X", value))
        peripheral.writeValue(Data([value]), for: txChar, type: txWriteType)
    }

    private func sendLuaLine(_ statement: String) {
        guard let peripheral = connectedPeripheral, let txChar else { return }
        guard let data = "\(statement)\n".data(using: .utf8) else { return }
        appendDevLog(direction: "OUT", message: "LUA " + statement)
        peripheral.writeValue(data, for: txChar, type: txWriteType)
    }

    private func sendRawCommand(_ fields: [String], preferredType: CBCharacteristicWriteType? = nil) {
        guard let peripheral = connectedPeripheral, let txChar else { return }
        let payload = fields
            .map { $0.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ") }
            .joined(separator: "\t")

        guard let textData = payload.data(using: .utf8) else { return }
        appendDevLog(direction: "OUT", message: payload)

        // Wire format matches the inlined `data.lua` accumulator on Frame:
        //   first chunk     = [0x01][size_hi][size_lo][payload bytes...]
        //   continuations   = [0x01][payload bytes...]
        // The Frame reassembles when sum(chunk sizes) == size_hi/size_lo length.
        // 23 is the BLE-spec minimum payload; framePayloadLimit may be 0 before BOOT.
        let mtu = max(framePayloadLimit, 23)
        let writeType = supportedWriteType(preferred: preferredType, characteristic: txChar)
        let total = textData.count
        let totalU16 = UInt16(min(total, 0xFFFF))
        let sizeHi = UInt8((Int(totalU16) >> 8) & 0xFF)
        let sizeLo = UInt8(Int(totalU16) & 0xFF)
        let firstChunkPayloadMax = max(1, mtu - 3)
        let nextChunkPayloadMax = max(1, mtu - 1)

        if total <= firstChunkPayloadMax {
            var packet = Data([Self.rawPrefix, sizeHi, sizeLo])
            packet.append(textData)
            peripheral.writeValue(packet, for: txChar, type: writeType)
            return
        }

        var offset = 0
        let firstLen = firstChunkPayloadMax
        var first = Data([Self.rawPrefix, sizeHi, sizeLo])
        first.append(textData.subdata(in: 0 ..< firstLen))
        peripheral.writeValue(first, for: txChar, type: writeType)
        offset += firstLen

        while offset < total {
            let len = min(nextChunkPayloadMax, total - offset)
            var packet = Data([Self.rawPrefix])
            packet.append(textData.subdata(in: offset ..< (offset + len)))
            peripheral.writeValue(packet, for: txChar, type: writeType)
            offset += len
        }
    }

    private func supportedWriteType(preferred: CBCharacteristicWriteType?, characteristic: CBCharacteristic) -> CBCharacteristicWriteType {
        if preferred == .withResponse, characteristic.properties.contains(.write) {
            return .withResponse
        }
        if preferred == .withoutResponse, characteristic.properties.contains(.writeWithoutResponse) {
            return .withoutResponse
        }
        if characteristic.properties.contains(.writeWithoutResponse) {
            return .withoutResponse
        }
        return .withResponse
    }

    private var txWriteType: CBCharacteristicWriteType {
        guard let txChar else { return .withResponse }
        if txChar.properties.contains(.writeWithoutResponse) {
            return .withoutResponse
        }
        return .withResponse
    }

    private func startRecognition() -> Bool {
        audioPacketCount = 0
        lastRecognitionResultAt = Date()
        lastAudioPacketAt = .distantPast
        logDecision("startRecognition invoked locale=\(selectedLanguageCode)")
        guard let recognizer, recognizer.isAvailable else {
            statusMessage = "Speech recognizer unavailable"
            logDecision("startRecognition failed recognizer unavailable")
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
            if let result {
                let transcript = result.bestTranscription.formattedString
                let now = Date()
                let sinceLastResult = now.timeIntervalSince(self.lastRecognitionResultAt)
                let sinceLastAudio = now.timeIntervalSince(self.lastAudioPacketAt)
                self.lastRecognitionResultAt = now
                self.logDecision("[TIMING] recognition result isFinal=\(result.isFinal) sinceLastResult=\(String(format: "%.0f", sinceLastResult * 1000))ms sinceLastAudio=\(String(format: "%.0f", sinceLastAudio * 1000))ms packets=\(self.audioPacketCount) transcript=\(transcript)")
                if !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    self.liveTranscript = transcript
                    self.handleTranscriptUpdate(text: transcript, isFinal: result.isFinal)
                } else {
                    self.logDecision("recognitionTask ignored empty transcript result")
                }
                if result.isFinal && !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    self.statusMessage = "Finalized segment"
                }
            }

            if let error {
                let desc = error.localizedDescription
                self.logDecision("recognitionTask error: \(desc)")
                if !self.isStreaming { return }
                self.statusMessage = "Recognition ended: \(desc)"
            }
        }
        return true
    }

    private func stopRecognition() {
        logDecision("stopRecognition invoked")
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil

        lastPartialTranslationAt = .distantPast
        lastPartialTranslationText = ""
        resetAudioConditioning()
        cancelTranslation()
    }

    private func handleTranscriptUpdate(text: String, isFinal: Bool) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        logDecision("handleTranscriptUpdate isFinal=\(isFinal) raw=\(text) trimmed=\(trimmed)")
        guard !trimmed.isEmpty else {
            logDecision("handleTranscriptUpdate ignored empty transcript")
            return
        }

        latestTranscriptSnapshot = trimmed

        if shouldBypassTranslation(source: selectedLanguageCode, target: targetLanguageCode) {
            logDecision("handleTranscriptUpdate bypassing translation source=\(selectedLanguageCode) target=\(targetLanguageCode)")
            renderedText = trimmed
            sendHUDTextToFrame(trimmed, isPartial: !isFinal)
            return
        }

        if !isFinal {
            guard trimmed.count >= 2 else {
                logDecision("partial translation skipped text too short count=\(trimmed.count)")
                return
            }
            guard trimmed != lastPartialTranslationText else {
                logDecision("partial translation skipped duplicate text")
                return
            }
            let now = Date()
            let delta = now.timeIntervalSince(lastPartialTranslationAt)
            guard delta >= partialTranslationInterval else {
                logDecision("partial translation throttled delta=\(delta)s threshold=\(partialTranslationInterval)s")
                return
            }
            lastPartialTranslationAt = now
            lastPartialTranslationText = trimmed
            logDecision("partial translation accepted text=\(trimmed)")
        } else {
            lastPartialTranslationText = trimmed
            logDecision("final translation accepted text=\(trimmed)")
        }

        let requestID = UUID()
        latestTranslationRequestID = requestID
        let transcriptSnapshot = trimmed
        let translationStartTime = Date()
        translationTask?.cancel()
        logDecision("[TIMING] translation start isFinal=\(isFinal) source=\(selectedLanguageCode) target=\(targetLanguageCode) text=\(transcriptSnapshot)")
        translationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let translated = try await translationClient.translate(
                    text: transcriptSnapshot,
                    source: selectedLanguageCode,
                    target: targetLanguageCode
                )
                let apiMs = Date().timeIntervalSince(translationStartTime) * 1000
                guard !Task.isCancelled else { return }
                guard latestTranslationRequestID == requestID else {
                    self.logDecision("[TIMING] translation dropped stale after \(String(format: "%.0f", apiMs))ms")
                    return
                }
                if !isFinal, latestTranscriptSnapshot != transcriptSnapshot {
                    self.logDecision("[TIMING] translation dropped mismatch after \(String(format: "%.0f", apiMs))ms")
                    return
                }

                self.logDecision("[TIMING] translation done in \(String(format: "%.0f", apiMs))ms translated=\(translated)")
                renderedText = translated
                sendHUDTextToFrame(translated, isPartial: !isFinal)
            } catch is CancellationError {
                self.logDecision("translationTask cancelled requestID=\(requestID)")
                return
            } catch {
                guard !Task.isCancelled else { return }
                guard latestTranslationRequestID == requestID else {
                    self.logDecision("translationTask error ignored stale requestID=\(requestID) error=\(error.localizedDescription)")
                    return
                }
                self.logDecision("translationTask failed requestID=\(requestID) error=\(error.localizedDescription)")
                statusMessage = "Translation error: \(error.localizedDescription)"
            }
        }
    }

    private func cancelTranslation() {
        logDecision("cancelTranslation invoked")
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
        if let dashIndex = cleaned.firstIndex(of: "-") {
            return String(cleaned[..<dashIndex])
        }
        if let underscoreIndex = cleaned.firstIndex(of: "_") {
            return String(cleaned[..<underscoreIndex])
        }
        return cleaned
    }

    private func appendAudioPacket(_ payload: Data) {
        guard payload.count >= 2 else { return }
        guard recognitionRequest != nil else { return }

        // Strip 1-byte header (0x05 non-final or 0x06 final)
        let audioPayload = payload.subdata(in: 1 ..< payload.count)
        lastAudioPacketAt = Date()
        audioPacketCount += 1
        if audioPacketCount % 100 == 0 {
            logDecision("audioPacket milestone count=\(audioPacketCount) packets=\(audioPacketCount)")
        }
        if Self.streamBitDepth == 8 {
            appendPCM8(audioPayload)
        } else {
            appendPCM16(audioPayload)
        }
        logAudioEnergyIfNeeded()
    }

    private func appendPCM16(_ payload: Data) {
        let sampleCount = payload.count / MemoryLayout<Int16>.size
        guard sampleCount > 0 else { return }

        // Log energy and capture debug audio (16kHz/16-bit after conversion)
        payload.withUnsafeBytes { raw in
            guard let src = raw.bindMemory(to: Int16.self).baseAddress else { return }
            var sumAbs: Float = 0
            for i in 0 ..< sampleCount {
                sumAbs += abs(Float(src[i]))
            }
            audioEnergyAccumulator += sumAbs / Float(sampleCount)
            audioEnergySampleCount += 1
        }
        debugAudioFileHandle?.write(payload)

        guard let request = recognitionRequest else { return }

        // Feed 16kHz PCM directly to recognizer — no upsampling needed
        guard let buffer = AVAudioPCMBuffer(pcmFormat: streamFormat, frameCapacity: AVAudioFrameCount(sampleCount)),
              let dst = buffer.int16ChannelData?[0] else { return }
        payload.withUnsafeBytes { srcRaw in
            guard let src = srcRaw.baseAddress else { return }
            memcpy(dst, src, payload.count)
        }
        buffer.frameLength = AVAudioFrameCount(sampleCount)
        request.append(buffer)
    }

    private func appendPCM8(_ payload: Data) {
        let sampleCount = payload.count
        guard sampleCount > 0 else { return }

        var converted = Data(count: sampleCount * MemoryLayout<Int16>.size)
        converted.withUnsafeMutableBytes { dstRaw in
            guard let dst = dstRaw.bindMemory(to: Int16.self).baseAddress else { return }
            for index in 0 ..< sampleCount {
                let signedByte = Int8(bitPattern: payload[index])
                dst[index] = Int16(signedByte) << 8
            }
        }

        appendPCM16(converted)
    }

    private func logAudioEnergyIfNeeded() {
        guard audioEnergySampleCount > 0, audioPacketCount % 500 == 0 else { return }
        let avgEnergy = audioEnergyAccumulator / Float(audioEnergySampleCount)
        logDecision("[AUDIO] energy=\(Int(avgEnergy)) packets=\(audioPacketCount)")
        audioEnergyAccumulator = 0
        audioEnergySampleCount = 0
    }

    private func startDebugAudioCapture() {
        let fileName = "frame_audio_\(Int(Date().timeIntervalSince1970)).raw"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        debugAudioFileHandle = try? FileHandle(forWritingTo: url)
        debugAudioFilePath = url
        logDecision("[AUDIO] debug capture started: \(url.lastPathComponent)")
    }

    private func stopDebugAudioCapture() {
        guard let handle = debugAudioFileHandle else { return }
        try? handle.close()
        debugAudioFileHandle = nil
        if let path = debugAudioFilePath {
            let size = (try? FileManager.default.attributesOfItem(atPath: path.path)[.size] as? Int) ?? 0
            let duration = Double(size) / (Self.streamSampleRate * 2.0)
            logDecision("[AUDIO] debug capture saved: \(path.lastPathComponent) size=\(size) bytes (~\(String(format: "%.1f", duration))s)")
            if size > 0 {
                debugAudioRecordings.append(path)
                trimOldRecordings()
            }
        }
    }

    private func trimOldRecordings() {
        while debugAudioRecordings.count > Self.maxDebugRecordings {
            let old = debugAudioRecordings.removeFirst()
            try? FileManager.default.removeItem(at: old)
        }
    }

    func clearDebugRecordings() {
        for url in debugAudioRecordings {
            try? FileManager.default.removeItem(at: url)
        }
        debugAudioRecordings.removeAll()
        debugAudioFilePath = nil
    }

    private func resetAudioConditioning() {
    }

    private func startScan() {
        shouldScanWhenReady = false
        discoveredDevices = []
        connectionDebugStage = "Scanning"
        central.scanForPeripherals(
            withServices: [Self.service],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
        state = .scanning
        statusMessage = "Scanning for Frame glasses…"
    }

    private func resetConnectionState(message: String) {

        txChar = nil
        rxChar = nil
        connectedPeripheral = nil
        discoveredDevices = []
        state = .idle
        connectionDebugStage = message
        statusMessage = message
        peripheralStatus = ""
        frameFirmwareVersion = ""
        frameAppVersion = ""
        framePayloadLimit = 0
        frameBatteryLevel = nil
        hasReceivedFrameAppHeartbeat = false
        stopKeepalive()
        frameAppIsCompatible = false
        stopDebugAudioCapture()
        stopRecognition()
        isStreaming = false
    }

    private func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    private func performHUDiniInstall() async {
        enum InstallFailure: Error {
            case timedOut(String)
            case device(String)
            case verification(String)
        }

        func failMessage(_ error: Error) -> String {
            switch error {
            case InstallFailure.timedOut(let detail):
                return "Timed out: \(detail)"
            case InstallFailure.device(let detail):
                return detail
            case InstallFailure.verification(let detail):
                return "Verify failed: \(detail)"
            case InstallerError.timeout(let detail):
                return "Timed out: \(detail)"
            case InstallerError.device(let detail):
                return detail
            default:
                return error.localizedDescription
            }
        }

        do {
            connectionDebugStage = "Installing app"
            installStatus = "Breaking running app…"
            resetInstallerBuffer()
            sendControlByte(Self.breakSignal)
            try? await Task.sleep(nanoseconds: 500_000_000)

            installStatus = "Waiting for REPL…"
            try await sendLuaAndAwaitMarker(
                "print('HUDINI_REPL_READY')",
                marker: "HUDINI_REPL_READY",
                timeout: 4
            )

            installStatus = "Removing old main.lua…"
            try await sendLuaAndAwaitMarker(
                "pcall(frame.file.remove,'main.lua'); print('HUDINI_REMOVE_OK')",
                marker: "HUDINI_REMOVE_OK"
            )

            installStatus = "Opening main.lua…"
            try await sendLuaAndAwaitMarker(
                "f=assert(frame.file.open('main.lua','write')); print('HUDINI_OPEN_OK')",
                marker: "HUDINI_OPEN_OK"
            )

            let script = FrameEmbeddedApp.mainLua
            let chunks = chunkLuaSource(script, chunkSize: 60)
            for (index, chunk) in chunks.enumerated() {
                installStatus = "Uploading \(index + 1)/\(chunks.count)…"
                try await sendLuaAndAwaitMarker(
                    "local ok,err=pcall(function() f:write(\(luaStringLiteral(chunk))) end); if ok then print('HUDINI_CHUNK_\(index + 1)_OK') else print('HUDINI_ERROR:'..tostring(err)) end",
                    marker: "HUDINI_CHUNK_\(index + 1)_OK",
                    timeout: 4
                )
            }

            installStatus = "Closing file…"
            try await sendLuaAndAwaitMarker(
                "f:close(); print('HUDINI_CLOSE_OK')",
                marker: "HUDINI_CLOSE_OK"
            )

            installStatus = "Verifying file…"
            let verifyResponse = try await sendLuaAndAwaitMarker(
                "local vf=assert(frame.file.open('main.lua','read')); local line1=vf:read() or ''; local line2=vf:read() or ''; vf:close(); print('HUDINI_VERIFY:'..line1..'|'..line2)",
                marker: "HUDINI_VERIFY:",
                timeout: 4
            )
            guard verifyResponse.contains("HUDINI_VERIFY:local APP_DIR = \"/hudini\"|local APP_VERSION = \"\(Self.embeddedAppVersion)\"") else {
                throw InstallFailure.verification(verifyResponse)
            }

            installStatus = "Resetting Frame app…"
            sendControlByte(Self.resetSignal)
            connectionDebugStage = "Install complete, waiting for reboot"
            statusMessage = "Verified upload. Waiting for Frame reboot…"
            installStatus = "Installed HUDini app \(Self.embeddedAppVersion). Reconnect after reboot."
        } catch {
            let message = failMessage(error)
            connectionDebugStage = "Install failed"
            statusMessage = message
            installStatus = message
        }

        isInstallingApp = false
    }

    private func sendLuaAndAwaitMarker(
        _ statement: String,
        marker: String,
        timeout: TimeInterval = 3
    ) async throws -> String {
        resetInstallerBuffer()
        sendLuaLine(statement)
        return try await waitForInstallerMarker(marker, timeout: timeout)
    }

    private func waitForInstallerMarker(_ marker: String, timeout: TimeInterval) async throws -> String {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if replTextBuffer.contains("HUDINI_ERROR:") {
                throw InstallerError.device(replTextBuffer)
            }
            if replTextBuffer.contains(marker) {
                return replTextBuffer
            }
            try? await Task.sleep(nanoseconds: 80_000_000)
        }
        throw InstallerError.timeout(marker)
    }

    private func resetInstallerBuffer() {
        replTextBuffer = ""
    }


    private func appendInstallerOutput(_ text: String) {
        replTextBuffer += text
        if !text.hasSuffix("\n") {
            replTextBuffer += "\n"
        }
        if installerOutput.count > 6000 {
            installerOutput = String(installerOutput.suffix(4000))
        }
        installerOutput.append(text)
        if !text.hasSuffix("\n") {
            installerOutput.append("\n")
        }
    }

    private enum InstallerError: Error {
        case timeout(String)
        case device(String)
    }

    private func chunkLuaSource(_ script: String, chunkSize: Int) -> [String] {
        var chunks: [String] = []
        var current = ""
        var count = 0

        for scalar in script.unicodeScalars {
            if count >= chunkSize {
                chunks.append(current)
                current = ""
                count = 0
            }
            current.unicodeScalars.append(scalar)
            count += 1
        }

        if !current.isEmpty {
            chunks.append(current)
        }
        return chunks
    }

    private func luaStringLiteral(_ text: String) -> String {
        var result = "'"
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\\":
                result += "\\\\"
            case "'":
                result += "\\'"
            case "\n":
                result += "\\n"
            case "\r":
                result += "\\r"
            case "\t":
                result += "\\t"
            default:
                if scalar.value >= 32 && scalar.value <= 126 {
                    result.append(Character(scalar))
                } else {
                    // Lua decimal escapes (`\NNN`) only accept 0..255. For any
                    // codepoint outside that range, emit the UTF-8 bytes one by
                    // one so the rebuilt string on Frame is byte-identical.
                    for byte in String(scalar).utf8 {
                        result += String(format: "\\%03d", byte)
                    }
                }
            }
        }
        result += "'"
        return result
    }

    private func handleRawPayload(_ payload: Data) {
        guard !payload.isEmpty else { return }

        if payload[0] == Self.audioDataNonFinal || payload[0] == Self.audioDataFinal {
            appendAudioPacket(payload)
            return
        }

        if payload[0] == Self.tapEvent {
            let now = Date()
            guard now.timeIntervalSince(lastTapAt) > 0.3 else {
                appendDevLog(direction: "IN", message: "TAP ignored (debounce)")
                return
            }
            lastTapAt = now
            appendDevLog(direction: "IN", message: "TAP")
            handleTapToggleListening(desiredEnabled: !isStreaming)
            return
        }

        guard let text = String(data: payload, encoding: .utf8) else { return }
        handleEvent(text)
    }

    private func handleEvent(_ text: String) {
        let parts = text.components(separatedBy: "\t")
        appendDevLog(direction: "IN", message: text)
        guard parts.first == "EVT" else {
            peripheralStatus = text
            return
        }

        let event = parts.dropFirst().first ?? ""
        switch event {
        case "BOOT", "READY":
            hasReceivedFrameAppHeartbeat = true
            if parts.count >= 4 {
                frameFirmwareVersion = parts[2]
                framePayloadLimit = Int(parts[3]) ?? framePayloadLimit
            }
            if parts.count >= 5 {
                frameAppVersion = parts[4]
                frameAppIsCompatible = Self.supportedFrameAppVersions.contains(frameAppVersion)
                if frameAppVersion == Self.embeddedAppVersion {
                    installStatus = "Installed HUDini app \(frameAppVersion)"
                } else {
                    installStatus = "Frame app version \(frameAppVersion) does not match expected \(Self.embeddedAppVersion)"
                }
            } else {
                frameAppVersion = ""
                frameAppIsCompatible = false
                installStatus = "Unknown Frame app version. Reinstall HUDini on Frame."
            }
            connectionDebugStage = frameAppIsCompatible ? "Frame app responded" : "Frame app update required"
            peripheralStatus = "\(event == "BOOT" ? "Booted" : "Ready") on \(frameFirmwareVersion)"
            statusMessage = frameAppIsCompatible
                ? "Connected to Frame"
                : "Connected, but the installed Frame app is outdated"
            if frameAppIsCompatible {
                bootstrapFrameSession(reason: "Connected to Frame")
            }
        case "STATUS":
            if parts.count >= 3 {
                peripheralStatus = parts[2]
            }
        case "MIC_ERROR":
            let detail = parts.count >= 3 ? parts[2] : "Unknown mic error"
            peripheralStatus = detail
            statusMessage = "Frame mic error"
        case "CRASH":
            let detail = parts.count >= 3 ? parts[2] : "Unknown Frame crash"
            peripheralStatus = detail
            statusMessage = "Frame app crashed"
            installStatus = "Frame crash: \(detail)"
        case "PREFS_SAVED":
            statusMessage = "Saved preferences on Frame"
        case "BATTERY":
            if parts.count >= 3, let level = Int(parts[2]) {
                frameBatteryLevel = max(0, min(100, level))
            }
        default:
            peripheralStatus = text
        }
    }

    private func handleTapToggleListening(desiredEnabled: Bool) {
        logDecision("handleTapToggleListening desiredEnabled=\(desiredEnabled) isStreaming=\(isStreaming)")
        if desiredEnabled == isStreaming { return }
        if desiredEnabled {
            startTranscribing(
                listeningLanguage: selectedLanguageCode,
                translatingTo: targetLanguageCode,
                triggeredByTap: true
            )
        } else {
            stopListening()
            statusMessage = "Stopped from Frame tap"
        }
    }
}

extension FrameBluetoothManager: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            self.handleState(central.state)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        let restored = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
        Task { @MainActor in
            guard let peripheral = restored.first else {
                self.appendDevLog(direction: "APP", message: "willRestoreState had no peripherals")
                return
            }
            self.connectedPeripheral = peripheral
            peripheral.delegate = self
            self.state = .connected(peripheral.name ?? "Frame")
            self.connectionDebugStage = "Restored after suspend"
            self.appendDevLog(direction: "APP", message: "willRestoreState recovered peripheral=\(peripheral.identifier)")
            if peripheral.state == .connected {
                peripheral.discoverServices([Self.service])
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager,
                                    didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String : Any],
                                    rssi RSSI: NSNumber) {
        Task { @MainActor in
            let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
            let deviceName = advertisedName ?? peripheral.name ?? "Frame"

            if let existingIndex = discoveredDevices.firstIndex(where: { $0.peripheral == peripheral }) {
                discoveredDevices[existingIndex] = DiscoveredDevice(name: deviceName, peripheral: peripheral, rssi: RSSI)
            } else {
                discoveredDevices.append(DiscoveredDevice(name: deviceName, peripheral: peripheral, rssi: RSSI))
            }

            discoveredDevices.sort { $0.rssi.intValue > $1.rssi.intValue }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            explicitDisconnectRequested = false
            shouldAttemptReconnect = false
            connectRetryCount = 0
            connectedPeripheral = peripheral
            peripheral.delegate = self
            state = .connected(peripheral.name ?? "Frame")
            connectionDebugStage = "Connected, discovering service"
            statusMessage = "Connected. Discovering Frame service…"
            peripheral.discoverServices([Self.service])
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor in
            let errorText = error?.localizedDescription ?? "Unknown error"
            let isEncryptionTimeout = errorText.lowercased().contains("encrypt") && errorText.lowercased().contains("time")
            let shouldRetry = isEncryptionTimeout && connectRetryCount < 1

            if shouldRetry {
                connectRetryCount += 1
                connectionDebugStage = "Connect failed, retrying"
                statusMessage = "Frame pairing timed out. Retrying…"
                appendDevLog(direction: "APP", message: "Connect retry \(connectRetryCount): \(errorText)")
                let displayName = peripheral.name ?? "Frame"
                state = .connecting(displayName)
                try? await Task.sleep(for: .milliseconds(750))
                guard !explicitDisconnectRequested else {
                    connectRetryCount = 0
                    return
                }
                central.connect(peripheral, options: nil)
                return
            }

            connectRetryCount = 0
            connectionDebugStage = "Connect failed"
            let hint = isEncryptionTimeout
                ? " If this keeps happening, unpair Frame in iOS Settings › Bluetooth and try again."
                : ""
            statusMessage = "Failed to connect: \(errorText)\(hint)"
            // Don't call resetConnectionState — it wipes discoveredDevices, forcing a rescan.
            txChar = nil
            rxChar = nil
            connectedPeripheral = nil
            state = .idle
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor in
            if let error {
                connectionDebugStage = "Disconnected with error"
                resetConnectionState(message: "Disconnected: \(error.localizedDescription)")
            } else {
                connectionDebugStage = "Disconnected"
                resetConnectionState(message: "Disconnected")
            }
            explicitDisconnectRequested = false
            shouldAttemptReconnect = false
        }
    }

    private func handleState(_ state: CBManagerState) {
        if #available(iOS 13.0, *) {
            switch CBCentralManager.authorization {
            case .denied:
                resetConnectionState(message: "Allow Bluetooth in Settings › Privacy › Bluetooth")
                return
            case .restricted:
                resetConnectionState(message: "Bluetooth access restricted")
                return
            default:
                break
            }
        }

        switch state {
        case .poweredOn:
            connectionDebugStage = "Bluetooth ready"
            statusMessage = "Bluetooth ready"
            if shouldScanWhenReady {
                startScan()
            }
        case .poweredOff:
            resetConnectionState(message: "Turn on Bluetooth to connect to Frame")
        case .unauthorized:
            resetConnectionState(message: "Bluetooth access denied")
        case .unsupported:
            resetConnectionState(message: "Bluetooth unsupported on this device")
        case .resetting:
            statusMessage = "Bluetooth resetting…"
        case .unknown:
            fallthrough
        @unknown default:
            statusMessage = waitingMessage()
        }
    }

    private func waitingMessage() -> String {
        if #available(iOS 13.0, *) {
            switch CBCentralManager.authorization {
            case .notDetermined:
                return "Waiting for Bluetooth permission…"
            default:
                break
            }
        }
        return "Waiting for Bluetooth…"
    }
}

extension FrameBluetoothManager: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        Task { @MainActor in
            if let error {
                connectionDebugStage = "Service discovery failed"
                statusMessage = "Service discovery failed: \(error.localizedDescription)"
                disconnect()
                return
            }

            connectionDebugStage = "Service found"
            statusMessage = "Frame service found. Discovering characteristics…"
            guard let services = peripheral.services else { return }
            for service in services where service.uuid == Self.service {
                peripheral.discoverCharacteristics([Self.txCharacteristic, Self.rxCharacteristic], for: service)
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didDiscoverCharacteristicsFor service: CBService,
                                error: Error?) {
        Task { @MainActor in
            if let error {
                connectionDebugStage = "Characteristic discovery failed"
                statusMessage = "Characteristic discovery failed: \(error.localizedDescription)"
                disconnect()
                return
            }

            connectionDebugStage = "Characteristics found"
            guard let chars = service.characteristics else { return }
            for char in chars {
                if char.uuid == Self.txCharacteristic {
                    txChar = char
                }
                if char.uuid == Self.rxCharacteristic {
                    rxChar = char
                    connectionDebugStage = "Enabling notifications"
                    peripheral.setNotifyValue(true, for: char)
                }
            }

            if txChar != nil && rxChar != nil {
                connectionDebugStage = "Waiting for Frame event"
                statusMessage = "Frame connected. Waiting for HUDini app heartbeat…"
                ping()
            } else {
                connectionDebugStage = "Characteristics missing"
                statusMessage = "Frame characteristics missing"
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didUpdateNotificationStateFor characteristic: CBCharacteristic,
                                error: Error?) {
        Task { @MainActor in
            if let error {
                connectionDebugStage = "Notification setup failed"
                statusMessage = "Notification setup failed: \(error.localizedDescription)"
                return
            }

            if characteristic.uuid == Self.rxCharacteristic {
                connectionDebugStage = characteristic.isNotifying ? "Notifications enabled" : "Notifications disabled"
                statusMessage = characteristic.isNotifying
                    ? "Notifications enabled. Waiting for Frame app events…"
                    : "Frame notifications were disabled"
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        Task { @MainActor in
            if let error {
                connectionDebugStage = "Receive failed"
                statusMessage = "Receive error: \(error.localizedDescription)"
                return
            }

            guard let data = characteristic.value else { return }
            if characteristic.uuid != Self.rxCharacteristic { return }

            if let first = data.first, first == Self.rawPrefix {
                handleRawPayload(Data(data.dropFirst()))
                return
            }

            if let first = data.first, (first == Self.audioDataNonFinal || first == Self.audioDataFinal) {
                handleRawPayload(data)
                return
            }

            if let first = data.first, first == UInt8(ascii: "E") {
                handleRawPayload(data)
                return
            }

            if let text = String(data: data, encoding: .utf8) {
                appendInstallerOutput(text)
                peripheralStatus = text
            }
        }
    }
}

// MARK: - HUDDeviceManager Conformance

extension FrameBluetoothManager: HUDDeviceManager {
    var kind: HUDDeviceKind { .frame }

    func startTranscribing(listeningLanguage: String, translatingTo targetLanguage: String) {
        startTranscribing(listeningLanguage: listeningLanguage, translatingTo: targetLanguage, triggeredByTap: false)
    }

    func sendHUDText(_ text: String, isPartial: Bool) {
        sendHUDTextToFrame(text, isPartial: isPartial, updateStatus: false)
    }

    func clearHUDText() {
        clearFrameDisplay()
    }

    func sendSuggestion(phonetic: String, english: String) {
        sendSuggestionToFrame(phonetic: phonetic, english: english)
    }

    func clearSuggestion() {
        clearSuggestionOnFrame()
    }
}
