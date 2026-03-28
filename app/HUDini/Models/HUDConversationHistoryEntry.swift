import Foundation

struct HUDConversationHistoryEntry: Identifiable, Codable, Hashable {
    let id: UUID
    let createdAt: Date
    /// Recognized speech in the listening language (may be empty).
    let sourceText: String
    /// Text shown on the HUD / sent to translation target.
    let translatedText: String
    let listeningLanguageCode: String
    let displayLanguageCode: String
}
