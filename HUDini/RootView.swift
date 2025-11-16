import SwiftUI

struct RootView: View {
    private enum Tab: Hashable {
        case hudini
        case transcription
        case translation
        case bluetooth
    }

    private enum TesterSheet: Identifiable {
        case transcription
        case translation

        var id: Int { hashValue }
    }

    @State private var selectedTab: Tab = .hudini
    @State private var activeSheet: TesterSheet?

    var body: some View {
        NavigationStack {
            TabView(selection: $selectedTab) {
                HUDiniView()
                    .tag(Tab.hudini)
                    .tabItem { Label("HUDini", systemImage: "mic.fill") }
                
                TranscriptionView()
                    .tag(Tab.transcription)
                    .tabItem { Label("Transcribe", systemImage: "waveform") }

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
        case .hudini:
            return "HUDini"
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
