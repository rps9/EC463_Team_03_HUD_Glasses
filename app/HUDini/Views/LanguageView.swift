import SwiftUI
#if canImport(Translation)
import Translation
#endif

#if canImport(Translation)
@available(iOS 26.0, *)
struct LanguageView: View {
    private let languageAvailability = LanguageAvailability()
    private let referenceLanguage = Locale.Language(identifier: "en")

    @State private var languageRows: [LanguageRow] = []
    @State private var isLoading = true
    @State private var downloadConfiguration: TranslationSession.Configuration?
    @State private var downloadTapped = false
    @State private var errorMessage: String?
    @State private var showError = false

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                HUDCard {
                    HUDSectionHeader(
                        eyebrow: "Languages",
                        title: "Manage translation packs.",
                        detail: "These match the packs used by the system Translate app, so downloaded languages are shared across the device."
                    )
                }

                HUDCard {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Available Downloads")
                            .font(.system(.headline, design: .rounded, weight: .semibold))
                            .foregroundStyle(HUDTheme.ink)

                        if isLoading {
                            HStack(spacing: 12) {
                                ProgressView()
                                Text("Loading languages...")
                                    .font(.system(.body, design: .rounded))
                                    .foregroundStyle(HUDTheme.inkMuted)
                            }
                        } else {
                            VStack(spacing: 12) {
                                ForEach(languageRows) { row in
                                    languageRow(row)
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 18)
        }
        .hudScreen()
        .task {
            await loadLanguages()
        }
        .translationTask(downloadConfiguration) { session in
            if downloadTapped {
                do {
                    try await session.prepareTranslation()
                    await loadLanguages()
                } catch {
                    errorMessage = error.localizedDescription
                    showError = true
                }
                downloadTapped = false
            }
        }
        .alert("Download error", isPresented: $showError) {
            Button("OK") { errorMessage = nil }
        } message: {
            if let msg = errorMessage {
                Text(msg)
            }
        }
    }

    @ViewBuilder
    private func languageRow(_ row: LanguageRow) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(row.displayName)
                    .font(.system(.body, design: .rounded, weight: .semibold))
                    .foregroundStyle(HUDTheme.ink)

                Text(row.language.minimalIdentifier.uppercased())
                    .font(.system(.caption, design: .rounded, weight: .semibold))
                    .foregroundStyle(HUDTheme.inkMuted)
            }

            Spacer()

            statusView(row)
        }
        .padding(16)
        .background(.white.opacity(0.72), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    @ViewBuilder
    private func statusView(_ row: LanguageRow) -> some View {
        switch row.status {
        case .installed:
            HUDStatusPill(text: "Downloaded", tint: HUDTheme.mint, icon: "checkmark.circle.fill")
        case .supported:
            Button {
                requestDownload(for: row.language)
            } label: {
                Text("Download")
            }
            .buttonStyle(HUDSecondaryButtonStyle(tint: HUDTheme.accent))
            .frame(width: 128)
        case .unsupported:
            HUDStatusPill(text: "Unsupported", tint: HUDTheme.amber, icon: "slash.circle")
        @unknown default:
            HUDStatusPill(text: "Unknown", tint: HUDTheme.inkMuted, icon: "questionmark.circle")
        }
    }

    private func loadLanguages() async {
        isLoading = true
        let supported = await languageAvailability.supportedLanguages
        let referenceId = referenceLanguage.minimalIdentifier
        var rows: [LanguageRow] = []
        for language in supported {
            let id = language.minimalIdentifier
            if id == referenceId { continue }
            let status = await languageAvailability.status(from: referenceLanguage, to: language)
            let displayName = displayName(for: language)
            rows.append(LanguageRow(language: language, displayName: displayName, status: status))
        }
        languageRows = rows.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
        isLoading = false
    }

    private func displayName(for language: Locale.Language) -> String {
        let locale = Locale.current
        if let code = language.languageCode?.identifier {
            return locale.localizedString(forLanguageCode: code) ?? code
        }
        return language.minimalIdentifier
    }

    private func requestDownload(for language: Locale.Language) {
        downloadConfiguration?.invalidate()
        downloadConfiguration = TranslationSession.Configuration(
            source: referenceLanguage,
            target: language
        )
        downloadTapped = true
    }
}

private struct LanguageRow: Identifiable {
    let language: Locale.Language
    let displayName: String
    let status: LanguageAvailability.Status

    var id: String { language.minimalIdentifier }
}
#endif

struct LanguageTabContent: View {
    var body: some View {
        #if canImport(Translation)
        if #available(iOS 26.0, *) {
            LanguageView()
        } else {
            languageUnavailableView
        }
        #else
        languageUnavailableView
        #endif
    }

    private var languageUnavailableView: some View {
        ZStack {
            HUDBackground()

            VStack(spacing: 18) {
                Image(systemName: "globe")
                    .font(.system(size: 42, weight: .semibold))
                    .foregroundStyle(HUDTheme.accent)

                Text("Language downloads require iOS 26 and the Translation framework.")
                    .font(.system(.body, design: .rounded))
                    .foregroundStyle(HUDTheme.inkMuted)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 280)
            }
            .padding(28)
            .background(HUDTheme.cardStrong, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .stroke(HUDTheme.stroke, lineWidth: 1)
            }
            .padding(24)
        }
    }
}

#Preview {
    NavigationStack {
        LanguageTabContent()
    }
}
