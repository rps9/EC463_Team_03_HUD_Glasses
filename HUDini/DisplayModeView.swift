import SwiftUI

struct DisplayModeView: View {
    @ObservedObject var transcriptionManager: TranscriptionManager
    @ObservedObject var translationManager: TranslationManager
    
    var body: some View {
        ZStack {
            // Transparent background for see-through effect
            Color.clear
                .ignoresSafeArea()
            
            VStack {
                Spacer()
                
                // Translated text - centered with HUD styling
                ScrollView {
                    VStack {
                        Text(translationManager.translatedText.isEmpty ? "Translation will appear here" : translationManager.translatedText)
                            .font(.system(size: 28, weight: .medium, design: .rounded))
                            .multilineTextAlignment(.center)
                            .foregroundColor(.white)
                            .shadow(color: .black.opacity(0.8), radius: 4, x: 0, y: 2)
                            .shadow(color: .black.opacity(0.6), radius: 8, x: 0, y: 4)
                            .padding(.horizontal, 30)
                            .padding(.vertical, 16)
                    }
                }
                
                Spacer()
                
                // Compact Start/Stop button at the bottom
                Button(action: {
                    if transcriptionManager.isTranscribing {
                        stopRecording()
                    } else {
                        startRecording()
                    }
                }) {
                    Text(transcriptionManager.isTranscribing ? "Stop" : "Start")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 80, height: 40)
                        .background(
                            (transcriptionManager.isTranscribing ? Color.red : Color.blue)
                                .opacity(0.85)
                        )
                        .cornerRadius(20)
                        .shadow(color: .black.opacity(0.3), radius: 4, x: 0, y: 2)
                }
                .padding(.bottom, 30)
                .disabled(translationManager.isTranslating)
            }
        }
        .task {
            // Request permissions on view appear
            await transcriptionManager.requestPermissions()
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
    DisplayModeView(
        transcriptionManager: TranscriptionManager(),
        translationManager: TranslationManager()
    )
}

