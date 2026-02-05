//
//  SignInView.swift
//  HUDini
//
//  Created for user authentication
//

import SwiftUI

struct SignInView: View {
    @EnvironmentObject var authManager: AuthenticationManager
    @State private var email: String = ""
    @State private var password: String = ""
    @FocusState private var focusedField: Field?
    
    private enum Field: Hashable {
        case email
        case password
    }
    
    var body: some View {
        VStack(spacing: 24) {
            // App Logo/Title
            VStack(spacing: 8) {
                Image(systemName: "display")
                    .font(.system(size: 60))
                    .foregroundStyle(.blue)
                
                Text("HUDini")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                
                Text("Sign in to continue")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 60)
            
            Spacer()
            
            // Sign In Form
            VStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Email")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    
                    TextField("Enter your email", text: $email)
                        .textFieldStyle(.roundedBorder)
                        .textContentType(.emailAddress)
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
                        .textContentType(.password)
                        .focused($focusedField, equals: .password)
                        .submitLabel(.go)
                }
                
                if !authManager.errorMessage.isEmpty {
                    Text(authManager.errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                
                Button(action: {
                    Task {
                        await authManager.signIn(email: email, password: password)
                    }
                }) {
                    HStack {
                        if authManager.isLoading {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        } else {
                            Text("Sign In")
                                .fontWeight(.semibold)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                }
                .buttonStyle(.borderedProminent)
                .disabled(authManager.isLoading || email.isEmpty || password.isEmpty)
            }
            .padding(.horizontal, 32)
            
            Spacer()
        }
        .onSubmit {
            if focusedField == .email {
                focusedField = .password
            } else {
                Task {
                    await authManager.signIn(email: email, password: password)
                }
            }
        }
    }
}

#Preview {
    SignInView()
}
