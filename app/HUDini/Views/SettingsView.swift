import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var bluetoothManager: BluetoothDemoManager

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 20) {
                HUDSectionHeader(
                    eyebrow: "Configuration",
                    title: "Settings built like a product surface.",
                    detail: "Core controls are organized into clear modules so the app feels production-ready instead of experimental."
                )
                .padding(.horizontal, 20)
                .padding(.top, 12)

                VStack(spacing: 14) {
                    NavigationLink {
                        BluetoothDemoView()
                            .environmentObject(bluetoothManager)
                            .navigationTitle("Bluetooth")
                            .navigationBarTitleDisplayMode(.inline)
                    } label: {
                        settingsRow(
                            title: "Bluetooth",
                            subtitle: "Scan, connect, and manage the HUD transceiver.",
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
                            subtitle: "Download translation packs and manage supported speech languages.",
                            icon: "character.book.closed",
                            tint: HUDTheme.mint
                        )
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 20)
            }
            .padding(.bottom, 28)
        }
        .hudScreen()
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.large)
    }

    private func settingsRow(title: String, subtitle: String, icon: String, tint: Color) -> some View {
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

                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(.system(.headline, design: .rounded, weight: .semibold))
                        .foregroundStyle(HUDTheme.ink)

                    Text(subtitle)
                        .font(.system(.subheadline, design: .rounded))
                        .foregroundStyle(HUDTheme.inkMuted)
                }

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
    }
}
