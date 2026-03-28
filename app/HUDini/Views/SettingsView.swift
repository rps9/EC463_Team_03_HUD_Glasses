import SwiftUI

struct SettingsView: View {
    var body: some View {
        List {
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

#Preview {
    NavigationStack {
        SettingsView()
            .environmentObject(BluetoothDemoManager())
    }
}
