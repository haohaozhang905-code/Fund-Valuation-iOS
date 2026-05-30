//
//  LivePhotoCreatorApp.swift
//  LivePhotoCreator
//
//  Created by Bill Zhang on 2026/3/8.
//

import SwiftUI

@main
struct FundValuationApp: App {
    @AppStorage("fund_theme") private var savedTheme: String = "dark"

    var body: some Scene {
        WindowGroup {
            RootView()
                .preferredColorScheme(preferredScheme)
        }
    }

    private var preferredScheme: ColorScheme? {
        .dark
    }
}
