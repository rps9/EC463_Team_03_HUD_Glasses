import SwiftUI

struct CustomResponseSheet: View {
    let targetLanguageCode: String
    let initialEnglishText: String
    let onApply: (_ translatedNative: String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var englishDraft: String = ""
    @State private var isTranslating: Bool = false
    @State private var errorMessage: String = ""
    @FocusState private var isEditorFocused: Bool

    private var targetLanguageDisplayName: String {
        TranslationLanguages.displayName(for: targetLanguageCode)
    }

    private var canSubmit: Bool {
        !isTranslating &&
        !englishDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HUDCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Your reply (English)")
                                .font(.system(.subheadline, design: .rounded, weight: .semibold))
                                .foregroundStyle(HUDTheme.inkMuted)

                            ZStack(alignment: .topLeading) {
                                if englishDraft.isEmpty {
                                    Text("Type what you want to say…")
                                        .font(.system(.body, design: .rounded))
                                        .foregroundStyle(HUDTheme.inkMuted)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 10)
                                        .allowsHitTesting(false)
                                }
                                TextEditor(text: $englishDraft)
                                    .focused($isEditorFocused)
                                    .scrollContentBackground(.hidden)
                                    .font(.system(.body, design: .rounded))
                                    .foregroundStyle(HUDTheme.ink)
                                    .frame(minHeight: 140)
                            }
                            .padding(8)
                            .background(.white.opacity(0.85), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .stroke(HUDTheme.strokeStrong.opacity(0.6), lineWidth: 1)
                            }

                            HStack(spacing: 6) {
                                Image(systemName: "arrow.right")
                                    .foregroundStyle(HUDTheme.inkMuted)
                                Text("Will be translated to ")
                                    .foregroundStyle(HUDTheme.inkMuted)
                                + Text(targetLanguageDisplayName)
                                    .foregroundStyle(HUDTheme.ink)
                                    .fontWeight(.semibold)
                            }
                            .font(.system(.footnote, design: .rounded))
                        }
                    }

                    if !errorMessage.isEmpty {
                        HUDCard {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(HUDTheme.rose)
                                Text(errorMessage)
                                    .font(.system(.footnote, design: .rounded))
                                    .foregroundStyle(HUDTheme.ink)
                            }
                        }
                    }

                    Button(action: submit) {
                        HStack(spacing: 10) {
                            if isTranslating {
                                ProgressView().tint(.white)
                                Text("Translating…")
                            } else {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 15, weight: .bold))
                                Text("Use this reply")
                            }
                        }
                    }
                    .buttonStyle(HUDPrimaryButtonStyle(tint: HUDTheme.ink))
                    .disabled(!canSubmit)
                    .opacity(canSubmit ? 1 : 0.6)
                }
                .padding(20)
            }
            .hudScreen()
            .navigationTitle("Write your reply")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isTranslating)
                }
            }
            .onAppear {
                if englishDraft.isEmpty {
                    englishDraft = initialEnglishText
                }
                isEditorFocused = true
            }
        }
    }

    private func submit() {
        let text = englishDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        errorMessage = ""
        isTranslating = true

        Task {
            do {
                let translated = try await HUDTranslationClient.translate(
                    text: text,
                    source: "en",
                    target: targetLanguageCode
                )
                await MainActor.run {
                    isTranslating = false
                    onApply(translated)
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    isTranslating = false
                    errorMessage = "Translation failed: \(error.localizedDescription)"
                }
            }
        }
    }
}
