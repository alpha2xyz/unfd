import Testing
@testable import AutoLang

/// Swift Testing. UI types are MainActor, so the suite runs on the main actor.
@MainActor
struct AutoLangTests {
    @Test func homeViewBuilds() {
        _ = HomeView()
    }
}
