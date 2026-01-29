import SwiftUI

struct TranscriptionTesterView: View {
    @StateObject private var tester = TranscriptionTester()

    private let pool = [
        "Please meet me at the library after lunch.",
        "The quick brown fox jumps over the lazy dog.",
        "Where is the nearest subway station?",
        "I would like a cup of coffee without sugar.",
        "Could you repeat that more slowly please?",
        "Turn left at the traffic light and walk two blocks.",
        "How much does this cost including tax?",
        "My name is Ryan and I am testing transcription.",
        "The system should display translations on a heads up display.",
        "We will measure speed and accuracy for this sentence."
    ]

    var body: some View {
        VStack(spacing: 12) {
            Text("Testing")
                .font(.headline)

            Group {
                sectionTitle("Target")
                textBox(tester.targetSentence.isEmpty ? "Tap “New sentence”" : tester.targetSentence)
            }

            Group {
                sectionTitle("Live transcript")
                ScrollView {
                    Text(tester.liveTranscript.isEmpty ? "…" : tester.liveTranscript)
                        .font(.body.monospaced())
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(minHeight: 90)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }

            HStack(spacing: 12) {
                Button("New sentence") { tester.pickRandomSentence(from: pool) }
                    .buttonStyle(.bordered)
                    .disabled(tester.isRunning)

                Button(tester.isRunning ? (tester.micStopped ? "Finalizing…" : "Stop") : "Start") {
                    if tester.isRunning {
                        tester.stopMicOnly()   // snip mic, keep recognition alive
                    } else {
                        Task {
                            if await tester.requestPermissions() {
                                tester.start()
                            } else {
                                tester.status = "Permissions not granted"
                            }
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(tester.isRunning && tester.micStopped) // after stop, wait for final

                Button("Reset stats") { tester.resetStats() }
                    .buttonStyle(.bordered)
                    .disabled(tester.isRunning)
            }

            if let m = tester.lastMetrics {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Last run").font(.subheadline).bold()
                    Text("Accuracy: \(formatPct(m.accuracy))")
                    Text("Finalize delay: \(formatMS(m.finalizeDelayMS))")
                    Text("Recognized: “\(m.recognized)”")
                        .lineLimit(3)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(Color(.tertiarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Session averages (\(tester.runs) run\(tester.runs == 1 ? "" : "s"))")
                    .font(.subheadline).bold()
                Text("Avg accuracy: \(formatPct(tester.avgAccuracy))")
                Text("Avg finalize delay: \(formatMS(tester.avgDelayMS))")
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if !tester.status.isEmpty {
                Text(tester.status)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Spacer(minLength: 0)
        }
        .padding()
    }

    // MARK: - Helpers

    private func sectionTitle(_ s: String) -> some View {
        Text(s).font(.subheadline).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func textBox(_ s: String) -> some View {
        Text(s)
            .font(.body)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private func formatPct(_ x: Double) -> String {
        if x.isNaN { return "—" }
        return String(format: "%.1f%%", max(0, min(1, x)) * 100)
    }
    private func formatMS(_ x: Double) -> String {
        if x.isNaN { return "—" }
        return String(format: "%.0f ms", x)
    }
}

#Preview { TranscriptionTesterView() }
