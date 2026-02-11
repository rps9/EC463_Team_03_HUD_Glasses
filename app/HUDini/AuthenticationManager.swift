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
    func signUp(email: String, password: String, confirmPassword: String) async {
        isLoading = true
        errorMessage = ""
        
        // Simulate network delay
        try? await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
        
        // Validation
        if email.isEmpty || password.isEmpty || confirmPassword.isEmpty {
            errorMessage = "All fields are required."
        } else if password.count < 6 {
            errorMessage = "Password must be at least 6 characters."
        } else if password != confirmPassword {
            errorMessage = "Passwords do not match."
        } else if !isValidEmail(email) {
            errorMessage = "Please enter a valid email address."
        } else {
            // Success - in production, this would call an API to create the account
            isAuthenticated = true
            errorMessage = ""
        }
        
        isLoading = false
    }
    
    private func isValidEmail(_ email: String) -> Bool {
        let emailRegex = "[A-Z0-9a-z._%+-]+@[A-Za-z0-9.-]+\\.[A-Za-z]{2,64}"
        let emailPredicate = NSPredicate(format:"SELF MATCHES %@", emailRegex)
        return emailPredicate.evaluate(with: email)
    }
    
    @MainActor
    func signOut() {
        isAuthenticated = false
    }
}
