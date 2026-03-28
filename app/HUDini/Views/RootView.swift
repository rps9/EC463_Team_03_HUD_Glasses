import SwiftUI

struct RootView: View {
    @StateObject private var authManager = AuthenticationManager()
    @StateObject private var bluetoothManager = BluetoothDemoManager()
    @State private var showSplash = true

    private enum Tab: Hashable {
        case hudDisplay
        case settings
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
                    .environmentObject(bluetoothManager)
                    .tag(Tab.hudDisplay)
                    .tabItem { Label("HUDini", systemImage: "display") }

                SettingsView()
                    .environmentObject(bluetoothManager)
                    .tag(Tab.settings)
                    .tabItem { Label("Settings", systemImage: "gearshape") }
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
        // TabView does not reliably inherit environment for tab roots; attach above the stack.
        .environmentObject(bluetoothManager)
    }

    private func title(for tab: Tab) -> String {
        switch tab {
        case .hudDisplay:
            return ""
        case .settings:
            return "Settings"
        }
    }
}

#Preview { RootView() }
