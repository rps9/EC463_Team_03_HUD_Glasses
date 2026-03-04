import SwiftUI

struct HUDLiveView: View {
    @StateObject private var suggestionManager = HUDSuggestionManager()
    @State private var hudBuffer: String = HUDLiveView.demoDefaults.hudText
    @State private var playbackTask: Task<Void, Never>? = nil
    @State private var isDemoRunning: Bool = false
    @State private var targetLanguage: String = "en"
    @State private var listeningLanguageCode: String = HUDLiveView.defaultListeningLanguageCode
    @State private var defaultsApplied: Bool = false

    // MARK: Demo script configuration (edit for your video)
    // Define the chunk and when (seconds after pressing Start) it should show.
    private let demoTranslationTimeline: [(chunk: String, secondsFromStart: Double)] = [
        ("Excellent", 0.7),
        ("Excellent, thank you!", 1.2),
        ("Excellent, thank you. By the way.", 2.2),
        ("Excellent, thank you. By the way, what's your name?", 3.0)
    ]
    private let suggestionRevealDelayAfterLastChunk: UInt64 = 500_000_000 // 0.5s

    // Default text values to seed the UI before playback.
    private static let demoDefaults = DemoDefaults(
        hudText: "I wanted to ask you if you know where the chemistry lab is",
        suggestionPhonetic: "Si por supuesto, esta en el primer el salon a la derechas.",
        suggestionEnglish: "Yes, of course, it's in the first room on the right."
    )

    private let demoSuggestedReplyPhonetic: String = "Mi nombre es Ryan. ¿Y tú cómo te llamas?"
    private let demoSuggestedReplyEnglish: String = "My name is Ryan. And what's your name?"

    private let hudCharacterLimit: Int = 260

    var body: some View {
        VStack(spacing: 24) {
            Spacer(minLength: 0)

            Text(hudBuffer.isEmpty ? "…" : hudBuffer)
                .font(.system(size: 40, weight: .semibold, design: .rounded))
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.6)
                .lineLimit(6)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity)
                .padding(24)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 20))

            suggestionCard

            HStack(spacing: 16) {
                Menu {
                    Picker("Listening language", selection: $listeningLanguageCode) {
                        ForEach(TranslationLanguages.supported) { option in
                            Text(option.name).tag(option.code)
                        }
                    }
                } label: {
                    Label(listeningLanguageLabel(for: listeningLanguageCode), systemImage: "ear")
                        .labelStyle(.titleAndIcon)
                }
                .menuOrder(.fixed)
                .tint(.secondary)

                Menu {
                    Picker("Target language", selection: $targetLanguage) {
                        ForEach(TranslationLanguages.targetOptions) { option in
                            Text(option.name).tag(option.code)
                        }
                    }
                } label: {
                    Label(languageLabel(for: targetLanguage), systemImage: "globe")
                        .labelStyle(.titleAndIcon)
                }
                .menuOrder(.fixed)
                .tint(.secondary)

                Button(isDemoRunning ? "Stop" : "Start") {
                    isDemoRunning ? stopDemo() : startDemo()
                }
                .buttonStyle(.borderedProminent)
                .tint(isDemoRunning ? .red : .accentColor)
                .font(.title3)
            }

            Spacer(minLength: 0)
        }
        .padding(32)
        .background(Color.black.opacity(0.02))
        .onAppear {
            applyDefaultsIfNeeded()
        }
        .onDisappear {
            playbackTask?.cancel()
            playbackTask = nil
            isDemoRunning = false
        }
    }

    private func startDemo() {
        playbackTask?.cancel()
        playbackTask = nil

        hudBuffer = HUDLiveView.demoDefaults.hudText
        suggestionManager.suggestionPhonetic = HUDLiveView.demoDefaults.suggestionPhonetic
        suggestionManager.suggestionEnglish = HUDLiveView.demoDefaults.suggestionEnglish
        isDemoRunning = true

        let timeline = demoTranslationTimeline.sorted { $0.secondsFromStart < $1.secondsFromStart }
        playbackTask = Task { [timeline, suggestionRevealDelayAfterLastChunk] in
            var lastTime: Double = 0
            for entry in timeline {
                if Task.isCancelled { break }

                let waitTime = max(0, entry.secondsFromStart - lastTime)
                lastTime = entry.secondsFromStart

                if waitTime > 0 {
                    do {
                        try await Task.sleep(nanoseconds: UInt64(waitTime * 1_000_000_000))
                    } catch {
                        break
                    }
                }

                await MainActor.run {
                    appendToHUDBuffer(entry.chunk)
                }
            }

            if Task.isCancelled { return }

            try? await Task.sleep(nanoseconds: suggestionRevealDelayAfterLastChunk)
            if Task.isCancelled { return }

            await MainActor.run {
                suggestionManager.suggestionPhonetic = demoSuggestedReplyPhonetic
                suggestionManager.suggestionEnglish = demoSuggestedReplyEnglish
            }
        }
    }

    private func appendToHUDBuffer(_ chunk: String) {
        let trimmed = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let limited = trimmed.count > hudCharacterLimit ? String(trimmed.suffix(hudCharacterLimit)) : trimmed
        hudBuffer = limited
    }

    private var suggestionCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Suggested reply")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                Text(suggestionManager.suggestionPhonetic.isEmpty ? "Suggestions appear while listening." : suggestionManager.suggestionPhonetic)
                    .font(.title3)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if !suggestionManager.suggestionEnglish.isEmpty {
                    Text(suggestionManager.suggestionEnglish)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .background(Color(.tertiarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 16))
        }
    }

    private func languageLabel(for code: String) -> String {
        TranslationLanguages.targetOptions.first(where: { $0.code == code })?.name ?? code.uppercased()
    }

    private func listeningLanguageLabel(for code: String) -> String {
        TranslationLanguages.supported.first(where: { $0.code == code })?.name ?? code.uppercased()
    }

    private func applyDefaultsIfNeeded() {
        guard !defaultsApplied else { return }
        defaultsApplied = true
        hudBuffer = HUDLiveView.demoDefaults.hudText
        suggestionManager.suggestionPhonetic = HUDLiveView.demoDefaults.suggestionPhonetic
        suggestionManager.suggestionEnglish = HUDLiveView.demoDefaults.suggestionEnglish
    }

    private func stopDemo() {
        playbackTask?.cancel()
        playbackTask = nil
        isDemoRunning = false
    }
}

#Preview { HUDLiveView() }

private extension HUDLiveView {
    static var defaultListeningLanguageCode: String {
        if #available(iOS 16.0, *) {
            if let current = Locale.current.language.languageCode?.identifier,
               TranslationLanguages.supported.contains(where: { $0.code == current }) {
                return current
            }
        }

        let identifier = Locale.current.identifier
        if let prefix = identifier.split(separator: "_").first,
           TranslationLanguages.supported.contains(where: { $0.code == String(prefix) }) {
            return String(prefix)
        }

        return "en"
    }

    struct DemoDefaults {
        let hudText: String
        let suggestionPhonetic: String
        let suggestionEnglish: String
    }
}
