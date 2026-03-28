import SwiftUI

struct SettingsView: View {
    @AppStorage(wrappedValue: true, APIConfig.AppStorageKey.hudSuggestionEnabled) private var suggestionEnabled: Bool

    var body: some View {
        List {
            Section {
                Toggle("Suggested replies", isOn: $suggestionEnabled)

                if let surveyURL = APIConfig.suggestionSurveyURL {
                    Link(destination: surveyURL) {
                        Label {
                            Text("Take the suggestion survey for a more personalized experience")
                                .fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: "doc.text")
                        }
                    }
                }
            } header: {
                Text("Suggestions")
            } footer: {
                Text("Suggested replies use OpenAI when the OPENAI_API_KEY environment variable is set (e.g. in your Xcode scheme).")
            }

            Section {
                NavigationLink {
                    BluetoothDemoView()
                        .navigationTitle("Bluetooth")
                        .navigationBarTitleDisplayMode(.inline)
                } label: {
                    Label("Bluetooth", systemImage: "dot.radiowaves.left.and.right")
                }

                NavigationLink {
                    LanguageTabContent()
                        .navigationTitle("Language")
                        .navigationBarTitleDisplayMode(.inline)
                } label: {
                    Label("Language", systemImage: "character.book.closed")
                }
            }
        }
    }
}

#Preview {
    NavigationStack {
        SettingsView()
            .environmentObject(BluetoothDemoManager())
    }
}
