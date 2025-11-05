import SwiftUI

struct RootView: View {
    var body: some View {
        TabView {
            TranscriptionView()
                .tabItem { Label("Live", systemImage: "waveform") }

            TranscriptionTesterView()
                .tabItem { Label("Testing", systemImage: "checklist") }
        }
    }
}

#Preview { RootView() }
