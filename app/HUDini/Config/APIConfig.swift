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
}
