//
//  AuthenticationManager.swift
//  HUDini
//
//  Created for authentication management
//

import Foundation
import SwiftUI
import Combine
import GoogleSignIn
import AuthenticationServices
import CryptoKit
import Security
import UIKit

class AuthenticationManager: ObservableObject {
    @Published var isAuthenticated: Bool = false
    @Published var isLoading: Bool = false
    @Published var errorMessage: String = ""
    @Published var statusMessage: String = ""
    @Published var pendingVerificationEmail: String?
    @Published private(set) var currentRole: String = "user"
    /// Held only in memory for re-attempting sign-in after email verification; not persisted.
    private var pendingVerificationPassword: String?
    @Published var isCheckingVerification: Bool = false

    private let session = URLSession.shared
    private let authProviderKey = "hudini.auth.provider"
    private let userEmailKey = "hudini.auth.email"
    private let userPictureURLKey = "hudini.auth.pictureURL"
    private let userRoleKey = "hudini.auth.role"
    private var currentAppleSignInNonce: String?

    private enum AuthProvider: String {
        case password
        case google
        case apple
    }

    private struct CredentialsBody: Encodable {
        let email: String
        let password: String
    }

    private struct SignUpBody: Encodable {
        let email: String
        let password: String
    }

    private struct GoogleAuthBody: Encodable {
        let credential: String
    }

    private struct AppleAuthBody: Encodable {
        let identity_token: String
        let nonce: String
        let full_name: String?
    }

    private struct AuthSessionResponse: Decodable {
        let access_token: String
        let expires_at: Int?
        let role: String?
        let user: User?

        struct User: Decodable {
            let email: String?
            let name: String?
            let picture: String?
            let role: String?
        }
    }

    private struct CurrentUserResponse: Decodable {
        let email: String
        let role: String
    }

    private struct APIMessageResponse: Decodable {
        let ok: Bool?
        let message: String?
    }
    
    init() {
        if let token = KeychainHelper.loadToken() {
            if JWTHelper.isExpired(token) {
                KeychainHelper.deleteToken()
                isAuthenticated = false
            } else {
                isAuthenticated = true
            }
        } else {
            isAuthenticated = false
        }
        currentRole = UserDefaults.standard.string(forKey: userRoleKey) ?? "user"
        if isAuthenticated {
            Task { @MainActor [weak self] in
                await self?.refreshCurrentUserRole()
            }
        }
    }

    /// Re-validates the stored token; signs out on expiry. Called on scene foreground.
    @MainActor
    func ensureTokenValid() {
        guard let token = KeychainHelper.loadToken() else {
            if isAuthenticated { signOut() }
            return
        }
        if JWTHelper.isExpired(token) {
            signOut()
        }
    }

    /// Email last reported by the backend or sign-in flow (may be empty for some sessions).
    var accountEmail: String? {
        let value = UserDefaults.standard.string(forKey: userEmailKey)
        return (value?.isEmpty == false) ? value : nil
    }

    /// Human-readable sign-in method for the active session.
    var accountSignInMethodDescription: String {
        switch UserDefaults.standard.string(forKey: authProviderKey) {
        case AuthProvider.google.rawValue:
            return "Google"
        case AuthProvider.apple.rawValue:
            return "Apple"
        case AuthProvider.password.rawValue:
            return "Email & password"
        default:
            return "—"
        }
    }

    /// Profile photo URL from the last sign-in (Google SDK or backend `user.picture`).
    var accountPhotoURL: URL? {
        let raw = UserDefaults.standard.string(forKey: userPictureURLKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let raw, !raw.isEmpty else { return nil }
        return URL(string: raw)
    }

    var isAdmin: Bool {
        currentRole == "admin" || currentRole == "owner"
    }
    
    @MainActor
    func signIn(email: String, password: String) async {
        isLoading = true
        errorMessage = ""
        statusMessage = ""
        
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
        request.httpBody = try? JSONEncoder().encode(CredentialsBody(email: email, password: password))
        
        do {
            let authResponse: AuthSessionResponse = try await perform(request)
            finishAuthentication(
                with: authResponse,
                email: email,
                provider: .password,
                profilePhotoURLString: authResponse.user?.picture
            )
        } catch {
            let message = presentableError(from: error, fallback: "Sign in failed. Please check your email and password.")
            if message.localizedCaseInsensitiveContains("email not verified") {
                beginPendingVerification(email: email, password: password)
                errorMessage = ""
                statusMessage = ""
            } else {
                errorMessage = message
            }
        }
        
        isLoading = false
    }
    
    @MainActor
    func signUp(email: String, password: String, confirmPassword: String) async {
        isLoading = true
        errorMessage = ""
        statusMessage = ""
        
        if email.isEmpty || password.isEmpty || confirmPassword.isEmpty {
            errorMessage = "All fields are required."
            isLoading = false
            return
        }
        if password.count < 8 {
            errorMessage = "Password must be at least 8 characters."
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
        request.httpBody = try? JSONEncoder().encode(SignUpBody(email: email, password: password))
        
        do {
            let _: AuthSessionResponse = try await perform(request)
            errorMessage = ""
            statusMessage = ""
            isAuthenticated = false
            beginPendingVerification(email: email, password: password)
        } catch {
            errorMessage = presentableError(from: error, fallback: "Sign up failed. Please try again.")
        }
        
        isLoading = false
    }

    @MainActor
    func signInWithGoogle() async {
        isLoading = true
        errorMessage = ""
        statusMessage = ""

        guard let presentingViewController = UIApplication.topViewController() else {
            errorMessage = "Unable to open Google Sign-In."
            isLoading = false
            return
        }
        guard let clientID = APIConfig.googleClientID, !clientID.isEmpty else {
            errorMessage = "Missing Google iOS client ID."
            isLoading = false
            return
        }
        guard let serverClientID = APIConfig.googleServerClientID, !serverClientID.isEmpty else {
            errorMessage = "Missing Google server client ID."
            isLoading = false
            return
        }
        guard let url = APIConfig.googleAuthURL else {
            errorMessage = "Invalid API configuration."
            isLoading = false
            return
        }

        GIDSignIn.sharedInstance.configuration = GIDConfiguration(
            clientID: clientID,
            serverClientID: serverClientID
        )

        do {
            let signInResult = try await beginGoogleSignIn(with: presentingViewController)
            let user = try await refreshGoogleTokens(for: signInResult.user)
            guard let credential = user.idToken?.tokenString, !credential.isEmpty else {
                throw AuthError.message("Google sign-in did not return an ID token.")
            }

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.httpBody = try JSONEncoder().encode(GoogleAuthBody(credential: credential))

            let authResponse: AuthSessionResponse = try await perform(request)
            let fromAPI = authResponse.user?.picture?.trimmingCharacters(in: .whitespacesAndNewlines)
            let fromGoogle = user.profile?.imageURL(withDimension: 160)?.absoluteString
            let picture = (fromAPI?.isEmpty == false) ? fromAPI : fromGoogle
            finishAuthentication(
                with: authResponse,
                email: authResponse.user?.email ?? user.profile?.email,
                provider: .google,
                profilePhotoURLString: picture
            )
        } catch {
            if isUserCancelledGoogleSignIn(error) {
                errorMessage = ""
            } else {
                errorMessage = presentableError(from: error, fallback: "Google sign-in failed. Please try again.")
            }
        }

        isLoading = false
    }

    @MainActor
    func configureSignInWithAppleRequest(_ request: ASAuthorizationAppleIDRequest) {
        let nonce = Self.randomNonceString()
        currentAppleSignInNonce = nonce
        request.requestedScopes = [.fullName, .email]
        request.nonce = Self.sha256(nonce)
    }

    @MainActor
    func signInWithApple(result: Result<ASAuthorization, Error>) async {
        isLoading = true
        errorMessage = ""
        statusMessage = ""
        defer {
            isLoading = false
            currentAppleSignInNonce = nil
        }

        guard let url = APIConfig.appleAuthURL else {
            errorMessage = "Invalid API configuration."
            return
        }

        do {
            let authorization = try result.get()
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential else {
                throw AuthError.message("Apple sign-in did not return an Apple ID credential.")
            }
            guard let identityToken = credential.identityToken,
                  let identityTokenString = String(data: identityToken, encoding: .utf8),
                  !identityTokenString.isEmpty else {
                throw AuthError.message("Apple sign-in did not return an identity token.")
            }
            guard let nonce = currentAppleSignInNonce else {
                throw AuthError.message("Apple sign-in could not be verified. Please try again.")
            }

            let fullName = credential.fullName.flatMap { components -> String? in
                let value = PersonNameComponentsFormatter().string(from: components)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return value.isEmpty ? nil : value
            }

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.httpBody = try JSONEncoder().encode(
                AppleAuthBody(
                    identity_token: identityTokenString,
                    nonce: nonce,
                    full_name: fullName
                )
            )

            let authResponse: AuthSessionResponse = try await perform(request)
            finishAuthentication(
                with: authResponse,
                email: authResponse.user?.email ?? credential.email,
                provider: .apple,
                profilePhotoURLString: nil
            )
        } catch {
            if isUserCancelledAppleSignIn(error) {
                errorMessage = ""
            } else {
                errorMessage = presentableError(from: error, fallback: "Apple sign-in failed. Please try again.")
            }
        }
    }
    
    private func parseAPIError(data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let detail = json["detail"] as? String { return detail }
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
    private func finishAuthentication(
        with response: AuthSessionResponse,
        email: String?,
        provider: AuthProvider,
        profilePhotoURLString: String?
    ) {
        KeychainHelper.saveToken(response.access_token)
        UserDefaults.standard.set(provider.rawValue, forKey: authProviderKey)
        if let email, !email.isEmpty {
            UserDefaults.standard.set(email, forKey: userEmailKey)
        }

        let fromUser = response.user?.picture?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = profilePhotoURLString?.trimmingCharacters(in: .whitespacesAndNewlines)
        let pictureToStore = (resolved?.isEmpty == false) ? resolved : (fromUser?.isEmpty == false ? fromUser : nil)
        if let pictureToStore, !pictureToStore.isEmpty {
            UserDefaults.standard.set(pictureToStore, forKey: userPictureURLKey)
        } else {
            UserDefaults.standard.removeObject(forKey: userPictureURLKey)
        }
        let resolvedRole = response.user?.role ?? response.role ?? "user"
        currentRole = resolvedRole
        UserDefaults.standard.set(resolvedRole, forKey: userRoleKey)

        isAuthenticated = true
        pendingVerificationEmail = nil
        pendingVerificationPassword = nil
        isCheckingVerification = false
        errorMessage = ""
        statusMessage = ""
    }

    @MainActor
    private func beginPendingVerification(email: String, password: String) {
        pendingVerificationEmail = email
        pendingVerificationPassword = password
        isAuthenticated = false
        isCheckingVerification = false
        errorMessage = ""
        statusMessage = ""
    }

    @MainActor
    func clearPendingVerification() {
        pendingVerificationEmail = nil
        pendingVerificationPassword = nil
        isCheckingVerification = false
        errorMessage = ""
        statusMessage = ""
    }

    @MainActor
    func checkPendingVerificationStatus() async {
        guard let email = pendingVerificationEmail,
              let password = pendingVerificationPassword,
              !isCheckingVerification else { return }
        guard let url = APIConfig.signInURL else { return }

        isCheckingVerification = true
        defer { isCheckingVerification = false }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try? JSONEncoder().encode(CredentialsBody(email: email, password: password))

        do {
            let authResponse: AuthSessionResponse = try await perform(request)
            finishAuthentication(
                with: authResponse,
                email: email,
                provider: .password,
                profilePhotoURLString: authResponse.user?.picture
            )
        } catch {
            let message = presentableError(from: error, fallback: "Verification is still pending.")
            if !message.localizedCaseInsensitiveContains("email not verified") {
                errorMessage = message
            }
        }
    }

    private func presentableError(from error: Error, fallback: String) -> String {
        if let authError = error as? AuthError {
            return authError.localizedDescription
        }
        return error.localizedDescription.isEmpty ? fallback : error.localizedDescription
    }

    private func isUserCancelledGoogleSignIn(_ error: Error) -> Bool {
        let nsError = error as NSError
        let loweredDomain = nsError.domain.lowercased()
        let loweredDescription = nsError.localizedDescription.lowercased()

        if nsError.code == NSUserCancelledError {
            return true
        }

        return loweredDomain.contains("gid") && loweredDescription.contains("cancel")
    }

    private func isUserCancelledAppleSignIn(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == ASAuthorizationError.errorDomain &&
            ASAuthorizationError.Code(rawValue: nsError.code) == .canceled
    }

    private func perform<Response: Decodable>(_ request: URLRequest) async throws -> Response {
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AuthError.message("Invalid response from server.")
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let message = parseAPIError(data: data) ?? "Request failed with status \(httpResponse.statusCode)."
            throw AuthError.http(status: httpResponse.statusCode, message: message)
        }

        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw AuthError.message("Unable to decode the server response.")
        }
    }

    private func beginGoogleSignIn(with presentingViewController: UIViewController) async throws -> GIDSignInResult {
        try await withCheckedThrowingContinuation { continuation in
            GIDSignIn.sharedInstance.signIn(withPresenting: presentingViewController) { result, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let result else {
                    continuation.resume(throwing: AuthError.message("Google sign-in did not complete."))
                    return
                }
                continuation.resume(returning: result)
            }
        }
    }

    private func refreshGoogleTokens(for user: GIDGoogleUser) async throws -> GIDGoogleUser {
        try await withCheckedThrowingContinuation { continuation in
            user.refreshTokensIfNeeded { refreshedUser, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard let refreshedUser else {
                    continuation.resume(throwing: AuthError.message("Unable to refresh Google credentials."))
                    return
                }
                continuation.resume(returning: refreshedUser)
            }
        }
    }
    
    @MainActor
    func refreshCurrentUserRole() async {
        guard let token = KeychainHelper.loadToken(),
              let url = APIConfig.authMeURL else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let response: CurrentUserResponse = try await perform(request)
            currentRole = response.role
            UserDefaults.standard.set(response.role, forKey: userRoleKey)
            if !response.email.isEmpty {
                UserDefaults.standard.set(response.email, forKey: userEmailKey)
            }
        } catch {
            if let authError = error as? AuthError, authError.httpStatus == 401 {
                signOut()
            }
            // Otherwise keep the last known role; admin tools are additive and fail closed.
        }
    }

    @MainActor
    func deleteAccount() async -> Bool {
        isLoading = true
        errorMessage = ""
        statusMessage = ""
        defer { isLoading = false }

        guard let token = KeychainHelper.loadToken(),
              let url = APIConfig.deleteAccountURL else {
            errorMessage = "Unable to delete account because the current session is missing."
            return false
        }

        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        do {
            let _: APIMessageResponse = try await perform(request)
            signOut()
            return true
        } catch {
            errorMessage = presentableError(from: error, fallback: "Account deletion failed. Please try again.")
            return false
        }
    }

    @MainActor
    func signOut() {
        KeychainHelper.deleteToken()
        UserDefaults.standard.removeObject(forKey: userEmailKey)
        UserDefaults.standard.removeObject(forKey: userPictureURLKey)
        UserDefaults.standard.removeObject(forKey: userRoleKey)

        if UserDefaults.standard.string(forKey: authProviderKey) == AuthProvider.google.rawValue {
            GIDSignIn.sharedInstance.signOut()
        }
        UserDefaults.standard.removeObject(forKey: authProviderKey)
        isAuthenticated = false
        currentRole = "user"
        pendingVerificationEmail = nil
        pendingVerificationPassword = nil
        isCheckingVerification = false
        errorMessage = ""
        statusMessage = ""
    }

    private static func sha256(_ input: String) -> String {
        let inputData = Data(input.utf8)
        let hashedData = SHA256.hash(data: inputData)
        return hashedData.map { String(format: "%02x", $0) }.joined()
    }

    private static func randomNonceString(length: Int = 32) -> String {
        precondition(length > 0)
        let charset = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        var result = ""
        var remainingLength = length

        while remainingLength > 0 {
            var random: UInt8 = 0
            let status = SecRandomCopyBytes(kSecRandomDefault, 1, &random)
            if status != errSecSuccess {
                fatalError("Unable to generate nonce. SecRandomCopyBytes failed with OSStatus \(status)")
            }

            if random < UInt8(charset.count) {
                result.append(charset[Int(random)])
                remainingLength -= 1
            }
        }

        return result
    }
}

private enum AuthError: LocalizedError {
    case message(String)
    case http(status: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .message(let message):
            return message
        case .http(_, let message):
            return message
        }
    }

    var httpStatus: Int? {
        if case .http(let status, _) = self { return status }
        return nil
    }
}

private extension UIApplication {
    static func topViewController(
        base: UIViewController? = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?
            .rootViewController
    ) -> UIViewController? {
        if let navigationController = base as? UINavigationController {
            return topViewController(base: navigationController.visibleViewController)
        }
        if let tabBarController = base as? UITabBarController, let selected = tabBarController.selectedViewController {
            return topViewController(base: selected)
        }
        if let presented = base?.presentedViewController {
            return topViewController(base: presented)
        }
        return base
    }
}
