import SwiftUI

struct HUDiniView: View {
    @ObservedObject var transcriptionManager: TranscriptionManager
    @ObservedObject var translationManager: TranslationManager
    @State private var selectedSourceCode: String = TranslationLanguages.autoCode
    @State private var selectedTargetCode: String = "en"
    
    var body: some View {
        VStack(spacing: 12) {
            Text("HUDini")
                .font(.headline)
            
            // Source language picker
            VStack(alignment: .leading, spacing: 8) {
                Text("From")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                
                Picker("Source language", selection: $selectedSourceCode) {
                    ForEach(TranslationLanguages.sourceOptions) { option in
                        Text(option.name).tag(option.code)
                    }
                }
                .pickerStyle(.menu)
                .onChange(of: selectedSourceCode, initial: false) { _, newValue in
                    translationManager.setSourceLanguage(newValue == TranslationLanguages.autoCode ? nil : newValue)
                }
            }
            
            // Target language picker
            VStack(alignment: .leading, spacing: 8) {
                Text("To")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                
                Picker("Target language", selection: $selectedTargetCode) {
                    ForEach(TranslationLanguages.targetOptions) { option in
                        Text(option.name).tag(option.code)
                    }
                }
                .pickerStyle(.menu)
                .onChange(of: selectedTargetCode, initial: false) { _, newValue in
                    translationManager.setTargetLanguage(newValue)
                }
            }
            
            // Transcript display
            VStack(alignment: .leading, spacing: 8) {
                Text("Transcript")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                
                ScrollView {
                    Text(transcriptionManager.transcript.isEmpty ? "Transcript will appear here..." : transcriptionManager.transcript)
                        .font(.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                .frame(minHeight: 120)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            
            // Translation display
            VStack(alignment: .leading, spacing: 8) {
                Text("Translation")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                
                ScrollView {
                    Text(translationManager.translatedText.isEmpty ? "Translation will appear here after you stop recording." : translationManager.translatedText)
                        .font(.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                .frame(minHeight: 120)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            
            // Control buttons
            HStack(spacing: 12) {
                Button(transcriptionManager.isTranscribing ? "Stop" : "Start") {
                    if transcriptionManager.isTranscribing {
                        stopRecording()
                    } else {
                        startRecording()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(translationManager.isTranslating)
                
                Button("Clear") {
                    transcriptionManager.resetTranscript()
                    translationManager.clear()
                }
                .buttonStyle(.bordered)
                .disabled(transcriptionManager.isTranscribing)
            }
            
            // Status messages
            if !transcriptionManager.statusMessage.isEmpty {
                Text(transcriptionManager.statusMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            
            if !translationManager.statusMessage.isEmpty {
                Text(translationManager.statusMessage)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            
            Spacer(minLength: 0)
        }
        .padding()
        .task {
            // Request permissions on view appear
            await transcriptionManager.requestPermissions()
            translationManager.setSourceLanguage(selectedSourceCode == TranslationLanguages.autoCode ? nil : selectedSourceCode)
            translationManager.setTargetLanguage(selectedTargetCode)
        }
    }
    
    private func startRecording() {
        transcriptionManager.start()
        // Clear previous translation when starting new recording
        translationManager.clear()
    }
    
    private func stopRecording() {
        transcriptionManager.stop()
        
        // Automatically translate the transcript when stopping
        let transcript = transcriptionManager.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        if !transcript.isEmpty {
            Task {
                await translationManager.translate(transcript)
            }
        }
    }
}

#Preview {
    HUDiniView(
        transcriptionManager: TranscriptionManager(),
        translationManager: TranslationManager()
    )
}

