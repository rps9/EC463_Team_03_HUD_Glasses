import SwiftUI

struct TranslationView: View {
    @StateObject private var manager = TranslationManager()
    @State private var inputText: String = ""
    @State private var selectedSourceCode: String = TranslationLanguages.autoCode
    @State private var selectedTargetCode: String = "en"
    @State private var installedSourceOptions: [TranslationLanguageOption] = TranslationLanguages.sourceOptions
    @State private var installedTargetOptions: [TranslationLanguageOption] = TranslationLanguages.targetOptions
    @FocusState private var isInputFocused: Bool

    var body: some View {
        VStack(spacing: 12) {
            Text("HUDini • Translation")
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                Text("From")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Picker("Source language", selection: $selectedSourceCode) {
                    ForEach(installedSourceOptions) { option in
                        Text(option.name).tag(option.code)
                    }
                }
                .pickerStyle(.menu)
                .onChange(of: selectedSourceCode, initial: false) { _, newValue in
                    manager.setSourceLanguage(newValue == TranslationLanguages.autoCode ? nil : newValue)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("To")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Picker("Target language", selection: $selectedTargetCode) {
                    ForEach(installedTargetOptions) { option in
                        Text(option.name).tag(option.code)
                    }
                }
                .pickerStyle(.menu)
                .onChange(of: selectedTargetCode, initial: false) { _, newValue in
                    manager.setTargetLanguage(newValue)
                }
            }

            TextEditor(text: $inputText)
                .focused($isInputFocused)
                .frame(minHeight: 120)
                .padding(8)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(alignment: .topLeading) {
                    if inputText.isEmpty {
                        Text("Enter text to translate")
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .foregroundStyle(.tertiary)
                    }
                }

            ScrollView {
                Text(manager.translatedText.isEmpty ? "Translation will appear here." : manager.translatedText)
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .frame(minHeight: 120)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12))

            HStack(spacing: 12) {
                Button("Translate") {
                    performTranslation()
                }
                .buttonStyle(.borderedProminent)
                .disabled(manager.isTranslating || inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Button("Swap") {
                    swapLanguages()
                }
                .buttonStyle(.bordered)

                Button("Clear") {
                    inputText = ""
                    manager.clear()
                    isInputFocused = true
                }
                .buttonStyle(.bordered)
            }

            if !manager.statusMessage.isEmpty {
                Text(manager.statusMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding()
        .task {
            await loadInstalledLanguages()
        }
        .onAppear {
            syncWithManager()
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if isInputFocused {
                isInputFocused = false
            }
        }
    }

    private func performTranslation() {
        Task {
            await manager.translate(inputText)
        }
    }

    private func swapLanguages() {
        guard selectedSourceCode != TranslationLanguages.autoCode else { return }
        let newTarget = selectedSourceCode
        let newSource = selectedTargetCode
        selectedSourceCode = newSource
        selectedTargetCode = newTarget

        manager.setSourceLanguage(newSource == TranslationLanguages.autoCode ? nil : newSource)
        manager.setTargetLanguage(newTarget)

        let originalInput = inputText
        inputText = manager.translatedText
        manager.translatedText = originalInput
    }

    private func syncWithManager() {
        if let source = manager.sourceLanguageCode {
            selectedSourceCode = source
        } else {
            selectedSourceCode = TranslationLanguages.autoCode
        }
        selectedTargetCode = manager.targetLanguageCode
    }

    private func loadInstalledLanguages() async {
        let source = await TranslationLanguages.installedSourceOptions()
        let target = await TranslationLanguages.installedTargetOptions()
        installedSourceOptions = source
        installedTargetOptions = target
        if !installedTargetOptions.contains(where: { $0.code == selectedTargetCode }) {
            selectedTargetCode = installedTargetOptions.first?.code ?? "en"
            manager.setTargetLanguage(selectedTargetCode)
        }
        if selectedSourceCode != TranslationLanguages.autoCode,
           !installedTargetOptions.contains(where: { $0.code == selectedSourceCode }) {
            selectedSourceCode = TranslationLanguages.autoCode
            manager.setSourceLanguage(nil)
        }
    }
}

#Preview { TranslationView() }
