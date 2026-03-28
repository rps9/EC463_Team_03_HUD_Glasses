//
//  HUDiniApp.swift
//  HUDini
//
//  Created by Ryan Smith on 10/16/25.
//

import SwiftUI
import GoogleSignIn

@main
struct HUDiniApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
                .onOpenURL { url in
                    GIDSignIn.sharedInstance.handle(url)
                }
        }
    }
}
