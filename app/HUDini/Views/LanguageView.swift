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
        List {
            Section {
                Text("These are the same language packs as in the Translate app. Download here or in Translate → Download Languages.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Section("Languages") {
                if isLoading {
                    HStack {
                        ProgressView()
                        Text("Loading languages…")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    ForEach(languageRows) { row in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.displayName)
                                    .font(.body)
                                Text(row.language.minimalIdentifier)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            statusView(row)
                        }
                    }
                }
            }
        }
        .navigationTitle("Language")
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
    private func statusView(_ row: LanguageRow) -> some View {
        switch row.status {
        case .installed:
            Label("Downloaded", systemImage: "checkmark.circle.fill")
                .font(.subheadline)
                .foregroundStyle(.green)
        case .supported:
            Button {
                requestDownload(for: row.language)
            } label: {
                Label("Download", systemImage: "arrow.down.circle")
            }
            .buttonStyle(.bordered)
        case .unsupported:
            Text("Unsupported")
                .font(.caption)
                .foregroundStyle(.tertiary)
        @unknown default:
            Text("—")
                .foregroundStyle(.tertiary)
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

/// Tab content that shows LanguageView when Translation is available, otherwise an unavailable message.
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
        ContentUnavailableView(
            "Language",
            systemImage: "globe",
            description: Text("Language download is available on a device with iOS 26 and the Translation framework.")
        )
    }
}

#Preview {
    NavigationStack {
        if #available(iOS 26.0, *) {
            LanguageView()
        } else {
            Text("Language view requires iOS 26")
        }
    }
}
