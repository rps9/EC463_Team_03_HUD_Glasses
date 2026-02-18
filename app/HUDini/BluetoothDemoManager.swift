import Foundation
import CoreBluetooth
import AVFoundation
import Speech

@MainActor
final class BluetoothDemoManager: NSObject, ObservableObject {
    struct DiscoveredDevice: Identifiable {
        let id = UUID()
        let name: String
        let peripheral: CBPeripheral
    }

    enum ConnectionState: Equatable {
        case idle
        case scanning
        case connecting(String)
        case connected(String)
    }

    // Custom HUDini BLE audio service.
    private static let audioService = CBUUID(string: "9A1D0001-7E54-4B1A-8B64-3A8F2C1D0001")
    private static let audioDataCharacteristic = CBUUID(string: "9A1D0002-7E54-4B1A-8B64-3A8F2C1D0001") // notify
    private static let controlCharacteristic = CBUUID(string: "9A1D0003-7E54-4B1A-8B64-3A8F2C1D0001")   // write
    private static let statusCharacteristic = CBUUID(string: "9A1D0004-7E54-4B1A-8B64-3A8F2C1D0001")    // read/notify

    private static let streamSampleRate: Double = 16_000

    @Published private(set) var state: ConnectionState = .idle
    @Published private(set) var discoveredDevices: [DiscoveredDevice] = []
    @Published private(set) var statusMessage: String = "Checking Bluetooth…"
    @Published private(set) var liveTranscript: String = ""
    @Published private(set) var peripheralStatus: String = ""
    @Published private(set) var isStreaming: Bool = false

    private var central: CBCentralManager!
    private var connectedPeripheral: CBPeripheral?
    private var controlChar: CBCharacteristic?
    private var audioDataChar: CBCharacteristic?
    private var shouldScanWhenReady: Bool = false

    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var recognizer = SFSpeechRecognizer(locale: Locale.current)

    private lazy var streamFormat: AVAudioFormat = {
        AVAudioFormat(commonFormat: .pcmFormatInt16,
                      sampleRate: Self.streamSampleRate,
                      channels: 1,
                      interleaved: false)!
    }()

    override init() {
        super.init()
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
        statusMessage = "Connecting to \(device.name)…"
        central.connect(device.peripheral, options: nil)
    }

    func disconnect() {
        stopAudioStream(sendStopCommand: true)
        guard let peripheral = connectedPeripheral else { return }
        central.cancelPeripheralConnection(peripheral)
        resetConnectionState(message: "Disconnected")
    }

    func clearTranscript() {
        liveTranscript = ""
    }

    func startAudioStream() {
        guard let peripheral = connectedPeripheral, let controlChar else {
            statusMessage = "Connect to a device first"
            return
        }
        guard !isStreaming else { return }

        statusMessage = "Requesting speech permission…"
        Task { @MainActor in
            let authorization = await requestSpeechAuthorization()
            guard authorization == .authorized else {
                statusMessage = "Allow Speech Recognition in Settings"
                return
            }

            guard startRecognition() else { return }

            writeControl("START", on: peripheral, char: controlChar)
            isStreaming = true
            statusMessage = "Streaming and transcribing…"
        }
    }

    func stopAudioStream(sendStopCommand: Bool = true) {
        guard let peripheral = connectedPeripheral, let controlChar else {
            stopRecognition()
            isStreaming = false
            return
        }

        if sendStopCommand {
            writeControl("STOP", on: peripheral, char: controlChar)
        }
        stopRecognition()
        isStreaming = false
        statusMessage = "Stream stopped"
    }

    private func writeControl(_ command: String, on peripheral: CBPeripheral, char: CBCharacteristic) {
        guard let data = command.data(using: .utf8) else { return }
        let writeType: CBCharacteristicWriteType = char.properties.contains(.write) ? .withResponse : .withoutResponse
        peripheral.writeValue(data, for: char, type: writeType)
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
        recognitionRequest = request

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            if let result {
                self.liveTranscript = result.bestTranscription.formattedString
                if result.isFinal {
                    self.statusMessage = "Finalized segment"
                }
            }
            if let error {
                self.statusMessage = "Recognition error: \(error.localizedDescription)"
                self.stopAudioStream(sendStopCommand: true)
            }
        }
        return true
    }

    private func stopRecognition() {
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
    }

    private func appendAudioPacket(_ data: Data) {
        guard data.count >= 6 else { return }

        let version = data[0]
        guard version == 1 else { return }

        let sampleCount = Int(UInt16(data[4]) | (UInt16(data[5]) << 8))
        let payloadBytes = sampleCount * MemoryLayout<Int16>.size
        let expectedLength = 6 + payloadBytes
        guard data.count >= expectedLength, payloadBytes > 0 else { return }

        let payload = data.subdata(in: 6 ..< expectedLength)
        appendPCM16(payload)
    }

    private func appendPCM16(_ payload: Data) {
        guard let request = recognitionRequest else { return }

        let sampleCount = payload.count / MemoryLayout<Int16>.size
        guard sampleCount > 0 else { return }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: streamFormat, frameCapacity: AVAudioFrameCount(sampleCount)) else { return }
        guard let dst = buffer.int16ChannelData?[0] else { return }

        payload.withUnsafeBytes { srcRaw in
            guard let src = srcRaw.baseAddress else { return }
            memcpy(dst, src, payload.count)
        }

        buffer.frameLength = AVAudioFrameCount(sampleCount)
        request.append(buffer)
    }

    private func resetConnectionState(message: String) {
        controlChar = nil
        audioDataChar = nil
        connectedPeripheral = nil
        discoveredDevices = []
        state = .idle
        statusMessage = message
        peripheralStatus = ""
        stopRecognition()
        isStreaming = false
    }

    private func startScan() {
        shouldScanWhenReady = false
        discoveredDevices = []
        central.scanForPeripherals(withServices: [Self.audioService], options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        state = .scanning
        statusMessage = "Scanning for HUDini mic devices…"
    }

    private func requestSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }
}

extension BluetoothDemoManager: CBCentralManagerDelegate {
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
            let name = peripheral.name ?? "Unnamed"
            if discoveredDevices.contains(where: { $0.peripheral == peripheral }) { return }
            discoveredDevices.append(DiscoveredDevice(name: name, peripheral: peripheral))
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            connectedPeripheral = peripheral
            peripheral.delegate = self
            state = .connected(peripheral.name ?? "Device")
            statusMessage = "Connected. Discovering audio service…"
            peripheral.discoverServices([Self.audioService])
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor in
            statusMessage = "Failed to connect: \(error?.localizedDescription ?? "Unknown error")"
            resetConnectionState(message: statusMessage)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor in
            if let error {
                resetConnectionState(message: "Disconnected: \(error.localizedDescription)")
            } else {
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
            statusMessage = "Bluetooth ready"
            if shouldScanWhenReady {
                startScan()
            }
        case .poweredOff:
            resetConnectionState(message: "Turn on Bluetooth to start")
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

extension BluetoothDemoManager: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        Task { @MainActor in
            if let error {
                statusMessage = "Service discovery failed: \(error.localizedDescription)"
                disconnect()
                return
            }
            guard let services = peripheral.services else { return }
            for service in services where service.uuid == Self.audioService {
                peripheral.discoverCharacteristics([Self.audioDataCharacteristic,
                                                    Self.controlCharacteristic,
                                                    Self.statusCharacteristic],
                                                   for: service)
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral,
                                didDiscoverCharacteristicsFor service: CBService,
                                error: Error?) {
        Task { @MainActor in
            if let error {
                statusMessage = "Characteristic discovery failed: \(error.localizedDescription)"
                disconnect()
                return
            }
            guard let chars = service.characteristics else { return }
            for char in chars {
                if char.uuid == Self.controlCharacteristic {
                    controlChar = char
                }
                if char.uuid == Self.audioDataCharacteristic {
                    audioDataChar = char
                    peripheral.setNotifyValue(true, for: char)
                }
                if char.uuid == Self.statusCharacteristic {
                    peripheral.setNotifyValue(true, for: char)
                    peripheral.readValue(for: char)
                }
            }

            if controlChar != nil && audioDataChar != nil {
                statusMessage = "Ready. Tap Start Transcription"
            } else {
                statusMessage = "Required BLE characteristics missing"
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        Task { @MainActor in
            if let error {
                statusMessage = "Receive error: \(error.localizedDescription)"
                return
            }
            guard let data = characteristic.value else { return }

            if characteristic.uuid == Self.audioDataCharacteristic {
                appendAudioPacket(data)
                return
            }

            if characteristic.uuid == Self.statusCharacteristic,
               let text = String(data: data, encoding: .utf8) {
                peripheralStatus = text
            }
        }
    }
}
