import SwiftUI

struct RootView: View {
    @StateObject private var authManager = AuthenticationManager()
    @State private var showSplash = true

    private enum Tab: Hashable {
        case hudDisplay
        case language
        case bluetooth
    }

    @State private var selectedTab: Tab = .hudDisplay

    var body: some View {
        Group {
            if showSplash {
                SplashView()
            } else if authManager.isAuthenticated {
                mainContentView
            } else {
                SignInView()
                    .environmentObject(authManager)
            }
        }
        .task {
            // Show splash screen for 0.7 seconds
            try? await Task.sleep(nanoseconds: 700_000_000)
            showSplash = false
        }
    }

    private var mainContentView: some View {
        NavigationStack {
            TabView(selection: $selectedTab) {
                HUDLiveView()
                    .tag(Tab.hudDisplay)
                    .tabItem { Label("HUDini", systemImage: "display") }

                LanguageTabContent()
                    .tag(Tab.language)
                    .tabItem { Label("Language", systemImage: "character.book.closed") }

                BluetoothDemoView()
                    .tag(Tab.bluetooth)
                    .tabItem { Label("Bluetooth", systemImage: "dot.radiowaves.left.and.right") }
            }
            .navigationTitle(title(for: selectedTab))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Sign Out", role: .destructive) {
                        authManager.signOut()
                    }
                }
            }
        }
    }

    private func title(for tab: Tab) -> String {
        switch tab {
        case .hudDisplay:
            return ""
        case .language:
            return "Language"
        case .bluetooth:
            return "Bluetooth"
        }
    }
}

#Preview { RootView() }
