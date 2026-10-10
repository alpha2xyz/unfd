import SwiftUI

/// Menu bar app: lives in the menu bar, no Dock icon (LSUIElement in project.yml).
/// The menu bar shows the current keyboard language: ع or EN.
@main
struct AutoLangApp: App {
    @State private var model: AppModel

    init() {
        let model = AppModel()
        _model = State(initialValue: model)
        #if DEBUG
        PanelSnapshot.runIfAsked(model: model)
        #endif
    }

    var body: some Scene {
        MenuBarExtra {
            HomeView(model: model)
                .frame(width: 320)
                .environment(\.layoutDirection, .rightToLeft)
        } label: {
            Text(model.currentLang?.menuBarLabel ?? "ع·EN")
        }
        .menuBarExtraStyle(.window)
    }
}
