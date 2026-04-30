import Foundation

enum SuggestionTonePreference: String, Codable, CaseIterable, Identifiable {
    case formal
    case casual
    case friendly

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .formal: return "Formal"
        case .casual: return "Casual"
        case .friendly: return "Friendly"
        }
    }
}

struct SuggestionOtherLanguage: Identifiable, Codable, Equatable, Hashable {
    var id: UUID
    var language: String
    var level: String

    init(id: UUID = UUID(), language: String = "", level: String = "") {
        self.id = id
        self.language = language
        self.level = level
    }
}

struct SuggestionUserProfile: Codable, Equatable {
    var name: String
    var nativeLanguage: String
    var otherLanguages: [SuggestionOtherLanguage]
    var homeCountryCity: String
    var dietaryRestrictions: String
    var healthConsiderations: String
    var religionCultural: String
    var foodPreferences: String
    var hobbiesInterests: String
    var favoriteTopics: String
    var topicsToAvoid: String
    var tonePreference: SuggestionTonePreference
    var personalityStyle: String
    var typicalUseCases: String
    var occupation: String
    var neverSuggestInvolving: String
    var currentLocationDisplay: String
    var lastKnownLatitude: Double?
    var lastKnownLongitude: Double?
    /// User allowed HUDini to read current location for this feature (when-in-use).
    var agreedToLocationForSuggestions: Bool

    static var empty: SuggestionUserProfile {
        SuggestionUserProfile(
            name: "",
            nativeLanguage: "",
            otherLanguages: [],
            homeCountryCity: "",
            dietaryRestrictions: "",
            healthConsiderations: "",
            religionCultural: "",
            foodPreferences: "",
            hobbiesInterests: "",
            favoriteTopics: "",
            topicsToAvoid: "",
            tonePreference: .friendly,
            personalityStyle: "",
            typicalUseCases: "",
            occupation: "",
            neverSuggestInvolving: "",
            currentLocationDisplay: "",
            lastKnownLatitude: nil,
            lastKnownLongitude: nil,
            agreedToLocationForSuggestions: false
        )
    }
}

/// Rows for the post-setup editable list.
enum SuggestionProfileFieldID: String, CaseIterable, Identifiable {
    case name
    case nativeLanguage
    case otherLanguages
    case homeCountryCity
    case dietaryRestrictions
    case healthConsiderations
    case religionCultural
    case foodPreferences
    case hobbiesInterests
    case favoriteTopics
    case topicsToAvoid
    case tonePreference
    case personalityStyle
    case typicalUseCases
    case occupation
    case neverSuggestInvolving
    case currentLocation

    var id: String { rawValue }

    var title: String {
        switch self {
        case .name: return "Name"
        case .nativeLanguage: return "Native language"
        case .otherLanguages: return "Other languages & level"
        case .homeCountryCity: return "Home country / city"
        case .dietaryRestrictions: return "Dietary restrictions / allergies"
        case .healthConsiderations: return "Health considerations"
        case .religionCultural: return "Religion / cultural considerations"
        case .foodPreferences: return "Food preferences"
        case .hobbiesInterests: return "Hobbies & interests"
        case .favoriteTopics: return "Favorite topics"
        case .topicsToAvoid: return "Things you avoid discussing"
        case .tonePreference: return "Tone preference"
        case .personalityStyle: return "Personality style"
        case .typicalUseCases: return "Typical use cases"
        case .occupation: return "Occupation / role"
        case .neverSuggestInvolving: return "Never suggest anything involving"
        case .currentLocation: return "Current location"
        }
    }
}

extension SuggestionUserProfile {
    /// Compact dictionary for sending to the suggestion API.
    /// Only includes non-empty fields. Values longer than 120 chars are truncated.
    /// Coordinates are omitted; only the friendly `currentLocationDisplay` is sent.
    func compactSnapshot() -> [String: String] {
        var dict: [String: String] = [:]

        func put(_ key: String, _ value: String) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            if trimmed.count > 120 {
                let cut = trimmed.prefix(119)
                dict[key] = String(cut) + "…"
            } else {
                dict[key] = trimmed
            }
        }

        put("name", name)
        put("native_language", nativeLanguage)
        if !otherLanguages.isEmpty {
            let joined = otherLanguages
                .map { entry -> String in
                    let lang = entry.language.trimmingCharacters(in: .whitespacesAndNewlines)
                    let level = entry.level.trimmingCharacters(in: .whitespacesAndNewlines)
                    if lang.isEmpty { return "" }
                    return level.isEmpty ? lang : "\(lang) (\(level))"
                }
                .filter { !$0.isEmpty }
                .joined(separator: ", ")
            put("other_languages", joined)
        }
        put("home_country_city", homeCountryCity)
        put("dietary_restrictions", dietaryRestrictions)
        put("health_considerations", healthConsiderations)
        put("religion_cultural", religionCultural)
        put("food_preferences", foodPreferences)
        put("hobbies_interests", hobbiesInterests)
        put("favorite_topics", favoriteTopics)
        put("topics_to_avoid", topicsToAvoid)
        put("tone_preference", tonePreference.displayName)
        put("personality_style", personalityStyle)
        put("typical_use_cases", typicalUseCases)
        put("occupation", occupation)
        put("never_suggest_involving", neverSuggestInvolving)
        put("current_location", currentLocationDisplay)

        return dict
    }

    func preview(for field: SuggestionProfileFieldID) -> String {
        switch field {
        case .name: return name
        case .nativeLanguage: return nativeLanguage
        case .otherLanguages:
            if otherLanguages.isEmpty { return "—" }
            return otherLanguages.map { "\($0.language) (\($0.level))" }.joined(separator: ", ")
        case .homeCountryCity: return homeCountryCity
        case .dietaryRestrictions: return dietaryRestrictions
        case .healthConsiderations: return healthConsiderations
        case .religionCultural: return religionCultural
        case .foodPreferences: return foodPreferences
        case .hobbiesInterests: return hobbiesInterests
        case .favoriteTopics: return favoriteTopics
        case .topicsToAvoid: return topicsToAvoid
        case .tonePreference: return tonePreference.displayName
        case .personalityStyle: return personalityStyle
        case .typicalUseCases: return typicalUseCases
        case .occupation: return occupation
        case .neverSuggestInvolving: return neverSuggestInvolving
        case .currentLocation: return currentLocationDisplay
        }
    }
}
