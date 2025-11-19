import Foundation
import Combine
import CoreBluetooth

/// Handles the demo Bluetooth central flow for the HUDini prototype.
/// The manager connects to a Nordic UART Service (NUS) peripheral so we can
/// stream simple UTF-8 text to apps such as LightBlue or nRF Connect on macOS.
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

    // Nordic UART service/characteristic identifiers.
    private static let uartService = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
    private static let rxCharacteristic = CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E") // write
    private static let txCharacteristic = CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E") // notify

    @Published private(set) var state: ConnectionState = .idle
    @Published private(set) var discoveredDevices: [DiscoveredDevice] = []
    @Published private(set) var statusMessage: String = "Checking Bluetooth…"
    @Published private(set) var receivedText: String = ""
    @Published private(set) var lastSentText: String = ""

    private var central: CBCentralManager!
    private var connectedPeripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var shouldScanWhenReady: Bool = false

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
        guard let peripheral = connectedPeripheral else { return }
        central.cancelPeripheralConnection(peripheral)
        resetConnectionState(message: "Disconnected")
    }

    func send(text: String) {
        guard let characteristic = writeCharacteristic, let peripheral = connectedPeripheral else {
            statusMessage = "Connect to a device first"
            return
        }
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else {
            statusMessage = "Enter a message to send"
            return
        }

        guard let data = message.data(using: .utf8) else {
            statusMessage = "Message must be UTF-8"
            return
        }

        peripheral.writeValue(data, for: characteristic, type: .withResponse)
        lastSentText = message
        statusMessage = "Sent message"
    }

    func clearTranscripts() {
        receivedText = ""
        lastSentText = ""
    }

    private func resetConnectionState(message: String) {
      writeCharacteristic = nil
      connectedPeripheral = nil
      discoveredDevices = []
      state = .idle
      statusMessage = message
    }

    private func startScan() {
        shouldScanWhenReady = false
        discoveredDevices = []
        central.scanForPeripherals(withServices: [Self.uartService], options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        state = .scanning
        statusMessage = "Scanning for devices…"
    }
}

// MARK: - CBCentralManagerDelegate

extension BluetoothDemoManager: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            handleState(central.state)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        Task { @MainActor in
            let name = peripheral.name ?? "Unnamed"
            // Avoid duplicates by checking identity pointer.
            if discoveredDevices.contains(where: { $0.peripheral == peripheral }) { return }
            let device = DiscoveredDevice(name: name, peripheral: peripheral)
            discoveredDevices.append(device)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            connectedPeripheral = peripheral
            peripheral.delegate = self
            state = .connected(peripheral.name ?? "Device")
            statusMessage = "Connected. Discovering services…"
            peripheral.discoverServices([Self.uartService])
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

// MARK: - CBPeripheralDelegate

extension BluetoothDemoManager: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        Task { @MainActor in
            if let error {
                statusMessage = "Service discovery failed: \(error.localizedDescription)"
                disconnect()
                return
            }
            guard let services = peripheral.services else { return }
            for service in services where service.uuid == Self.uartService {
                peripheral.discoverCharacteristics([Self.rxCharacteristic, Self.txCharacteristic], for: service)
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        Task { @MainActor in
            if let error {
                statusMessage = "Characteristic discovery failed: \(error.localizedDescription)"
                disconnect()
                return
            }
            guard let chars = service.characteristics else { return }
            for char in chars {
                if char.uuid == Self.rxCharacteristic {
                    writeCharacteristic = char
                }
                if char.uuid == Self.txCharacteristic {
                    peripheral.setNotifyValue(true, for: char)
                }
            }

            if writeCharacteristic != nil {
                statusMessage = "Ready to send messages"
            } else {
                statusMessage = "Writable characteristic missing"
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        Task { @MainActor in
            if let error {
                statusMessage = "Receive error: \(error.localizedDescription)"
                return
            }
            guard let data = characteristic.value, let text = String(data: data, encoding: .utf8) else { return }
            if receivedText.isEmpty {
                receivedText = text
            } else {
                receivedText += "\n" + text
            }
        }
    }
}
