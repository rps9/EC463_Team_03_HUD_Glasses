import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var bluetoothManager: BluetoothDemoManager

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                NavigationLink {
                    AccountSettingsView()
                } label: {
                    settingsRow(
                        title: "Account Settings",
                        icon: "person.crop.circle",
                        tint: HUDTheme.rose
                    )
                }
                .buttonStyle(.plain)

                NavigationLink {
                    BluetoothDemoView()
                        .environmentObject(bluetoothManager)
                        .navigationTitle("Bluetooth")
                        .navigationBarTitleDisplayMode(.inline)
                } label: {
                    settingsRow(
                        title: "Bluetooth",
                        icon: "dot.radiowaves.left.and.right",
                        tint: HUDTheme.accent
                    )
                }
                .buttonStyle(.plain)

                NavigationLink {
                    LanguageTabContent()
                        .navigationTitle("Languages")
                        .navigationBarTitleDisplayMode(.inline)
                } label: {
                    settingsRow(
                        title: "Languages",
                        icon: "character.book.closed",
                        tint: HUDTheme.mint
                    )
                }
                .buttonStyle(.plain)

                if APIConfig.isSuggestionFeatureEnabled {
                    NavigationLink {
                        SuggestionsSettingsView()
                    } label: {
                        settingsRow(
                            title: "Suggestions",
                            icon: "quote.bubble",
                            tint: HUDTheme.amber
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 28)
        }
        .hudScreen()
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.large)
    }

    private func settingsRow(title: String, icon: String, tint: Color) -> some View {
        HUDCard {
            HStack(spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(tint.opacity(0.12))
                        .frame(width: 54, height: 54)

                    Image(systemName: icon)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(tint)
                }

                Text(title)
                    .font(.system(.headline, design: .rounded, weight: .semibold))
                    .foregroundStyle(HUDTheme.ink)

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(HUDTheme.inkMuted)
            }
        }
    }
}

#Preview {
    NavigationStack {
        SettingsView()
            .environmentObject(BluetoothDemoManager())
            .environmentObject(AuthenticationManager())
            .environmentObject(HUDConversationHistoryStore())
            .environmentObject(SuggestionProfileStore())
    }
}
