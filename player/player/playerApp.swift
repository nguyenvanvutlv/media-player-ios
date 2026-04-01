//
//  playerApp.swift
//  player
//
//  Created by nvv on 29/3/26.
//

import SwiftUI
import SwiftData

@main
struct playerApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            AppView()
        }
        .modelContainer(for: [SubtitleSettings.self])
    }
}
