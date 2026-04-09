import SwiftUI
import UIKit
import AVFoundation

struct AdminFrameLogView: View {
    @EnvironmentObject private var frameManager: FrameBluetoothManager
    @State private var copyStatusMessage: String = ""
    @State private var manualMessage: String = ""
    @State private var isPlayingAudio = false
    @State private var playingURL: URL?
    @State private var audioPlayer: AVAudioPlayer?

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                HUDCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Frame Dev Log")
                            .font(.system(.headline, design: .rounded, weight: .semibold))
                            .foregroundStyle(HUDTheme.ink)

                        Text("Admin-only log of outbound Frame commands and inbound Frame events.")
                            .font(.system(.body, design: .rounded))
                            .foregroundStyle(HUDTheme.inkMuted)

                        HStack(spacing: 12) {
                            Button("Copy Log") {
                                UIPasteboard.general.string = exportedLogText
                                copyStatusMessage = "Copied \(frameManager.devLogEntries.count) log entries."
                            }
                            .buttonStyle(HUDPrimaryButtonStyle(tint: HUDTheme.accent))

                            Button("Clear Log") {
                                frameManager.clearDevLog()
                                copyStatusMessage = ""
                            }
                            .buttonStyle(HUDSecondaryButtonStyle(tint: HUDTheme.rose))
                        }

                        if !copyStatusMessage.isEmpty {
                            Text(copyStatusMessage)
                                .font(.system(.caption, design: .rounded))
                                .foregroundStyle(HUDTheme.inkMuted)
                        }
                    }
                }

                HUDCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Send to Glasses")
                            .font(.system(.headline, design: .rounded, weight: .semibold))
                            .foregroundStyle(HUDTheme.ink)

                        TextField("Type a message…", text: $manualMessage, axis: .vertical)
                            .font(.system(.body, design: .rounded))
                            .lineLimit(1...4)
                            .padding(12)
                            .background(.white.opacity(0.72), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .stroke(HUDTheme.strokeStrong, lineWidth: 1)
                            }

                        HStack(spacing: 12) {
                            Button("Send") {
                                let text = manualMessage.trimmingCharacters(in: .whitespacesAndNewlines)
                                guard !text.isEmpty else { return }
                                frameManager.sendHUDTextToFrame(text, isPartial: false, updateStatus: true)
                            }
                            .buttonStyle(HUDPrimaryButtonStyle(tint: HUDTheme.accent))
                            .disabled(manualMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !isFrameConnected)

                            Button("Clear Display") {
                                frameManager.clearFrameDisplay()
                            }
                            .buttonStyle(HUDSecondaryButtonStyle(tint: HUDTheme.rose))
                            .disabled(!isFrameConnected)

                            Button("Reset Frame") {
                                frameManager.resetFrame()
                            }
                            .buttonStyle(HUDSecondaryButtonStyle(tint: HUDTheme.amber))
                            .disabled(!isFrameConnected)
                        }
                    }
                }

                HUDCard {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Debug Audio")
                                .font(.system(.headline, design: .rounded, weight: .semibold))
                                .foregroundStyle(HUDTheme.ink)
                            Spacer()
                            if !frameManager.debugAudioRecordings.isEmpty {
                                Button("Clear All") {
                                    frameManager.clearDebugRecordings()
                                }
                                .buttonStyle(HUDSecondaryButtonStyle(tint: HUDTheme.rose))
                            }
                        }

                        if frameManager.debugAudioRecordings.isEmpty {
                            Text("Audio is captured each listening session. Recordings appear here after you stop.")
                                .font(.system(.body, design: .rounded))
                                .foregroundStyle(HUDTheme.inkMuted)
                        } else {
                            ForEach(frameManager.debugAudioRecordings, id: \.absoluteString) { url in
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(url.lastPathComponent)
                                            .font(.system(.caption, design: .monospaced, weight: .semibold))
                                            .foregroundStyle(HUDTheme.ink)
                                        Text(fileSizeString(for: url))
                                            .font(.system(.caption2, design: .rounded))
                                            .foregroundStyle(HUDTheme.inkMuted)
                                    }
                                    Spacer()
                                    Button(playingURL == url ? "Playing..." : "Play") {
                                        playDebugAudio(url: url)
                                    }
                                    .buttonStyle(HUDSecondaryButtonStyle(tint: HUDTheme.accent))
                                    .disabled(isPlayingAudio)
                                }
                                .padding(10)
                                .background(.white.opacity(0.72), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }
                        }
                    }
                }

                HUDCard {
                    if frameManager.devLogEntries.isEmpty {
                        Text("No Frame events logged yet.")
                            .font(.system(.body, design: .rounded))
                            .foregroundStyle(HUDTheme.inkMuted)
                    } else {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(frameManager.devLogEntries.reversed()) { entry in
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("\(entry.direction) \(Self.timestampFormatter.string(from: entry.timestamp))")
                                        .font(.system(.caption, design: .monospaced, weight: .semibold))
                                        .foregroundStyle(entry.direction == "OUT" ? HUDTheme.accent : HUDTheme.mint)

                                    Text(entry.message)
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundStyle(HUDTheme.ink)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .padding(12)
                                .background(.white.opacity(0.72), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
        }
        .hudScreen()
        .navigationTitle("Admin")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var isFrameConnected: Bool {
        if case .connected = frameManager.state { return true }
        return false
    }

    private func fileSizeString(for url: URL) -> String {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        let duration = Double(size) / (16000.0 * 2.0)
        return "\(size / 1024) KB (~\(String(format: "%.1f", duration))s)"
    }

    private func playDebugAudio(url: URL) {
        guard let rawData = try? Data(contentsOf: url), !rawData.isEmpty else { return }

        let sampleRate: UInt32 = 16000
        let bitsPerSample: UInt16 = 16
        let channels: UInt16 = 1
        let byteRate = sampleRate * UInt32(channels) * UInt32(bitsPerSample / 8)
        let blockAlign = channels * (bitsPerSample / 8)
        let dataSize = UInt32(rawData.count)

        var wav = Data()
        wav.append(contentsOf: "RIFF".utf8)
        wav.append(littleEndian: 36 + dataSize)
        wav.append(contentsOf: "WAVE".utf8)
        wav.append(contentsOf: "fmt ".utf8)
        wav.append(littleEndian: UInt32(16))
        wav.append(littleEndian: UInt16(1))
        wav.append(littleEndian: channels)
        wav.append(littleEndian: sampleRate)
        wav.append(littleEndian: byteRate)
        wav.append(littleEndian: blockAlign)
        wav.append(littleEndian: bitsPerSample)
        wav.append(contentsOf: "data".utf8)
        wav.append(littleEndian: dataSize)
        wav.append(rawData)

        let wavURL = FileManager.default.temporaryDirectory.appendingPathComponent("debug_playback.wav")
        try? wav.write(to: wavURL)

        try? AVAudioSession.sharedInstance().setCategory(.playback)
        try? AVAudioSession.sharedInstance().setActive(true)

        isPlayingAudio = true
        playingURL = url
        do {
            let player = try AVAudioPlayer(contentsOf: wavURL)
            audioPlayer = player
            player.play()
            Task {
                try? await Task.sleep(nanoseconds: UInt64(player.duration * 1_000_000_000) + 500_000_000)
                await MainActor.run {
                    isPlayingAudio = false
                    playingURL = nil
                    audioPlayer = nil
                }
            }
        } catch {
            print("[Debug Audio] playback error: \(error)")
            isPlayingAudio = false
            playingURL = nil
        }
    }

    private var exportedLogText: String {
        frameManager.devLogEntries.map { entry in
            "\(Self.timestampFormatter.string(from: entry.timestamp)) [\(entry.direction)] \(entry.message)"
        }
        .joined(separator: "\n")
    }
}

private extension Data {
    mutating func append(littleEndian value: UInt16) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }
    mutating func append(littleEndian value: UInt32) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }
}

#Preview {
    NavigationStack {
        AdminFrameLogView()
            .environmentObject(FrameBluetoothManager())
    }
}
