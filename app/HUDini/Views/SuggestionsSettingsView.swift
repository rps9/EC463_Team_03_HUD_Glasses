import SwiftUI

struct SuggestionsSettingsView: View {
    @EnvironmentObject private var profileStore: SuggestionProfileStore
    @AppStorage(wrappedValue: true, APIConfig.AppStorageKey.hudSuggestionEnabled) private var suggestionEnabled: Bool

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 14) {
                HUDCard {
                    VStack(alignment: .leading, spacing: 16) {
                        Toggle("Suggested replies", isOn: $suggestionEnabled)
                            .tint(HUDTheme.accent)

                        Text("OpenAI runs when OPENAI_API_KEY is set in your Xcode scheme.")
                            .font(.system(.footnote, design: .rounded))
                            .foregroundStyle(HUDTheme.inkMuted)

                        if let surveyURL = APIConfig.suggestionSurveyURL {
                            Link(destination: surveyURL) {
                                Label("Survey", systemImage: "doc.text")
                                    .font(.system(.subheadline, design: .rounded, weight: .medium))
                            }
                            .foregroundStyle(HUDTheme.accent)
                        }
                    }
                }

                if profileStore.hasCompletedSetup {
                    NavigationLink {
                        SuggestionProfileFieldListView()
                            .environmentObject(profileStore)
                    } label: {
                        HStack {
                            Image(systemName: "person.text.rectangle")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(HUDTheme.mint)
                            Text("Your suggestion profile")
                                .font(.system(.headline, design: .rounded, weight: .semibold))
                                .foregroundStyle(HUDTheme.ink)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(HUDTheme.inkMuted)
                        }
                        .padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(HUDTheme.card, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 28, style: .continuous)
                                .stroke(HUDTheme.stroke, lineWidth: 1)
                        }
                    }
                    .buttonStyle(.plain)
                } else {
                    NavigationLink {
                        SuggestionProfileSetupView()
                            .environmentObject(profileStore)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "wand.and.stars")
                                .font(.system(size: 20, weight: .semibold))
                            Text("Setup suggestion")
                                .font(.system(.headline, design: .rounded, weight: .semibold))
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(HUDTheme.inkMuted)
                        }
                        .foregroundStyle(.white)
                        .padding(18)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(HUDTheme.accent, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                        .shadow(color: HUDTheme.accent.opacity(0.25), radius: 16, x: 0, y: 10)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 28)
        }
        .hudScreen()
        .navigationTitle("Suggestions")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationStack {
        SuggestionsSettingsView()
            .environmentObject(SuggestionProfileStore())
    }
}
