import SwiftUI

/// Menu bar app: lives in the menu bar, no Dock icon (LSUIElement in project.yml).
@main
struct AutoLangApp: App {
    var body: some Scene {
        MenuBarExtra("AutoLang", systemImage: "sparkles") {
            HomeView()
                .frame(width: 320)
        }
        .menuBarExtraStyle(.window)

        Settings {
            Text("Settings")
                .padding(24)
        }
    }
}
