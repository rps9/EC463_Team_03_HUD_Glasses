import Foundation
import Combine
import CoreBluetooth
import AVFoundation
import Speech

struct FrameDisplayPreferences: Equatable {
    var brightness: Int = 0
    var showsLivePartials: Bool = true
    var captionPosition: CaptionPosition = .bottom
    var layoutMode: LayoutMode = .focus
    var transcriptionColor: PaletteColor = .grey
    var translationColor: PaletteColor = .skyBlue

    enum CaptionPosition: String, CaseIterable, Identifiable {
        case top
        case middle
        case bottom

        var id: String { rawValue }
        var title: String { rawValue.capitalized }
    }

    enum LayoutMode: String, CaseIterable, Identifiable {
        case focus
        case split
        case compact

        var id: String { rawValue }
        var title: String { rawValue.capitalized }
    }

    enum PaletteColor: String, CaseIterable, Identifiable {
        case white = "WHITE"
        case grey = "GREY"
        case red = "RED"
        case pink = "PINK"
        case brown = "BROWN"
        case orange = "ORANGE"
        case yellow = "YELLOW"
        case green = "GREEN"
        case lightGreen = "LIGHTGREEN"
        case nightBlue = "NIGHTBLUE"
        case seaBlue = "SEABLUE"
        case skyBlue = "SKYBLUE"
        case cloudBlue = "CLOUDBLUE"

        var id: String { rawValue }

        var title: String {
            switch self {
            case .white: return "White"
            case .grey: return "Grey"
            case .red: return "Red"
            case .pink: return "Pink"
            case .brown: return "Brown"
            case .orange: return "Orange"
            case .yellow: return "Yellow"
            case .green: return "Green"
            case .lightGreen: return "Light Green"
            case .nightBlue: return "Night Blue"
            case .seaBlue: return "Sea Blue"
            case .skyBlue: return "Sky Blue"
            case .cloudBlue: return "Cloud Blue"
            }
        }
    }

    func commandPayload() -> String {
        [
            "brightness=\(brightness)",
            "partials=\(showsLivePartials ? 1 : 0)",
            "position=\(captionPosition.rawValue)",
            "layout=\(layoutMode.rawValue)",
            "transcription_color=\(transcriptionColor.rawValue)",
            "translation_color=\(translationColor.rawValue)"
        ].joined(separator: ";")
    }
}

struct FrameSuggestionDisplay: Equatable {
    var text: String
    var phonetic: String = ""

    var commandField: String {
        let left = text.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "~", with: "-")
        let right = phonetic.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "~", with: "-")
        return "\(left)~\(right)"
    }
}

enum FrameConversationMode: String, CaseIterable, Identifiable {
    case translation
    case transcription
    case meeting
    case pronunciation

    var id: String { rawValue }

    var title: String {
        switch self {
        case .translation: return "Translation"
        case .transcription: return "Transcription"
        case .meeting: return "Meeting"
        case .pronunciation: return "Pronunciation"
        }
    }
}

@MainActor
final class FrameBluetoothManager: NSObject, ObservableObject {
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
    private static let audioPacketType: UInt8 = 0x20
    private static let streamSampleRate: Double = 8_000
    private static let streamBitDepth: Int = 16
    private static let recognitionSampleRate: Double = 16_000

    @Published private(set) var state: ConnectionState = .idle
    @Published private(set) var discoveredDevices: [DiscoveredDevice] = []
    @Published private(set) var statusMessage: String = "Checking Bluetooth…"
    @Published private(set) var peripheralStatus: String = ""
    @Published private(set) var liveTranscript: String = ""
    @Published private(set) var renderedText: String = ""
    @Published private(set) var isStreaming: Bool = false
    @Published private(set) var frameFirmwareVersion: String = ""
    @Published private(set) var framePayloadLimit: Int = 0
    @Published private(set) var selectedLanguageCode: String = "en"
    @Published private(set) var targetLanguageCode: String = "en"
    @Published private(set) var connectionDebugStage: String = "Idle"
    @Published private(set) var isInstallingApp: Bool = false
    @Published private(set) var installStatus: String = "Not installed from phone yet"
    @Published private(set) var installerOutput: String = ""
    @Published var preferences: FrameDisplayPreferences = .init()
    @Published var selectedMode: FrameConversationMode = .translation

    private var central: CBCentralManager!
    private var connectedPeripheral: CBPeripheral?
    private var txChar: CBCharacteristic?
    private var rxChar: CBCharacteristic?
    private var shouldScanWhenReady = false

    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var recognizer = SFSpeechRecognizer(locale: Locale.current)
    private let translationClient = HUDTranslationClient()
    private var translationTask: Task<Void, Never>?
    private var latestTranslationRequestID = UUID()
    private var lastPartialTranslationAt: Date = .distantPast
    private let partialTranslationInterval: TimeInterval = 0.6
    private var expectedPacketSeq: UInt16?
    private var lastSentFinalCaption: String = ""
    private var lastSentPartialCaption: String = ""
    private var lastSentTranscript: String = ""
    private var lastSentSuggestions: [FrameSuggestionDisplay] = []
    private var replTextBuffer: String = ""
    private var micStateGeneration: UInt64 = 0
    private var micTransitionInFlight = false
    private lazy var streamFormat: AVAudioFormat = {
        AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Self.streamSampleRate,
            channels: 1,
            interleaved: false
        )!
    }()

    private lazy var recognitionFormat: AVAudioFormat = {
        AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Self.recognitionSampleRate,
            channels: 1,
            interleaved: false
        )!
    }()

    override init() {
        super.init()
        let preferred = Locale.current.language.languageCode?.identifier ?? "en"
        if TranslationLanguages.supported.contains(where: { $0.code == preferred }) {
            selectedLanguageCode = preferred
        }
        recognizer = SFSpeechRecognizer(locale: Locale(identifier: selectedLanguageCode))
        central = CBCentralManager(delegate: self, queue: nil)
        handleState(central.state)
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
        stopScanning()
        state = .connecting(device.name)
        connectionDebugStage = "Connect requested"
        statusMessage = "Connecting to \(device.name)…"
        central.connect(device.peripheral, options: nil)
    }

    func disconnect() {
        stopAudioStream(sendCommand: true)
        guard let peripheral = connectedPeripheral else { return }
        central.cancelPeripheralConnection(peripheral)
        resetConnectionState(message: "Disconnected")
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

    func setMode(_ mode: FrameConversationMode) {
        selectedMode = mode
        sendRawCommand(["SET_MODE", mode.rawValue], preferredType: .withResponse)
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
        recognizer = newRecognizer

        if isStreaming {
            stopRecognition()
            if startRecognition() {
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
        setMode(.translation)
        startAudioStream(triggeredByTap: triggeredByTap)
    }

    func startAudioStream(triggeredByTap: Bool = false) {
        guard connectedPeripheral != nil, txChar != nil else {
            statusMessage = "Connect to Frame first"
            return
        }
        guard !isStreaming, !micTransitionInFlight else { return }

        statusMessage = "Requesting speech permission…"
        lastPartialTranslationAt = .distantPast
        expectedPacketSeq = nil
        micStateGeneration &+= 1
        micTransitionInFlight = true
        let generation = micStateGeneration

        Task { @MainActor in
            let authorization = await requestSpeechAuthorization()
            guard generation == self.micStateGeneration else { return }
            guard authorization == .authorized else {
                self.micTransitionInFlight = false
                self.setStreamingState(false)
                self.syncFrameMicState(false)
                statusMessage = "Allow Speech Recognition in Settings"
                return
            }

            guard startRecognition() else {
                self.micTransitionInFlight = false
                self.setStreamingState(false)
                self.syncFrameMicState(false)
                return
            }
            guard generation == self.micStateGeneration else { return }

            syncFrameMicState(true)
            sendRawCommand(["MIC_START"], preferredType: .withResponse)
            sendRawCommand(["SET_STATE", "listening"], preferredType: .withResponse)
            setStreamingState(true)
            micTransitionInFlight = false
            statusMessage = "Streaming audio from Frame…"
        }
    }

    func stopAudioStream(sendCommand: Bool = true) {
        micStateGeneration &+= 1
        micTransitionInFlight = false
        if sendCommand {
            syncFrameMicState(false)
            sendRawCommand(["MIC_STOP"], preferredType: .withResponse)
            sendRawCommand(["SET_STATE", "idle"], preferredType: .withResponse)
        }
        stopRecognition()
        setStreamingState(false)
        statusMessage = "Stream stopped"
    }

    func clearTranscript() {
        liveTranscript = ""
        renderedText = ""
        lastSentFinalCaption = ""
        lastSentPartialCaption = ""
        lastSentTranscript = ""
        cancelTranslation()
        clearFrameDisplay()
    }

    func clearFrameDisplay() {
        lastSentFinalCaption = ""
        lastSentPartialCaption = ""
        lastSentTranscript = ""
        sendRawCommand(["SHOW_TRANSCRIPT", ""])
        sendRawCommand(["CLEAR_CAPTION"])
    }

    private func setStreamingState(_ enabled: Bool) {
        isStreaming = enabled
    }

    private func syncFrameMicState(_ enabled: Bool) {
        sendRawCommand(["SET_MIC", enabled ? "1" : "0"], preferredType: .withResponse)
    }

    func sendHUDTextToFrame(_ text: String, isPartial: Bool = false, updateStatus: Bool = false) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if isPartial {
            guard trimmed != lastSentPartialCaption else { return }
            lastSentPartialCaption = trimmed
            sendRawCommand(["SHOW_CAPTION", "partial", trimmed])
        } else {
            guard trimmed != lastSentFinalCaption else { return }
            lastSentFinalCaption = trimmed
            lastSentPartialCaption = ""
            sendRawCommand(["SHOW_CAPTION", "final", trimmed])
        }

        if updateStatus {
            statusMessage = "Updated Frame display"
        }
    }

    func sendSuggestions(_ suggestions: [FrameSuggestionDisplay]) {
        let cleaned = suggestions
            .map { FrameSuggestionDisplay(text: $0.text.trimmingCharacters(in: .whitespacesAndNewlines), phonetic: $0.phonetic.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { !$0.text.isEmpty }

        guard cleaned != lastSentSuggestions else { return }
        lastSentSuggestions = cleaned

        guard !cleaned.isEmpty else {
            sendRawCommand(["CLEAR_SUGGESTIONS"])
            return
        }

        var fields = ["SHOW_SUGGESTIONS"]
        fields.append(contentsOf: cleaned.prefix(3).map(\.commandField))
        sendRawCommand(fields)
    }

    func cycleSuggestions() {
        sendRawCommand(["CYCLE_SUGGESTIONS"])
    }

    private func sendControlByte(_ value: UInt8) {
        guard let peripheral = connectedPeripheral, let txChar else { return }
        peripheral.writeValue(Data([value]), for: txChar, type: txWriteType)
    }

    private func sendLuaLine(_ statement: String) {
        guard let peripheral = connectedPeripheral, let txChar else { return }
        guard let data = "\(statement)\n".data(using: .utf8) else { return }
        peripheral.writeValue(data, for: txChar, type: txWriteType)
    }

    private func sendRawCommand(_ fields: [String], preferredType: CBCharacteristicWriteType? = nil) {
        guard let peripheral = connectedPeripheral, let txChar else { return }
        let payload = fields
            .map { $0.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ") }
            .joined(separator: "\t")

        guard let textData = payload.data(using: .utf8) else { return }
        var data = Data([Self.rawPrefix])
        data.append(textData)
        let writeType = supportedWriteType(preferred: preferredType, characteristic: txChar)
        peripheral.writeValue(data, for: txChar, type: writeType)
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
        guard let recognizer, recognizer.isAvailable else {
            statusMessage = "Speech recognizer unavailable"
            return false
        }

        recognitionTask?.cancel()
        recognitionTask = nil

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        recognitionRequest = request

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let result {
                self.liveTranscript = result.bestTranscription.formattedString
                self.handleTranscriptUpdate(text: result.bestTranscription.formattedString, isFinal: result.isFinal)
                if result.isFinal {
                    self.statusMessage = "Finalized segment"
                }
            }

            if let error {
                self.statusMessage = "Recognition error: \(error.localizedDescription)"
                self.stopAudioStream(sendCommand: true)
            }
        }
        return true
    }

    private func stopRecognition() {
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        expectedPacketSeq = nil
        lastPartialTranslationAt = .distantPast
        cancelTranslation()
    }

    private func sendTranscriptToFrame(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != lastSentTranscript else { return }
        lastSentTranscript = trimmed
        sendRawCommand(["SHOW_TRANSCRIPT", trimmed])
    }

    private func handleTranscriptUpdate(text: String, isFinal: Bool) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return
        }

        sendTranscriptToFrame(trimmed)

        if shouldBypassTranslation(source: selectedLanguageCode, target: targetLanguageCode) {
            renderedText = trimmed
            sendHUDTextToFrame(trimmed, isPartial: !isFinal)
            sendRawCommand(["SET_STATE", isFinal ? "listening" : "translating"])
            return
        }

        if !isFinal {
            let now = Date()
            guard now.timeIntervalSince(lastPartialTranslationAt) >= partialTranslationInterval else {
                return
            }
            lastPartialTranslationAt = now
        }

        sendRawCommand(["SET_STATE", "translating"])
        let requestID = UUID()
        latestTranslationRequestID = requestID
        translationTask?.cancel()
        translationTask = Task { [weak self] in
            guard let self else { return }
            do {
                let translated = try await translationClient.translate(
                    text: trimmed,
                    source: selectedLanguageCode,
                    target: targetLanguageCode
                )
                guard !Task.isCancelled else { return }
                guard latestTranslationRequestID == requestID else { return }

                renderedText = translated
                sendHUDTextToFrame(translated, isPartial: !isFinal)
                sendRawCommand(["SET_STATE", isFinal ? "listening" : "translating"])
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                guard latestTranslationRequestID == requestID else { return }
                statusMessage = "Translation error: \(error.localizedDescription)"
                sendRawCommand(["SET_STATE", "error"])
            }
        }
    }

    private func cancelTranslation() {
        latestTranslationRequestID = UUID()
        translationTask?.cancel()
        translationTask = nil
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
        guard payload.count >= 3 else { return }
        let type = payload[0]
        guard type == Self.audioPacketType else { return }

        let packetSeq = UInt16(payload[1]) | (UInt16(payload[2]) << 8)
        let audioPayload = payload.subdata(in: 3 ..< payload.count)

        if let expected = expectedPacketSeq {
            let missing = Int(packetSeq &- expected)
            if missing > 0 && missing < 64 {
                let bytesPerSample = max(1, Self.streamBitDepth / 8)
                let silenceSamples = (audioPayload.count / bytesPerSample) * missing
                appendSilence(samples: silenceSamples)
            }
        }
        expectedPacketSeq = packetSeq &+ 1
        if Self.streamBitDepth == 8 {
            appendPCM8(audioPayload)
        } else {
            appendPCM16(audioPayload)
        }
    }

    private func appendPCM16(_ payload: Data) {
        let sampleCount = payload.count / MemoryLayout<Int16>.size
        guard sampleCount > 0 else { return }
        let recognitionPayload = upsampleForRecognitionIfNeeded(payload)
        let recognitionSampleCount = recognitionPayload.count / MemoryLayout<Int16>.size
        if let request = recognitionRequest,
           let buffer = AVAudioPCMBuffer(pcmFormat: recognitionFormat, frameCapacity: AVAudioFrameCount(recognitionSampleCount)),
           let dst = buffer.int16ChannelData?[0] {
            recognitionPayload.withUnsafeBytes { srcRaw in
                guard let src = srcRaw.baseAddress else { return }
                memcpy(dst, src, recognitionPayload.count)
            }

            buffer.frameLength = AVAudioFrameCount(recognitionSampleCount)
            request.append(buffer)
        }
    }

    private func appendPCM8(_ payload: Data) {
        let sampleCount = payload.count
        guard sampleCount > 0 else { return }

        var converted = Data(count: sampleCount * MemoryLayout<Int16>.size)
        converted.withUnsafeMutableBytes { dstRaw in
            guard let dst = dstRaw.bindMemory(to: Int16.self).baseAddress else { return }
            payload.withUnsafeBytes { srcRaw in
                guard let src = srcRaw.bindMemory(to: Int8.self).baseAddress else { return }
                for index in 0 ..< sampleCount {
                    dst[index] = Int16(src[index]) << 8
                }
            }
        }

        appendPCM16(converted)
    }

    private func appendSilence(samples: Int) {
        guard samples > 0 else { return }
        guard let request = recognitionRequest else { return }
        let recognitionSamples = max(samples, Int(Double(samples) * (Self.recognitionSampleRate / Self.streamSampleRate)))
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: recognitionFormat,
            frameCapacity: AVAudioFrameCount(recognitionSamples)
        ) else { return }
        guard let dst = buffer.int16ChannelData?[0] else { return }

        memset(dst, 0, recognitionSamples * MemoryLayout<Int16>.size)
        buffer.frameLength = AVAudioFrameCount(recognitionSamples)
        request.append(buffer)
    }

    private func upsampleForRecognitionIfNeeded(_ payload: Data) -> Data {
        guard Self.streamSampleRate < Self.recognitionSampleRate else { return payload }

        let inputSampleCount = payload.count / 2
        guard inputSampleCount > 0 else { return payload }
        if inputSampleCount == 1 {
            return payload + payload
        }

        var output = Data(capacity: inputSampleCount * 4)
        for index in 0 ..< inputSampleCount {
            let current = sampleAt(index, in: payload)
            appendLittleEndian(current, to: &output)

            let next = index + 1 < inputSampleCount ? sampleAt(index + 1, in: payload) : current
            let midpoint = Int16((Int32(current) + Int32(next)) / 2)
            appendLittleEndian(midpoint, to: &output)
        }
        return output
    }

    private func sampleAt(_ index: Int, in payload: Data) -> Int16 {
        let offset = index * 2
        let low = UInt16(payload[offset])
        let high = UInt16(payload[offset + 1]) << 8
        return Int16(bitPattern: low | high)
    }

    private func appendLittleEndian(_ value: Int16, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { bytes in
            data.append(contentsOf: bytes)
        }
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
        micStateGeneration &+= 1
        txChar = nil
        rxChar = nil
        connectedPeripheral = nil
        discoveredDevices = []
        state = .idle
        connectionDebugStage = message
        statusMessage = message
        peripheralStatus = ""
        frameFirmwareVersion = ""
        framePayloadLimit = 0
        stopRecognition()
        isStreaming = false
        lastSentFinalCaption = ""
        lastSentPartialCaption = ""
        lastSentSuggestions = []
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
            let chunks = chunkLuaSource(script, chunkSize: 48)
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
                "local vf=assert(frame.file.open('main.lua','read')); local line=vf:read() or ''; vf:close(); print('HUDINI_VERIFY:'..line)",
                marker: "HUDINI_VERIFY:",
                timeout: 4
            )
            guard verifyResponse.contains("HUDINI_VERIFY:local APP_DIR = \"/hudini\"") else {
                throw InstallFailure.verification(verifyResponse)
            }

            installStatus = "Resetting Frame app…"
            sendControlByte(Self.resetSignal)
            connectionDebugStage = "Install complete, waiting for reboot"
            statusMessage = "Verified upload. Waiting for Frame reboot…"
            installStatus = "Verified and reset sent. Reconnect after reboot."
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
                if scalar.value < 32 || scalar.value > 126 {
                    result += String(format: "\\%03d", scalar.value)
                } else {
                    result.append(Character(scalar))
                }
            }
        }
        result += "'"
        return result
    }

    private func handleRawPayload(_ payload: Data) {
        guard !payload.isEmpty else { return }

        if payload[0] == Self.audioPacketType {
            appendAudioPacket(payload)
            return
        }

        guard let text = String(data: payload, encoding: .utf8) else { return }
        handleEvent(text)
    }

    private func handleEvent(_ text: String) {
        let parts = text.components(separatedBy: "\t")
        guard parts.first == "EVT" else {
            peripheralStatus = text
            return
        }

        let event = parts.dropFirst().first ?? ""
        switch event {
        case "BOOT", "READY":
            if parts.count >= 4 {
                frameFirmwareVersion = parts[2]
                framePayloadLimit = Int(parts[3]) ?? framePayloadLimit
            }
            connectionDebugStage = "Frame app responded"
            peripheralStatus = "\(event == "BOOT" ? "Booted" : "Ready") on \(frameFirmwareVersion)"
            statusMessage = "Connected to Frame"
            syncFrameMicState(isStreaming)
            sendRawCommand(["SET_STATE", "idle"])
        case "STATUS":
            if parts.count >= 3 {
                peripheralStatus = parts[2]
            }
        case "MODE":
            if parts.count >= 3, let mode = FrameConversationMode(rawValue: parts[2]) {
                selectedMode = mode
            }
        case "PREFS_SAVED":
            statusMessage = "Saved preferences on Frame"
        case "SUGGESTION_INDEX":
            if parts.count >= 3 {
                peripheralStatus = "Showing suggestion \(parts[2])"
            }
        case "TAP":
            if parts.count >= 3 {
                let action = parts[2]
                peripheralStatus = "Tap gesture: \(action)"
                if action == "toggle_listening" {
                    let desiredEnabled = parts.count >= 4 ? parts[3] == "1" : !isStreaming
                    handleTapToggleListening(desiredEnabled: desiredEnabled)
                }
            }
        default:
            peripheralStatus = text
        }
    }

    private func handleTapToggleListening(desiredEnabled: Bool) {
        guard !micTransitionInFlight else { return }
        if desiredEnabled == isStreaming { return }
        if desiredEnabled {
            startTranscribing(
                listeningLanguage: selectedLanguageCode,
                translatingTo: targetLanguageCode,
                triggeredByTap: true
            )
            statusMessage = "Started from Frame tap"
        } else {
            stopAudioStream()
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
            connectionDebugStage = "Connect failed"
            let message = "Failed to connect: \(error?.localizedDescription ?? "Unknown error")"
            resetConnectionState(message: message)
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
                statusMessage = "Frame connected. Waiting for app heartbeat…"
                ping()
                applyPreferences()
                setMode(selectedMode)
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

            if let first = data.first, first == Self.audioPacketType {
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
