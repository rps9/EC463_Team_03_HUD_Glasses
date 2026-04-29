import SwiftUI
import UIKit

struct AdminTestView: View {
    @EnvironmentObject private var frameManager: FrameBluetoothManager
    @State private var testLog: [TestLogLine] = []
    @State private var isRunning = false
    @State private var runningTestName: String = ""
    @State private var copyStatus: String = ""

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                connectionCard

                instructionsCard

                testGridCard

                testLogCard
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
        }
        .hudScreen()
        .navigationTitle("Admin Tests")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: Cards

    private var connectionCard: some View {
        HUDCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Circle()
                        .fill(frameManager.adminIsReady ? HUDTheme.mint : HUDTheme.rose)
                        .frame(width: 12, height: 12)
                    Text(frameManager.adminIsReady ? "Ready" : "Not ready")
                        .font(.system(.headline, design: .rounded, weight: .semibold))
                        .foregroundStyle(HUDTheme.ink)
                    Spacer()
                    if isRunning {
                        ProgressView().tint(HUDTheme.accent)
                        Text(runningTestName).font(.system(.caption, design: .rounded))
                            .foregroundStyle(HUDTheme.inkMuted)
                    }
                }
                Text(frameManager.peripheralStatus.isEmpty ? "No status" : frameManager.peripheralStatus)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(HUDTheme.inkMuted)
                Text("MTU: \(frameManager.framePayloadLimit)  |  app: \(frameManager.frameAppVersion)  |  fw: \(frameManager.frameFirmwareVersion)")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(HUDTheme.inkMuted)
            }
        }
    }

    private var instructionsCard: some View {
        HUDCard {
            VStack(alignment: .leading, spacing: 8) {
                Text("How to use")
                    .font(.system(.headline, design: .rounded, weight: .semibold))
                    .foregroundStyle(HUDTheme.ink)
                Text("Make sure Frame is connected and Ready. Run tests one at a time. If a test wedges Frame, tap Reset Frame & Verify to recover before the next test, or reinstall + reboot if needed. When you're done, tap Copy Test Log and paste it back into chat.")
                    .font(.system(.body, design: .rounded))
                    .foregroundStyle(HUDTheme.inkMuted)
            }
        }
    }

    private var testGridCard: some View {
        HUDCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Diagnostics")
                    .font(.system(.headline, design: .rounded, weight: .semibold))
                    .foregroundStyle(HUDTheme.ink)

                testButton(
                    label: "A — Liveness (PING → READY)",
                    description: "Baseline. If this fails, Frame is already wedged.",
                    action: testLiveness
                )

                testButton(
                    label: "B — Empty SHOW_SUGGESTION",
                    description: "Reproduces the 12:57:35 trigger. Sends two empty fields, then PINGs.",
                    action: testEmptySuggestion
                )

                testButton(
                    label: "C — Stranded first chunk",
                    description: "Lies about declared size, sends partial body, then PINGs. Confirms accumulator stranding.",
                    action: testStrandedChunk,
                    tint: HUDTheme.amber
                )

                testButton(
                    label: "D — Stranded then full command",
                    description: "Strands accumulator, then sends a full SHOW_CAPTION, then PINGs. Tests if Frame self-heals.",
                    action: testStrandedThenFull,
                    tint: HUDTheme.amber
                )

                testButton(
                    label: "E — Rapid mic toggle ×5",
                    description: "Cycles SYNC_STATE listening 0/1 five times to test mic restart resilience.",
                    action: testRapidMicToggle
                )

                testButton(
                    label: "F — Large multi-chunk payload",
                    description: "Sends a ~600-byte SHOW_SUGGESTION (forces multi-chunk) then PINGs.",
                    action: testLargePayload
                )

                testButton(
                    label: "G — PING storm ×20",
                    description: "Bursts 20 PINGs as fast as possible, counts EVT READYs.",
                    action: testPingStorm
                )

                Divider()

                Button {
                    Task { await resetAndVerify() }
                } label: {
                    Label("Reset Frame & Verify", systemImage: "arrow.counterclockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(HUDPrimaryButtonStyle(tint: HUDTheme.rose))
                .disabled(isRunning || !frameManager.adminIsReady)
            }
        }
    }

    private var testLogCard: some View {
        HUDCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Test Log")
                        .font(.system(.headline, design: .rounded, weight: .semibold))
                        .foregroundStyle(HUDTheme.ink)
                    Spacer()
                    Button("Copy") {
                        UIPasteboard.general.string = exportedTestLog
                        copyStatus = "Copied \(testLog.count) lines."
                    }
                    .buttonStyle(HUDSecondaryButtonStyle(tint: HUDTheme.accent))
                    .disabled(testLog.isEmpty)

                    Button("Clear") {
                        testLog.removeAll()
                        copyStatus = ""
                    }
                    .buttonStyle(HUDSecondaryButtonStyle(tint: HUDTheme.rose))
                    .disabled(testLog.isEmpty)
                }

                if !copyStatus.isEmpty {
                    Text(copyStatus)
                        .font(.system(.caption, design: .rounded))
                        .foregroundStyle(HUDTheme.inkMuted)
                }

                if testLog.isEmpty {
                    Text("No tests run yet.")
                        .font(.system(.body, design: .rounded))
                        .foregroundStyle(HUDTheme.inkMuted)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(testLog.reversed()) { line in
                            HStack(alignment: .top, spacing: 8) {
                                Text(Self.timestampFormatter.string(from: line.timestamp))
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(HUDTheme.inkMuted)
                                Text(line.text)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(line.tint)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(8)
                            .background(.white.opacity(0.65), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                    }
                }
            }
        }
    }

    private func testButton(
        label: String,
        description: String,
        action: @escaping () async -> Void,
        tint: Color = HUDTheme.accent
    ) -> some View {
        Button {
            Task { await action() }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(label)
                    .font(.system(.body, design: .rounded, weight: .semibold))
                Text(description)
                    .font(.system(.caption, design: .rounded))
                    .foregroundStyle(HUDTheme.inkMuted)
                    .multilineTextAlignment(.leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(.white.opacity(0.78), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(tint.opacity(0.4), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .disabled(isRunning || !frameManager.adminIsReady)
    }

    // MARK: Tests

    private func testLiveness() async {
        await runTest(name: "A_Liveness") {
            await sendAndAwaitReady(timeout: 2.0, tag: "A.PING")
        }
    }

    private func testEmptySuggestion() async {
        await runTest(name: "B_EmptySuggestion") {
            frameManager.adminSendCommand(flag: FrameBluetoothManager.flagShowSuggestion, fields: ["", ""])
            try? await Task.sleep(nanoseconds: 200_000_000)
            return await sendAndAwaitReady(timeout: 3.0, tag: "B.PING_after_empty")
        }
    }

    private func testStrandedChunk() async {
        await runTest(name: "C_StrandedChunk") {
            // Strand the SHOW_CAPTION (0x43) slot. Under per-flag isolation,
            // PING (0x40) lives in a different slot and should still answer.
            frameManager.adminSendStrandedFirstChunk(
                flag: FrameBluetoothManager.flagShowCaption,
                declaredSize: 500,
                actualPayload: "partial\tdummy_partial_body_1234567"
            )
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            return await sendAndAwaitReady(timeout: 3.0, tag: "C.PING_after_strand")
        }
    }

    private func testStrandedThenFull() async {
        await runTest(name: "D_StrandedThenFull") {
            frameManager.adminSendStrandedFirstChunk(
                flag: FrameBluetoothManager.flagShowCaption,
                declaredSize: 500,
                actualPayload: "partial\tdummy_partial_body_1234567"
            )
            try? await Task.sleep(nanoseconds: 800_000_000)
            // A full SHOW_CAPTION will still be eaten by the stranded 0x43 slot.
            frameManager.adminSendCommand(flag: FrameBluetoothManager.flagShowCaption, fields: ["partial", "stranded-test-eaten"])
            try? await Task.sleep(nanoseconds: 800_000_000)
            // After the watchdog window (>10s), the 0x43 slot self-heals; a
            // fresh SHOW_CAPTION attempted here would also succeed, but the
            // PING below validates per-flag isolation regardless.
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            return await sendAndAwaitReady(timeout: 3.0, tag: "D.PING_after_recovery_window")
        }
    }

    private func testRapidMicToggle() async {
        await runTest(name: "E_RapidMicToggle") {
            var allOk = true
            for i in 1...5 {
                let cycleStart = frameManager.devLogEntries.count
                frameManager.adminSendCommand(flag: FrameBluetoothManager.flagSyncState, fields: ["1", "listening"])
                let onOk = await waitForEvent(matching: "EVT\tSTATUS\tlistening", since: cycleStart, timeout: 2.0)
                let toggleStart = frameManager.devLogEntries.count
                frameManager.adminSendCommand(flag: FrameBluetoothManager.flagSyncState, fields: ["0", "idle"])
                let offOk = await waitForEvent(matching: "EVT\tSTATUS\tidle", since: toggleStart, timeout: 2.0)
                frameManager.adminLog("E cycle \(i): listen=\(onOk != nil ? "OK" : "MISS") idle=\(offOk != nil ? "OK" : "MISS")")
                if onOk == nil || offOk == nil { allOk = false }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            let pingOk = await sendAndAwaitReady(timeout: 2.0, tag: "E.PING_after_cycles")
            return allOk && pingOk
        }
    }

    private func testLargePayload() async {
        await runTest(name: "F_LargePayload") {
            let phonetic = String(repeating: "OH-lah, BWAY-nahs, ", count: 16)
            let english = String(repeating: "Hello, good day to you. ", count: 13)
            frameManager.adminSendCommand(flag: FrameBluetoothManager.flagShowSuggestion, fields: [phonetic, english])
            try? await Task.sleep(nanoseconds: 400_000_000)
            return await sendAndAwaitReady(timeout: 3.0, tag: "F.PING_after_large")
        }
    }

    private func testPingStorm() async {
        await runTest(name: "G_PingStorm") {
            let startIndex = frameManager.devLogEntries.count
            for _ in 0..<20 {
                frameManager.adminSendCommand(flag: FrameBluetoothManager.flagPing)
                try? await Task.sleep(nanoseconds: 5_000_000)
            }
            // Wait up to 5s for replies to land.
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            let entries = frameManager.devLogEntries
            var readyCount = 0
            for i in startIndex..<entries.count {
                if entries[i].direction == "IN" && entries[i].message.contains("EVT\tREADY") {
                    readyCount += 1
                }
            }
            frameManager.adminLog("G storm: \(readyCount)/20 EVT READY received")
            return readyCount >= 18 // allow tiny BLE loss tolerance
        }
    }

    // MARK: Reset

    private func resetAndVerify() async {
        await runTest(name: "Reset") {
            frameManager.adminSendCommand(flag: FrameBluetoothManager.flagReset)
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            return await sendAndAwaitReady(timeout: 4.0, tag: "Reset.PING_after_reset")
        }
    }

    // MARK: Runner helpers

    private func runTest(name: String, body: @escaping () async -> Bool) async {
        guard frameManager.adminIsReady else {
            appendTestLog("[\(name)] skipped — not connected/ready", tint: HUDTheme.rose)
            return
        }
        if isRunning { return }
        isRunning = true
        runningTestName = name
        defer {
            isRunning = false
            runningTestName = ""
        }

        appendTestLog("[\(name)] start", tint: HUDTheme.accent)
        frameManager.adminLog("[\(name)] start")

        let pass = await body()

        let summary = "[\(name)] \(pass ? "PASS" : "FAIL")"
        appendTestLog(summary, tint: pass ? HUDTheme.mint : HUDTheme.rose)
        frameManager.adminLog(summary)
    }

    private func sendAndAwaitReady(timeout: TimeInterval, tag: String) async -> Bool {
        let startIndex = frameManager.devLogEntries.count
        frameManager.adminSendCommand(flag: FrameBluetoothManager.flagPing)
        let hit = await waitForEvent(matching: "EVT\tREADY", since: startIndex, timeout: timeout)
        if let hit {
            frameManager.adminLog("\(tag): READY in \(latencyMs(from: startIndex, to: hit))ms")
            appendTestLog("\(tag) → READY \(latencyMs(from: startIndex, to: hit))ms", tint: HUDTheme.mint)
            return true
        } else {
            frameManager.adminLog("\(tag): TIMEOUT after \(timeout)s")
            appendTestLog("\(tag) → TIMEOUT \(timeout)s", tint: HUDTheme.rose)
            return false
        }
    }

    private func waitForEvent(matching pattern: String, since startIndex: Int, timeout: TimeInterval) async -> FrameBluetoothManager.DevLogEntry? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let entries = frameManager.devLogEntries
            if startIndex <= entries.count {
                for i in startIndex..<entries.count {
                    let e = entries[i]
                    if e.direction == "IN" && e.message.contains(pattern) {
                        return e
                    }
                }
            }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return nil
    }

    private func latencyMs(from startIndex: Int, to entry: FrameBluetoothManager.DevLogEntry) -> Int {
        guard startIndex < frameManager.devLogEntries.count else { return -1 }
        let start = frameManager.devLogEntries[startIndex].timestamp
        return Int(entry.timestamp.timeIntervalSince(start) * 1000)
    }

    private func appendTestLog(_ text: String, tint: Color) {
        testLog.append(TestLogLine(timestamp: Date(), text: text, tint: tint))
    }

    private var exportedTestLog: String {
        testLog.map { line in
            "\(Self.timestampFormatter.string(from: line.timestamp)) \(line.text)"
        }
        .joined(separator: "\n")
    }

    struct TestLogLine: Identifiable {
        let id = UUID()
        let timestamp: Date
        let text: String
        let tint: Color
    }
}

#Preview {
    NavigationStack {
        AdminTestView()
            .environmentObject(FrameBluetoothManager())
    }
}
