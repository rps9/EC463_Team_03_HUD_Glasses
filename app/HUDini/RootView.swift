import SwiftUI

struct RootView: View {
    private enum Tab: Hashable {
        case hudDisplay
        case transcription
        case translation
        case bluetooth
    }

    private enum TesterSheet: Identifiable {
        case transcription
        case translation

        var id: Int { hashValue }
    }

    @State private var selectedTab: Tab = .hudDisplay
    @State private var activeSheet: TesterSheet?

    var body: some View {
        NavigationStack {
            TabView(selection: $selectedTab) {
                HUDLiveView()
                    .tag(Tab.hudDisplay)
                    .tabItem { Label("HUDini", systemImage: "display") }

                TranscriptionView()
                    .tag(Tab.transcription)
                    .tabItem { Label("Transcription", systemImage: "waveform") }

                TranslationView()
                    .tag(Tab.translation)
                    .tabItem { Label("Translate", systemImage: "globe") }

                BluetoothDemoView()
                    .tag(Tab.bluetooth)
                    .tabItem { Label("Bluetooth", systemImage: "dot.radiowaves.left.and.right") }
            }
            .navigationTitle(title(for: selectedTab))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Transcription QA") { activeSheet = .transcription }
                        Button("Translation QA") { activeSheet = .translation }
                    } label: {
                        Label("Testing", systemImage: "testtube.2")
                    }
                }
            }
        }
        .sheet(item: $activeSheet) { sheet in
            NavigationStack {
                testerView(for: sheet)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button("Done") { activeSheet = nil }
                        }
                    }
            }
        }
    }

    private func title(for tab: Tab) -> String {
        switch tab {
        case .hudDisplay:
            return ""
        case .transcription:
            return "Live Transcription"
        case .translation:
            return "Translation"
        case .bluetooth:
            return "Bluetooth"
        }
    }

    @ViewBuilder
    private func testerView(for sheet: TesterSheet) -> some View {
        switch sheet {
        case .transcription:
            TranscriptionTesterView()
                .navigationTitle("Transcription QA")
        case .translation:
            TranslationTesterView()
                .navigationTitle("Translation QA")
        }
    }
}

#Preview { RootView() }
