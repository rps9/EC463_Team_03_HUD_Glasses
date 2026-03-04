//
//  APIConfig.swift
//  HUDini
//
//  API configuration - replace with your backend base URL
//

import Foundation

enum APIConfig {
    /// Base URL for the auth API (no trailing slash)
    static let baseURL = "https://your-api.com"
    
    static var signInURL: URL? {
        URL(string: "\(baseURL)/api/auth/signin")
    }
    
    static var signUpURL: URL? {
        URL(string: "\(baseURL)/api/auth/signup")
    }
}
