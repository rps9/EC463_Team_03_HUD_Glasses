import Foundation
import Combine

@MainActor
final class HUDConversationHistoryStore: ObservableObject {
    @Published private(set) var entries: [HUDConversationHistoryEntry] = []

    private static let maxEntries = 500
    private static let fileName = "conversation_history.json"

    private let fileURL: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let folder = base.appendingPathComponent("HUDini", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        fileURL = folder.appendingPathComponent(Self.fileName, isDirectory: false)
        load()
    }

    func append(_ entry: HUDConversationHistoryEntry) {
        entries.insert(entry, at: 0)
        if entries.count > Self.maxEntries {
            entries = Array(entries.prefix(Self.maxEntries))
        }
        save()
    }

    func remove(id: UUID) {
        entries.removeAll { $0.id == id }
        save()
    }

    func removeAll() {
        entries.removeAll()
        save()
    }

    /// Distinct listening language codes present in history (newest-first order preserved).
    var distinctListeningCodes: [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for e in entries {
            if seen.insert(e.listeningLanguageCode).inserted {
                ordered.append(e.listeningLanguageCode)
            }
        }
        return ordered
    }

    /// Distinct display language codes present in history.
    var distinctDisplayCodes: [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for e in entries {
            if seen.insert(e.displayLanguageCode).inserted {
                ordered.append(e.displayLanguageCode)
            }
        }
        return ordered
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else {
            entries = []
            return
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let decoded = try? decoder.decode([HUDConversationHistoryEntry].self, from: data) {
            entries = decoded.sorted { $0.createdAt > $1.createdAt }
        } else {
            entries = []
        }
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(entries) else { return }
        try? data.write(to: fileURL, options: [.atomic])
    }
}
