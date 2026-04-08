//
//  APIConfig.swift
//  HUDini
//
//  API configuration - replace with your backend base URL
//

import Foundation

enum APIConfig {
    /// Base URL for the auth API (no trailing slash)
    static let baseURL = "https://rps9.net/hudini"
    
    static var signInURL: URL? {
        URL(string: "\(baseURL)/auth/signin")
    }
    
    static var signUpURL: URL? {
        URL(string: "\(baseURL)/auth/signup")
    }

    static var googleAuthURL: URL? {
        URL(string: "\(baseURL)/auth/google")
    }

    static var authMeURL: URL? {
        URL(string: "\(baseURL)/auth/me")
    }

    static var googleClientID: String? {
        Bundle.main.object(forInfoDictionaryKey: "GIDClientID") as? String
    }

    static var googleServerClientID: String? {
        Bundle.main.object(forInfoDictionaryKey: "GIDServerClientID") as? String
    }

    /// When `false`, hides Suggestions in Settings / Live HUD and skips OpenAI suggestion calls.
    static let isSuggestionFeatureEnabled = true

    /// Optional URL for the suggestion personalization survey (Google Form, Typeform, etc.). When `nil`, Settings hides the survey row.
    static var suggestionSurveyURL: URL? {
        nil
        // Example: URL(string: "https://forms.gle/your-form-id")
    }

    /// Optional legal / support links for Account Settings. When `nil`, the row is hidden.
    static var privacyPolicyURL: URL? { nil }
    static var termsOfServiceURL: URL? { nil }

    /// `AppStorage` / `UserDefaults` keys (avoid scattering string literals).
    enum AppStorageKey {
        static let hudSuggestionEnabled = "hudSuggestionEnabled"
        static let hudListeningLanguageCode = "hudListeningLanguageCode"
    }
}
