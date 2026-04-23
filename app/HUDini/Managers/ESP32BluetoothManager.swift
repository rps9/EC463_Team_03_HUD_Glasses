import Foundation
import Combine
import CoreBluetooth
import AVFoundation
import Speech
import SwiftUI

@MainActor
final class ESP32BluetoothManager: NSObject, ObservableObject {
    private static let service = CBUUID(string: "9A1D0001-7E54-4B1A-8B64-3A8F2C1D0001")
    private static let audioDataCharacteristic = CBUUID(string: "9A1D0002-7E54-4B1A-8B64-3A8F2C1D0001")
    private static let controlCharacteristic = CBUUID(string: "9A1D0003-7E54-4B1A-8B64-3A8F2C1D0001")
    private static let statusCharacteristic = CBUUID(string: "9A1D0004-7E54-4B1A-8B64-3A8F2C1D0001")

    private static let streamSampleRate: Double = 8_000
    private static let singleShotTextLimit = 160
    private static let chunkPayloadSize = 150

    @Published private(set) var state: FrameBluetoothManager.ConnectionState = .idle
    @Published private(set) var discoveredDevices: [FrameBluetoothManager.DiscoveredDevice] = []
    @Published private(set) var statusMessage: String = "Checking Bluetooth…"
    @Published private(set) var liveTranscript: String = ""
    @Published private(set) var renderedText: String = ""
    @Published private(set) var isStreaming: Bool = false
    @Published private(set) var selectedLanguageCode: String = TranslationLanguages.defaultListeningLanguageCode
    @Published private(set) var targetLanguageCode: String = "en"

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
    private var lastSentDisplayText: String = ""
    private var lastSentSuggestion: String = ""

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
        central = CBCentralManager(delegate: self, queue: nil)
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
        Task { @MainActor in
            let auth = await requestSpeechAuthorization()
            guard auth == .authorized else {
                statusMessage = "Allow Speech Recognition in Settings"
                return
            }
            guard startRecognition() else { return }
            writeControl("START", char: controlChar)
            isStreaming = true
            statusMessage = "Streaming and transcribing…"
        }
    }

    func stopListening() {
        if let controlChar {
            writeControl("STOP", char: controlChar)
        }
        stopRecognition()
        isStreaming = false
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
            Task { @MainActor in
                if let result {
                    let transcript = result.bestTranscription.formattedString
                    if !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        self.liveTranscript = transcript
                        self.handleTranscriptUpdate(text: transcript, isFinal: result.isFinal)
                    }
                }
                if let error, self.isStreaming {
                    self.statusMessage = "Recognition ended: \(error.localizedDescription)"
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
        guard !trimmed.isEmpty, trimmed != lastSentDisplayText else { return }
        lastSentDisplayText = trimmed
        writeDisplayText(trimmed)
    }

    func clearHUDText() {
        lastSentDisplayText = ""
        lastSentSuggestion = ""
        writeDisplayText(" ")
    }

    func sendSuggestion(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != lastSentSuggestion else { return }
        lastSentSuggestion = trimmed
        writeDisplayText(trimmed)
    }

    func clearSuggestion() {
        lastSentSuggestion = ""
    }

    private func writeDisplayText(_ text: String) {
        guard let controlChar, let peripheral = connectedPeripheral else { return }
        let utf8 = Array(text.utf8)
        if utf8.count <= Self.singleShotTextLimit - 5 {
            writeControl("TEXT:\(text)", char: controlChar)
            return
        }
        writeControl("TEXT_BEGIN", char: controlChar)
        var index = 0
        while index < utf8.count {
            let end = min(index + Self.chunkPayloadSize, utf8.count)
            let slice = Array(utf8[index..<end])
            if let chunkStr = String(bytes: slice, encoding: .utf8) {
                writeControl("TEXT_CHUNK:\(chunkStr)", char: controlChar)
            }
            index = end
        }
        writeControl("TEXT_END", char: controlChar)
        _ = peripheral
    }

    private func writeControl(_ command: String, char: CBCharacteristic) {
        guard let peripheral = connectedPeripheral, let data = command.data(using: .utf8) else { return }
        let writeType: CBCharacteristicWriteType = char.properties.contains(.write) ? .withResponse : .withoutResponse
        peripheral.writeValue(data, for: char, type: writeType)
    }

    // MARK: - Audio

    private func appendAudioPacket(_ data: Data) {
        guard data.count >= 6 else { return }
        let version = data[0]
        guard version == 1 else { return }
        let sampleCount = Int(UInt16(data[4]) | (UInt16(data[5]) << 8))
        let payloadBytes = sampleCount * MemoryLayout<Int16>.size
        guard data.count >= 6 + payloadBytes, payloadBytes > 0 else { return }
        let payload = data.subdata(in: 6 ..< 6 + payloadBytes)
        appendPCM16(payload)
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

    // MARK: - Lifecycle

    func warmUp() {
        Task { _ = try? await translationClient.translate(text: "hello", source: "en", target: "es") }
    }

    func handleScenePhaseChange(_ phase: ScenePhase) {
        switch phase {
        case .background:
            if isStreaming { stopListening() }
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
        guard error == nil, let value = characteristic.value else { return }
        let uuid = characteristic.uuid
        Task { @MainActor in
            if uuid == Self.audioDataCharacteristic {
                self.appendAudioPacket(value)
            } else if uuid == Self.statusCharacteristic {
                if let text = String(data: value, encoding: .utf8) {
                    self.statusMessage = "ESP32: \(text)"
                }
            }
        }
    }
}
