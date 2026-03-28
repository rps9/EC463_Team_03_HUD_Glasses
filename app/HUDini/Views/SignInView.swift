//
//  SignInView.swift
//  HUDini
//
//  Created for user authentication
//

import SwiftUI
#if canImport(Translation)
import Translation
#endif

struct SignInView: View {
    @EnvironmentObject var authManager: AuthenticationManager
    @State private var selectedTab: AuthTab = .login
    @State private var email: String = ""
    @State private var password: String = ""
    @State private var confirmPassword: String = ""
    @State private var preferredSourceLanguageCode: String = "es"
    @State private var fireDownloadPreferredLanguage: Bool = false
    @State private var showDownloadLanguageConfirmation: Bool = false
    @FocusState private var focusedField: Field?
    
    private enum AuthTab: String, CaseIterable {
        case login = "Login"
        case signup = "Sign Up"
    }
    
    private enum Field: Hashable {
        case email
        case password
        case confirmPassword
    }
    
    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 24) {
                    // App Logo/Title
                    VStack(spacing: 8) {
                        Image("AppIconImage")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 80, height: 80)
                            .clipShape(RoundedRectangle(cornerRadius: 18))
                        
                        Text("HUDini")
                            .font(.largeTitle)
                            .fontWeight(.bold)
                        
                        Text(selectedTab == .login ? "Sign in to continue" : "Create an account")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 24)
                    
                    // Tab Picker
                    Picker("Auth Tab", selection: $selectedTab) {
                        ForEach(AuthTab.allCases, id: \.self) { tab in
                            Text(tab.rawValue).tag(tab)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 32)
                    .onChange(of: selectedTab) {
                        // Clear fields when switching tabs
                        email = ""
                        password = ""
                        confirmPassword = ""
                        preferredSourceLanguageCode = "es"
                        authManager.errorMessage = ""
                        authManager.statusMessage = ""
                    }
                    
                    // Form Content
                    VStack(spacing: 20) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Email")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            
                            TextField("Enter your email", text: $email)
                                .textFieldStyle(.roundedBorder)
                                .textContentType(selectedTab == .login ? .emailAddress : .username)
                                .keyboardType(.emailAddress)
                                .autocapitalization(.none)
                                .focused($focusedField, equals: .email)
                                .submitLabel(.next)
                        }
                        
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Password")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            
                            SecureField("Enter your password", text: $password)
                                .textFieldStyle(.roundedBorder)
                                .focused($focusedField, equals: .password)
                                .submitLabel(selectedTab == .login ? .go : .next)
                        }
                        
                        if selectedTab == .signup {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Confirm Password")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                
                                SecureField("Confirm your password", text: $confirmPassword)
                                    .textFieldStyle(.roundedBorder)
                                    .focused($focusedField, equals: .confirmPassword)
                                    .submitLabel(.go)
                            }
                            
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Language to Translate from")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                
                                Picker("Language to Translate from", selection: $preferredSourceLanguageCode) {
                                    ForEach(TranslationLanguages.sourceOptions) { option in
                                        Text(option.name).tag(option.code)
                                    }
                                }
                                .pickerStyle(.menu)
                                .tint(.primary)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color(.secondarySystemBackground))
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                            }
                        }
                        
                        if !authManager.errorMessage.isEmpty {
                            Text(authManager.errorMessage)
                                .font(.caption)
                                .foregroundStyle(.red)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        
                        Button(action: {
                            Task {
                                if selectedTab == .login {
                                    await authManager.signIn(email: email, password: password)
                                } else {
                                    await authManager.signUp(email: email, password: password, confirmPassword: confirmPassword)
                                }
                            }
                        }) {
                            HStack {
                                if authManager.isLoading {
                                    ProgressView()
                                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                } else {
                                    Text(selectedTab == .login ? "Sign In" : "Sign Up")
                                        .fontWeight(.semibold)
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .frame(height: 50)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(authManager.isLoading || email.isEmpty || password.isEmpty || (selectedTab == .signup && confirmPassword.isEmpty))
        
                        if selectedTab == .login {
                            HStack {
                                Rectangle()
                                    .fill(Color.secondary.opacity(0.25))
                                    .frame(height: 1)
                                Text("or")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Rectangle()
                                    .fill(Color.secondary.opacity(0.25))
                                    .frame(height: 1)
                            }
        
                            Button(action: {
                                Task {
                                    await authManager.signInWithGoogle()
                                }
                            }) {
                                HStack(spacing: 12) {
                                    Image(systemName: "globe")
                                        .font(.headline)
                                    Text("Continue with Google")
                                        .fontWeight(.semibold)
                                }
                                .frame(maxWidth: .infinity)
                                .frame(height: 50)
                            }
                            .buttonStyle(.bordered)
                            .disabled(authManager.isLoading)
                        }
        
                        if !authManager.statusMessage.isEmpty {
                            Text(authManager.statusMessage)
                                .font(.caption)
                                .foregroundStyle(.green)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.horizontal, 32)
                }
                .frame(maxWidth: .infinity)
                .frame(minHeight: geometry.size.height, alignment: .top)
            }
            .scrollDismissesKeyboard(.interactively)
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .onSubmit {
            if focusedField == .email {
                focusedField = .password
            } else if focusedField == .password && selectedTab == .signup {
                focusedField = .confirmPassword
            } else {
                Task {
                    if selectedTab == .login {
                        await authManager.signIn(email: email, password: password)
                    } else {
                        await authManager.signUp(email: email, password: password, confirmPassword: confirmPassword)
                    }
                }
            }
        }
    }
}

#Preview {
    SignInView()
        .environmentObject(AuthenticationManager())
}
