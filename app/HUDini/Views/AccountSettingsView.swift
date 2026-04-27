import SwiftUI

struct AccountSettingsView: View {
    @EnvironmentObject private var authManager: AuthenticationManager
    @EnvironmentObject private var conversationHistoryStore: HUDConversationHistoryStore
    @EnvironmentObject private var suggestionProfileStore: SuggestionProfileStore

    @State private var confirmSignOut = false
    @State private var confirmClearHistory = false
    @State private var confirmResetSuggestionProfile = false
    @State private var confirmDeleteAccount = false

    private var appVersion: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
        return "\(short) (\(build))"
    }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                HUDCard(padding: 18) {
                    HStack(alignment: .center, spacing: 16) {
                        AccountSettingsAvatarView(photoURL: authManager.accountPhotoURL)

                        VStack(alignment: .leading, spacing: 6) {
                            Text("Signed in")
                                .font(.system(.caption, design: .rounded, weight: .semibold))
                                .foregroundStyle(HUDTheme.inkMuted)

                            if let email = authManager.accountEmail {
                                Text(email)
                                    .font(.system(.body, design: .rounded, weight: .semibold))
                                    .foregroundStyle(HUDTheme.ink)
                                    .lineLimit(2)
                            } else {
                                Text("Account")
                                    .font(.system(.body, design: .rounded, weight: .semibold))
                                    .foregroundStyle(HUDTheme.ink)
                            }

                            HUDStatusPill(
                                text: authManager.accountSignInMethodDescription,
                                tint: HUDTheme.mint,
                                icon: "key.fill"
                            )
                        }

                        Spacer(minLength: 0)
                    }
                }

                HUDCard(padding: 16) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Session & security")
                            .font(.system(.headline, design: .rounded, weight: .semibold))
                            .foregroundStyle(HUDTheme.ink)
                        Text("Your access token is stored in the iOS Keychain on this device. Signing out removes it from this device.")
                            .font(.system(.footnote, design: .rounded))
                            .foregroundStyle(HUDTheme.inkMuted)
                    }
                }

                HUDCard(padding: 16) {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Account deletion")
                            .font(.system(.headline, design: .rounded, weight: .semibold))
                            .foregroundStyle(HUDTheme.ink)

                        Text("Permanently delete your HUDini account and sign out on this device.")
                            .font(.system(.footnote, design: .rounded))
                            .foregroundStyle(HUDTheme.inkMuted)

                        if !authManager.errorMessage.isEmpty {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(HUDTheme.rose)
                                    .padding(.top, 2)
                                Text(authManager.errorMessage)
                                    .font(.system(.footnote, design: .rounded))
                                    .foregroundStyle(HUDTheme.ink)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(12)
                            .background(HUDTheme.rose.opacity(0.1), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }

                        Button(role: .destructive) {
                            confirmDeleteAccount = true
                        } label: {
                            HStack {
                                if authManager.isLoading {
                                    ProgressView()
                                        .tint(HUDTheme.rose)
                                } else {
                                    Image(systemName: "person.crop.circle.badge.xmark")
                                }
                                Text("Delete account")
                                Spacer()
                            }
                            .font(.system(.subheadline, design: .rounded, weight: .semibold))
                            .foregroundStyle(HUDTheme.rose)
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.white.opacity(0.75), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .stroke(HUDTheme.rose.opacity(0.45), lineWidth: 1)
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(authManager.isLoading)
                    }
                }

                if APIConfig.privacyPolicyURL != nil || APIConfig.termsOfServiceURL != nil {
                    HUDCard(padding: 14) {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Legal")
                                .font(.system(.headline, design: .rounded, weight: .semibold))
                                .foregroundStyle(HUDTheme.ink)

                            if let url = APIConfig.privacyPolicyURL {
                                Link(destination: url) {
                                    accountLinkRow(title: "Privacy Policy", icon: "hand.raised.fill")
                                }
                            }
                            if let url = APIConfig.termsOfServiceURL {
                                Link(destination: url) {
                                    accountLinkRow(title: "Terms of Service", icon: "doc.plaintext")
                                }
                            }
                        }
                    }
                }

                VStack(spacing: 12) {
                    Button(role: .destructive) {
                        confirmSignOut = true
                    } label: {
                        HStack {
                            Image(systemName: "rectangle.portrait.and.arrow.right")
                            Text("Sign out")
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(HUDSecondaryButtonStyle(tint: HUDTheme.rose))
                }

                HUDCard(padding: 16) {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Local data on this device")
                            .font(.system(.headline, design: .rounded, weight: .semibold))
                            .foregroundStyle(HUDTheme.ink)

                        Text("These actions do not delete your server account. They only remove data stored in this app.")
                            .font(.system(.footnote, design: .rounded))
                            .foregroundStyle(HUDTheme.inkMuted)

                        Button {
                            confirmClearHistory = true
                        } label: {
                            HStack {
                                Image(systemName: "clock.arrow.circlepath")
                                Text("Clear conversation history")
                                Spacer()
                            }
                            .font(.system(.subheadline, design: .rounded, weight: .semibold))
                            .foregroundStyle(HUDTheme.ink)
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.white.opacity(0.75), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .stroke(HUDTheme.strokeStrong, lineWidth: 1)
                            }
                        }
                        .buttonStyle(.plain)

                        Button {
                            confirmResetSuggestionProfile = true
                        } label: {
                            HStack {
                                Image(systemName: "person.text.rectangle")
                                Text("Reset suggestion profile")
                                Spacer()
                            }
                            .font(.system(.subheadline, design: .rounded, weight: .semibold))
                            .foregroundStyle(HUDTheme.ink)
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.white.opacity(0.75), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .stroke(HUDTheme.strokeStrong, lineWidth: 1)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }

                HUDCard(padding: 16) {
                    HStack {
                        Text("App version")
                            .font(.system(.subheadline, design: .rounded, weight: .semibold))
                            .foregroundStyle(HUDTheme.inkMuted)
                        Spacer()
                        Text(appVersion)
                            .font(.system(.subheadline, design: .rounded, weight: .medium))
                            .foregroundStyle(HUDTheme.ink)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 28)
        }
        .hudScreen()
        .navigationTitle("Account Settings")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Sign out of HUDini on this device?", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("Sign Out", role: .destructive) {
                authManager.signOut()
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete all saved conversations from this device?", isPresented: $confirmClearHistory, titleVisibility: .visible) {
            Button("Clear History", role: .destructive) {
                conversationHistoryStore.removeAll()
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Remove your saved suggestion questionnaire from this device?", isPresented: $confirmResetSuggestionProfile, titleVisibility: .visible) {
            Button("Reset Profile", role: .destructive) {
                suggestionProfileStore.clearProfile()
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Permanently delete your HUDini account?", isPresented: $confirmDeleteAccount, titleVisibility: .visible) {
            Button("Delete Account", role: .destructive) {
                Task {
                    let deleted = await authManager.deleteAccount()
                    if deleted {
                        conversationHistoryStore.removeAll()
                        suggestionProfileStore.clearProfile()
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes your server account and removes local HUDini data from this device. This action cannot be undone.")
        }
    }

}

// MARK: - Avatar

private struct AccountSettingsAvatarView: View {
    let photoURL: URL?

    private let size: CGFloat = 56

    var body: some View {
        Group {
            if let url = photoURL {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .empty:
                        ProgressView()
                            .frame(width: size, height: size)
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    case .failure:
                        placeholder
                    @unknown default:
                        placeholder
                    }
                }
                .frame(width: size, height: size)
                .clipShape(Circle())
                .overlay {
                    Circle()
                        .stroke(HUDTheme.strokeStrong.opacity(0.55), lineWidth: 1)
                }
            } else {
                placeholder
            }
        }
    }

    private var placeholder: some View {
        ZStack {
            Circle()
                .fill(HUDTheme.accent.opacity(0.15))
                .frame(width: size, height: size)
            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: 32))
                .foregroundStyle(HUDTheme.accent)
        }
    }
}

private extension AccountSettingsView {
    private func accountLinkRow(title: String, icon: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(HUDTheme.accent)
                .frame(width: 24)
            Text(title)
                .font(.system(.subheadline, design: .rounded, weight: .semibold))
                .foregroundStyle(HUDTheme.accent)
            Spacer()
            Image(systemName: "arrow.up.right")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(HUDTheme.accent.opacity(0.7))
        }
    }
}

#Preview {
    NavigationStack {
        AccountSettingsView()
            .environmentObject(AuthenticationManager())
            .environmentObject(HUDConversationHistoryStore())
            .environmentObject(SuggestionProfileStore())
    }
}
