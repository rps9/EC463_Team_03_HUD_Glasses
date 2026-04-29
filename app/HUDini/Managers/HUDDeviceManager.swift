import Foundation
import CoreBluetooth

/// Kinds of peripheral the app supports.
enum HUDDeviceKind: String, CaseIterable, Identifiable {
    case frame
    case esp32

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .frame: return "Frame"
        case .esp32: return "ESP32"
        }
    }
}

/// Shared surface that `HUDLiveView` + the Device Sync card bind to.
/// Both `FrameBluetoothManager` and `ESP32BluetoothManager` conform.
@MainActor
protocol HUDDeviceManager: AnyObject, ObservableObject {
    var kind: HUDDeviceKind { get }

    var state: FrameBluetoothManager.ConnectionState { get }
    var discoveredDevices: [FrameBluetoothManager.DiscoveredDevice] { get }
    var isStreaming: Bool { get }
    var liveTranscript: String { get }
    var renderedText: String { get }
    var statusMessage: String { get }

    func beginScanning()
    func stopScanning()
    func connect(to device: FrameBluetoothManager.DiscoveredDevice)
    func disconnect()

    func startTranscribing(listeningLanguage: String, translatingTo: String)
    func stopListening()

    func sendHUDText(_ text: String, isPartial: Bool)
    func clearHUDText()
    func sendSuggestion(phonetic: String, english: String)
    func clearSuggestion()

    func setRecognitionLanguage(_ code: String)
    func setTargetLanguage(_ code: String)

    func warmUp()
}

extension HUDDeviceManager {
    var isConnected: Bool {
        if case .connected = state { return true }
        return false
    }
}
