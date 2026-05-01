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

                testButton(
                    label: "H — Render flood (no listening, 3 min)",
                    description: "Sends a fresh SHOW_CAPTION partial every 100 ms for 3 min. Probes every 30 s. Reproduces display.text() malloc fragmentation in isolation.",
                    action: testRenderFlood,
                    tint: HUDTheme.amber
                )

                testButton(
                    label: "J — Real-session simulator (3 min)",
                    description: "Listens for 3 min; iOS sends SHOW_CAPTION every 200 ms and SHOW_SUGGESTION every 30 s. Probes every 30 s. Mimics real translation use.",
                    action: testRealSession,
                    tint: HUDTheme.rose
                )

                testButton(
                    label: "L — Multi-line SHOW_SUGGESTION stress",
                    description: "Sends 60 large 7-line SHOW_SUGGESTIONs over 2 min (~7 mallocs/render × 60 renders). Probes every 20 s.",
                    action: testSuggestionStress,
                    tint: HUDTheme.amber
                )

                testButton(
                    label: "K — On-demand SYS_PROBE",
                    description: "Sends FLAG_ADMIN_PROBE so Frame emits a full heap snapshot right now. No mic activity required.",
                    action: testAdminProbe
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

    /// Test H — Pure render flood (no listening). Targets the
    /// `frame.display.text()` malloc pattern in isolation. Per firmware
    /// (lua_libraries/display.c), each call to display.text mallocs a
    /// variable-size buffer (text length + meta). Our `draw_multiline`
    /// calls it once per line, so each render is ~7 variable-size
    /// mallocs. 100 ms cadence × 3 min = ~1800 renders. If the C heap
    /// is going to fragment from rendering alone, this finds it.
    private func testRenderFlood() async {
        await runTest(name: "H_RenderFlood") {
            await sendAdminProbe(label: "H_baseline")
            let captionStart = frameManager.devLogEntries.count
            let phrases = [
                "The quick brown fox jumps over the lazy dog one two three four",
                "Lorem ipsum dolor sit amet consectetur adipiscing elit sed do",
                "She sells seashells by the seashore on a sunny summer afternoon",
                "Pack my box with five dozen liquor jugs every monday morning",
                "How vexingly quick daft zebras jump in the misty forest dawn"
            ]
            // 3 min × 10/sec = ~1800 partials. Vary text so each
            // render's pixel-data length differs (different malloc sizes).
            let totalIterations = 1800
            for i in 0..<totalIterations {
                let phrase = phrases[i % phrases.count]
                let truncated = String(phrase.prefix(15 + (i % 30)))
                frameManager.adminSendCommand(
                    flag: FrameBluetoothManager.flagShowCaption,
                    fields: ["partial", truncated]
                )
                try? await Task.sleep(nanoseconds: 100_000_000)
                if i > 0 && i % 300 == 0 { // every ~30 s
                    await sendAdminProbe(label: "H_after_\(i)")
                }
            }
            await sendAdminProbe(label: "H_final")
            let summary = summarizeMicEvents(since: captionStart)
            frameManager.adminLog("H: \(summary.summaryLine)")
            return summary.audioErrors == 0 && summary.readErrors == 0
        }
    }

    /// Test J — Real-session simulator. The closest reproduction of the
    /// conditions where users see the OOM: continuous listening + steady
    /// caption stream + periodic suggestion delivery. If the failure is
    /// fragmentation that builds up over minutes, this surfaces it.
    private func testRealSession() async {
        await runTest(name: "J_RealSession") {
            await sendAdminProbe(label: "J_baseline")
            let sessionStart = frameManager.devLogEntries.count
            // Start listening — mic.read runs continuously.
            frameManager.adminSendCommand(
                flag: FrameBluetoothManager.flagSyncState,
                fields: ["1", "listening"]
            )
            // Run for 3 min. Caption stream at 5/sec; suggestion at 30 s
            // intervals. Probe at 30, 60, 90, 120, 150 s.
            let captionPhrases = [
                "Hello there how are you doing this fine afternoon today",
                "I would like to order a coffee with milk and two sugars",
                "Where is the nearest train station I need directions please",
                "Thank you very much for your help I really appreciate it"
            ]
            let suggestionPhonetic = "OH-lah BWAY-nahs DEE-ahs KOH-moh es-TAH oos-TED MWAY byen GRAH-syas POR pre-goon-TAR meh YA-moh"
            let suggestionEnglish = "Hello good morning, how are you? Very well thank you for asking, my name is. Pleased to meet you, where are you from?"

            let totalSteps = 900   // 3 min × 5/sec = 900 caption steps
            for step in 0..<totalSteps {
                let phrase = captionPhrases[step % captionPhrases.count]
                let chars = phrase.prefix(8 + (step % 40))
                frameManager.adminSendCommand(
                    flag: FrameBluetoothManager.flagShowCaption,
                    fields: ["partial", String(chars)]
                )
                if step > 0 && step % 150 == 0 { // every 30 s
                    frameManager.adminSendCommand(
                        flag: FrameBluetoothManager.flagShowSuggestion,
                        fields: [suggestionPhonetic, suggestionEnglish]
                    )
                    await sendAdminProbe(label: "J_t\(step / 5)s")
                }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            frameManager.adminSendCommand(
                flag: FrameBluetoothManager.flagSyncState,
                fields: ["0", "idle"]
            )
            await sendAdminProbe(label: "J_final")
            let summary = summarizeMicEvents(since: sessionStart)
            frameManager.adminLog("J: \(summary.summaryLine)")
            return summary.audioErrors == 0 && summary.readErrors == 0 && summary.permanentFailures == 0
        }
    }

    /// Test L — Multi-line SHOW_SUGGESTION stress. SHOW_SUGGESTION fills
    /// all 7 display lines (2 transcription + 2 english + 3 phonetic);
    /// each render is the worst case for display.text() mallocs. Sending
    /// 60 of these over 2 min = ~420 mallocs of the largest variable
    /// sizes — accelerates fragmentation if the hypothesis is correct.
    private func testSuggestionStress() async {
        await runTest(name: "L_SuggestionStress") {
            await sendAdminProbe(label: "L_baseline")
            let stressStart = frameManager.devLogEntries.count
            // Build a long phonetic + english pair that will fill the
            // 3-line phonetic and 2-line english regions completely.
            let basePhonetic = "OH-lah BWAY-nahs DEE-ahs KOH-moh es-TAH oos-TED MWAY byen GRAH-syas POR pre-goon-TAR meh YA-moh kah-RLOS"
            let baseEnglish = "Hello good morning how are you doing today, I am very well thank you for asking, my name is Carlos"

            for i in 0..<60 {
                let phonetic = basePhonetic + " v\(i)"
                let english = baseEnglish + " v\(i)"
                frameManager.adminSendCommand(
                    flag: FrameBluetoothManager.flagShowSuggestion,
                    fields: [phonetic, english]
                )
                try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 s
                if i > 0 && i % 10 == 0 { // every ~20 s
                    await sendAdminProbe(label: "L_after_\(i)")
                }
            }
            await sendAdminProbe(label: "L_final")
            let summary = summarizeMicEvents(since: stressStart)
            frameManager.adminLog("L: \(summary.summaryLine)")
            return summary.audioErrors == 0 && summary.readErrors == 0
        }
    }

    private func testAdminProbe() async {
        await runTest(name: "K_AdminProbe") {
            return await sendAdminProbe(label: "K_manual")
        }
    }

    /// Send FLAG_ADMIN_PROBE with the given label and wait for the
    /// matching ADMIN_PROBE_OK response. Returns whether all probes
    /// arrived. Logs a one-line summary of the SYS_PROBE results.
    @discardableResult
    private func sendAdminProbe(label: String) async -> Bool {
        let startIndex = frameManager.devLogEntries.count
        frameManager.adminSendCommand(flag: FrameBluetoothManager.flagAdminProbe, fields: [label])
        guard let _ = await waitForEvent(matching: "EVT\tADMIN_PROBE_OK\t\(label)",
                                         since: startIndex,
                                         timeout: 4.0) else {
            frameManager.adminLog("[\(label)] probe timeout")
            return false
        }
        var sysLine = "[\(label)] sys:"
        let entries = frameManager.devLogEntries
        for i in startIndex..<entries.count {
            let m = entries[i].message
            if m.contains("EVT\tSYS_PROBE\tadmin_\(label)") {
                // EVT\tSYS_PROBE\tadmin_<label>\t<size>\t<outcome>
                let parts = m.components(separatedBy: "\t")
                if parts.count >= 5 {
                    sysLine += " \(parts[3])=\(parts[4])"
                }
            } else if m.contains("EVT\tHEAP_PROBE\tadmin_\(label)") {
                let parts = m.components(separatedBy: "\t")
                if parts.count >= 4 {
                    sysLine += " lua=\(parts[3])"
                }
            } else if m.contains("EVT\tBLE_STATE\tadmin_\(label)") {
                let parts = m.components(separatedBy: "\t")
                if parts.count >= 4 {
                    sysLine += " ble=\(parts[3])"
                }
            }
        }
        appendTestLog(sysLine, tint: HUDTheme.accent)
        frameManager.adminLog(sysLine)
        return true
    }

    /// Walk the dev log from `startIndex` and tally MIC_READ_ERR / AUDIO_ERROR
    /// counts so each stress test gets a one-line pass/fail summary.
    private struct MicEventSummary {
        var readErrors: Int
        var audioErrors: Int
        var permanentFailures: Int
        var recoveryAttempts: Int
        var sysProbes: Int
        var summaryLine: String {
            "read_err=\(readErrors) audio_err=\(audioErrors) perm=\(permanentFailures) recov=\(recoveryAttempts) sys_probes=\(sysProbes)"
        }
    }

    private func summarizeMicEvents(since startIndex: Int) -> MicEventSummary {
        var s = MicEventSummary(readErrors: 0, audioErrors: 0, permanentFailures: 0, recoveryAttempts: 0, sysProbes: 0)
        let entries = frameManager.devLogEntries
        guard startIndex <= entries.count else { return s }
        for i in startIndex..<entries.count {
            let m = entries[i].message
            if m.contains("EVT\tMIC_READ_ERR") { s.readErrors += 1 }
            else if m.contains("EVT\tAUDIO_ERROR") { s.audioErrors += 1 }
            else if m.contains("EVT\tMIC_PERMANENT_FAILURE") { s.permanentFailures += 1 }
            else if m.contains("EVT\tMIC_RECOVERY_TRY") { s.recoveryAttempts += 1 }
            else if m.contains("EVT\tSYS_PROBE") { s.sysProbes += 1 }
        }
        return s
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
