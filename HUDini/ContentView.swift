import SwiftUI

struct ContentView: View {
    @StateObject private var mgr = TranscriptionManager()

    var body: some View {
        VStack(spacing: 12) {
            Text("HUDini • Live Transcription")
                .font(.headline)

            ScrollView {
                Text(mgr.transcript.isEmpty ? "…" : mgr.transcript)
                    .font(.body.monospaced())
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .accessibilityLabel("Transcript")
            }
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12))

            HStack(spacing: 12) {
                Button(mgr.isTranscribing ? "Stop" : "Start") {
                    mgr.isTranscribing ? mgr.stop() : mgr.start()
                }
                .buttonStyle(.borderedProminent)

                Button("Clear") {
                    mgr.resetTranscript()
                }
                .buttonStyle(.bordered)
            }

            if !mgr.statusMessage.isEmpty {
                Text(mgr.statusMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .task {
            // Ask once at view start
            await mgr.requestPermissions()
        }
    }
}

#Preview {
    ContentView()
}
