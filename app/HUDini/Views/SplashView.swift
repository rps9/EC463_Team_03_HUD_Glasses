//
//  SplashView.swift
//  HUDini
//
//  Created for app splash screen
//

import SwiftUI

struct SplashView: View {
    var body: some View {
        ZStack {
            // Background
            Color(.systemBackground)
                .ignoresSafeArea()
            
            // App Logo and Title
            VStack(spacing: 20) {
                Image("AppIconImage")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 120, height: 120)
                    .clipShape(RoundedRectangle(cornerRadius: 26))
                    .shadow(color: .black.opacity(0.2), radius: 10, x: 0, y: 5)
                
                Text("HUDini")
                    .font(.system(size: 42, weight: .bold))
                    .foregroundStyle(.primary)
            }
        }
    }
}

#Preview {
    SplashView()
}
