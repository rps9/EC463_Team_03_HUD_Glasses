//
//  AuthenticationManager.swift
//  HUDini
//
//  Created for authentication management
//

import Foundation
import SwiftUI
import Combine

class AuthenticationManager: ObservableObject {
    @Published var isAuthenticated: Bool = false
    @Published var isLoading: Bool = false
    @Published var errorMessage: String = ""
    
    init() {
        // Always start as not authenticated - require sign-in every time
        isAuthenticated = false
    }
    
    @MainActor
    func signIn(email: String, password: String) async {
        isLoading = true
        errorMessage = ""
        
        // Simulate network delay
        try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
        
        // Simple validation - in production, this would call an API
        if !email.isEmpty && !password.isEmpty && password.count >= 6 {
            isAuthenticated = true
            errorMessage = ""
        } else {
            errorMessage = "Invalid email or password. Password must be at least 6 characters."
        }
        
        isLoading = false
    }
    
    @MainActor
    func signOut() {
        isAuthenticated = false
    }
}
