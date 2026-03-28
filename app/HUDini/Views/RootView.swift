import SwiftUI

struct RootView: View {
    @StateObject private var authManager = AuthenticationManager()
    @StateObject private var bluetoothManager = BluetoothDemoManager()
    @StateObject private var conversationHistoryStore = HUDConversationHistoryStore()
    @StateObject private var suggestionProfileStore = SuggestionProfileStore()
    @State private var hasEnteredApp = false
    @State private var showAppMenu = false

    var body: some View {
        Group {
            if !hasEnteredApp {
                SplashView {
                    withAnimation(.spring(response: 0.62, dampingFraction: 0.88)) {
                        hasEnteredApp = true
                    }
                }
            } else if authManager.isAuthenticated {
                mainContentView
            } else {
                SignInView()
                    .environmentObject(authManager)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .preferredColorScheme(.light)
    }

    private var mainContentView: some View {
        TabView {
            NavigationStack {
                HUDLiveView()
                    .environmentObject(bluetoothManager)
                    .environmentObject(conversationHistoryStore)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button {
                                withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
                                    showAppMenu.toggle()
                                }
                            } label: {
                                HamburgerButton(isOpen: showAppMenu)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(showAppMenu ? "Close Menu" : "Open Menu")
                        }
                    }
                    .overlay(alignment: .topTrailing) {
                        if showAppMenu {
                            ZStack(alignment: .topTrailing) {
                                Color.black.opacity(0.001)
                                    .ignoresSafeArea()
                                    .onTapGesture {
                                        withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
                                            showAppMenu = false
                                        }
                                    }

                                appMenu
                                    .padding(.top, 12)
                                    .padding(.trailing, 20)
                                    .transition(.asymmetric(insertion: .scale(scale: 0.92, anchor: .topTrailing).combined(with: .opacity), removal: .scale(scale: 0.96, anchor: .topTrailing).combined(with: .opacity)))
                                    .zIndex(2)
                            }
                        }
                    }
            }
            .tabItem {
                Label("Live", systemImage: "dot.radiowaves.left.and.right")
            }

            NavigationStack {
                ConversationHistoryView()
                    .environmentObject(conversationHistoryStore)
            }
            .tabItem {
                Label("History", systemImage: "clock.arrow.circlepath")
            }
        }
        .tint(HUDTheme.accent)
        .environmentObject(suggestionProfileStore)
    }

    private var appMenu: some View {
        VStack(alignment: .leading, spacing: 8) {
            NavigationLink {
                SettingsView()
                    .environmentObject(bluetoothManager)
                    .environmentObject(suggestionProfileStore)
            } label: {
                menuRow(title: "Settings", icon: "slider.horizontal.3")
            }
            .simultaneousGesture(TapGesture().onEnded {
                withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
                    showAppMenu = false
                }
            })

            Button {
                withAnimation(.spring(response: 0.34, dampingFraction: 0.82)) {
                    showAppMenu = false
                }
                authManager.signOut()
            } label: {
                menuRow(title: "Sign Out", icon: "rectangle.portrait.and.arrow.right", tint: HUDTheme.rose)
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .frame(width: 220, alignment: .leading)
        .background(HUDTheme.cardStrong, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(HUDTheme.stroke, lineWidth: 1)
        }
        .shadow(color: HUDTheme.shadow, radius: 24, x: 0, y: 18)
    }

    private func menuRow(title: String, icon: String, tint: Color = HUDTheme.ink) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 22)

            Text(title)
                .font(.system(.body, design: .rounded, weight: .semibold))
                .foregroundStyle(tint)

            Spacer()
        }
        .padding(.horizontal, 14)
        .frame(height: 50)
        .background(.white.opacity(0.76), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

#Preview { RootView() }

enum HUDTheme {
    static let backgroundTop = Color(red: 0.95, green: 0.97, blue: 1.0)
    static let backgroundBottom = Color(red: 0.985, green: 0.988, blue: 0.995)
    static let ink = Color(red: 0.09, green: 0.12, blue: 0.18)
    static let inkMuted = Color(red: 0.4, green: 0.46, blue: 0.54)
    static let accent = Color(red: 0.06, green: 0.42, blue: 0.95)
    static let accentSoft = Color(red: 0.72, green: 0.86, blue: 1.0)
    static let mint = Color(red: 0.18, green: 0.72, blue: 0.6)
    static let amber = Color(red: 0.96, green: 0.73, blue: 0.26)
    static let rose = Color(red: 0.9, green: 0.39, blue: 0.43)
    static let card = Color.white.opacity(0.76)
    static let cardStrong = Color.white.opacity(0.9)
    static let stroke = Color.white.opacity(0.75)
    static let strokeStrong = Color.black.opacity(0.08)
    static let shadow = Color.black.opacity(0.08)
}

struct HUDBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [HUDTheme.backgroundTop, HUDTheme.backgroundBottom],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Circle()
                .fill(HUDTheme.accentSoft.opacity(0.45))
                .frame(width: 320, height: 320)
                .blur(radius: 30)
                .offset(x: -130, y: -260)

            Circle()
                .fill(HUDTheme.mint.opacity(0.16))
                .frame(width: 260, height: 260)
                .blur(radius: 20)
                .offset(x: 150, y: -120)

            Circle()
                .fill(HUDTheme.accent.opacity(0.08))
                .frame(width: 380, height: 380)
                .blur(radius: 40)
                .offset(x: 160, y: 260)
        }
        .ignoresSafeArea()
    }
}

struct HUDCard<Content: View>: View {
    var padding: CGFloat = 22
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(HUDTheme.card, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .stroke(HUDTheme.stroke, lineWidth: 1)
            }
            .shadow(color: HUDTheme.shadow, radius: 18, x: 0, y: 10)
    }
}

struct HUDSectionHeader: View {
    let eyebrow: String
    let title: String
    var detail: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(eyebrow.uppercased())
                .font(.system(.caption, design: .rounded, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(HUDTheme.inkMuted)

            Text(title)
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .foregroundStyle(HUDTheme.ink)

            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(.system(.body, design: .rounded))
                    .foregroundStyle(HUDTheme.inkMuted)
            }
        }
    }
}

struct HUDStatusPill: View {
    let text: String
    var tint: Color = HUDTheme.accent
    var icon: String? = nil

    var body: some View {
        HStack(spacing: 8) {
            if let icon {
                Image(systemName: icon)
            }
            Text(text)
                .lineLimit(1)
        }
        .font(.system(.caption, design: .rounded, weight: .semibold))
        .foregroundStyle(tint)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(tint.opacity(0.12), in: Capsule())
    }
}

struct HUDPrimaryButtonStyle: ButtonStyle {
    var tint: Color = HUDTheme.ink
    var foreground: Color = .white

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.headline, design: .rounded, weight: .semibold))
            .foregroundStyle(foreground)
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .background(tint.opacity(configuration.isPressed ? 0.88 : 1), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .shadow(color: tint.opacity(0.22), radius: 16, x: 0, y: 10)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.16), value: configuration.isPressed)
    }
}

struct HUDSecondaryButtonStyle: ButtonStyle {
    var tint: Color = HUDTheme.ink

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.headline, design: .rounded, weight: .semibold))
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(.white.opacity(configuration.isPressed ? 0.95 : 0.72), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(HUDTheme.strokeStrong, lineWidth: 1)
            }
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.16), value: configuration.isPressed)
    }
}

struct HUDInputFieldStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 16)
            .frame(height: 56)
            .background(.white.opacity(0.88), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(HUDTheme.strokeStrong, lineWidth: 1)
            }
            .foregroundStyle(HUDTheme.ink)
    }
}

extension View {
    func hudInputFieldStyle() -> some View {
        modifier(HUDInputFieldStyle())
    }

    func hudScreen() -> some View {
        background(HUDBackground())
            .toolbarBackground(.hidden, for: .navigationBar)
    }
}

struct HamburgerButton: View {
    let isOpen: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(.white.opacity(0.78))
                .frame(width: 40, height: 40)
                .overlay {
                    Circle()
                        .stroke(HUDTheme.strokeStrong, lineWidth: 1)
                }

            VStack(spacing: 4.5) {
                Capsule()
                    .fill(HUDTheme.ink)
                    .frame(width: 16, height: 2.2)
                    .rotationEffect(.degrees(isOpen ? 45 : 0))
                    .offset(y: isOpen ? 6.5 : 0)

                Capsule()
                    .fill(HUDTheme.ink)
                    .frame(width: isOpen ? 0 : 16, height: 2.2)
                    .opacity(isOpen ? 0 : 1)

                Capsule()
                    .fill(HUDTheme.ink)
                    .frame(width: 16, height: 2.2)
                    .rotationEffect(.degrees(isOpen ? -45 : 0))
                    .offset(y: isOpen ? -6.5 : 0)
            }
            .animation(.spring(response: 0.34, dampingFraction: 0.82), value: isOpen)
        }
    }
}
