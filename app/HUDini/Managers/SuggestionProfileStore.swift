import Foundation
import Combine

@MainActor
final class SuggestionProfileStore: ObservableObject {
    @Published private(set) var profile: SuggestionUserProfile?

    private static let fileName = "suggestion_user_profile.json"

    private var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let folder = base.appendingPathComponent("HUDini", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent(Self.fileName, isDirectory: false)
    }

    init() {
        load()
    }

    var hasCompletedSetup: Bool {
        profile != nil
    }

    func saveProfile(_ newProfile: SuggestionUserProfile) {
        profile = newProfile
        persist()
    }

    func updateProfile(_ update: (inout SuggestionUserProfile) -> Void) {
        guard var p = profile else { return }
        update(&p)
        profile = p
        persist()
    }

    func clearProfile() {
        profile = nil
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else {
            profile = nil
            return
        }
        let decoder = JSONDecoder()
        profile = try? decoder.decode(SuggestionUserProfile.self, from: data)
    }

    private func persist() {
        guard let profile else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        guard let data = try? encoder.encode(profile) else { return }
        try? data.write(to: fileURL, options: [.atomic])
    }
}
