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
        
        guard !email.isEmpty, !password.isEmpty else {
            errorMessage = "Email and password are required."
            isLoading = false
            return
        }
        
        guard let url = APIConfig.signInURL else {
            errorMessage = "Invalid API configuration."
            isLoading = false
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try? JSONEncoder().encode(["email": email, "password": password])
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                errorMessage = "Invalid response from server."
                isLoading = false
                return
            }
            if (200...299).contains(httpResponse.statusCode) {
                isAuthenticated = true
                errorMessage = ""
            } else {
                errorMessage = parseAPIError(data: data) ?? "Sign in failed. Please check your email and password."
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        
        isLoading = false
    }
    
    @MainActor
    func signUp(email: String, password: String, confirmPassword: String) async {
        isLoading = true
        errorMessage = ""
        
        if email.isEmpty || password.isEmpty || confirmPassword.isEmpty {
            errorMessage = "All fields are required."
            isLoading = false
            return
        }
        if password.count < 6 {
            errorMessage = "Password must be at least 6 characters."
            isLoading = false
            return
        }
        if password != confirmPassword {
            errorMessage = "Passwords do not match."
            isLoading = false
            return
        }
        if !isValidEmail(email) {
            errorMessage = "Please enter a valid email address."
            isLoading = false
            return
        }
        
        guard let url = APIConfig.signUpURL else {
            errorMessage = "Invalid API configuration."
            isLoading = false
            return
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try? JSONEncoder().encode([
            "email": email,
            "password": password,
            "confirmPassword": confirmPassword
        ])
        
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                errorMessage = "Invalid response from server."
                isLoading = false
                return
            }
            if (200...299).contains(httpResponse.statusCode) {
                isAuthenticated = true
                errorMessage = ""
            } else {
                errorMessage = parseAPIError(data: data) ?? "Sign up failed. Please try again."
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        
        isLoading = false
    }
    
    private func parseAPIError(data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let message = json["message"] as? String { return message }
        if let error = json["error"] as? String { return error }
        if let errors = json["errors"] as? [String], let first = errors.first { return first }
        return nil
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
