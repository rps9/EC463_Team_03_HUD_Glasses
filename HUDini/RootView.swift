import SwiftUI

struct RootView: View {
    private enum Tab: Hashable {
        case hudini
        case displayMode
        case transcription
        case translation
        case bluetooth
    }

    private enum TesterSheet: Identifiable {
        case transcription
        case translation

        var id: Int { hashValue }
    }

    @StateObject private var sharedTranslationManager = TranslationManager()
    @StateObject private var sharedTranscriptionManager = TranscriptionManager()
    @State private var selectedTab: Tab = .hudini
    @State private var activeSheet: TesterSheet?

    var body: some View {
        NavigationStack {
            TabView(selection: $selectedTab) {
                HUDiniView(
                    transcriptionManager: sharedTranscriptionManager,
                    translationManager: sharedTranslationManager
                )
                    .tag(Tab.hudini)
                    .tabItem { Label("HUDini", systemImage: "mic.fill") }
                
                DisplayModeView(
                    transcriptionManager: sharedTranscriptionManager,
                    translationManager: sharedTranslationManager
                )
                    .tag(Tab.displayMode)
                    .tabItem { Label("Display", systemImage: "display") }
                
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
            .navigationTitle(selectedTab == .displayMode ? "" : title(for: selectedTab))
            .toolbar {
                if selectedTab != .displayMode {
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
            .toolbar(selectedTab == .displayMode ? .hidden : .visible, for: .navigationBar)
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
        case .displayMode:
            return "Display Mode"
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
