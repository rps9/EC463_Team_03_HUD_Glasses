import SwiftUI

struct RootView: View {
    var body: some View {
        TabView {
            TranscriptionView()
                .tabItem { Label("Transcribe", systemImage: "waveform") }

            TranscriptionTesterView()
                .tabItem { Label("Transcribe QA", systemImage: "checklist") }

            TranslationView()
                .tabItem { Label("Translate", systemImage: "globe") }

            TranslationTesterView()
                .tabItem { Label("Translate QA", systemImage: "checkmark.circle") }
        }
    }
}

#Preview { RootView() }
