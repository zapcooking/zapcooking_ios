import Foundation
import Testing
@testable import wisp

/// The Open-on setting: Feed by default, Recipes when the user picks it,
/// persisted across launches, and a stored value from an older build never
/// crashes the picker.
@MainActor
struct StartupScreenTests {

    @Test func theTwoChoicesCarryTheBarLabels() {
        #expect(AppSettings.StartupScreen.allCases == [.recipes, .feed])
        #expect(AppSettings.StartupScreen.recipes.label == "Recipes")
        #expect(AppSettings.StartupScreen.feed.label == "Feed")
    }

    @Test func theChoicePersistsAndRestores() {
        let settings = AppSettings.shared
        let saved = settings.startupScreen
        defer { settings.startupScreen = saved }

        settings.startupScreen = .recipes
        let stored = UserDefaults.standard.string(forKey: "wisp_settings_startup_screen")
        #expect(stored == AppSettings.StartupScreen.recipes.rawValue)
        #expect(AppSettings.StartupScreen(rawValue: stored ?? "") == .recipes)

        settings.startupScreen = .feed
        #expect(UserDefaults.standard.string(forKey: "wisp_settings_startup_screen")
                == AppSettings.StartupScreen.feed.rawValue)
    }

    /// A stored value from an older or divergent build decodes to nil, which
    /// `AppSettings.init` turns into the Feed default — never a crash.
    @Test func anUnknownStoredValueFallsBackToFeed() {
        #expect(AppSettings.StartupScreen(rawValue: "kitchen") == nil)
        #expect(AppSettings.StartupScreen(rawValue: "") == nil)
    }
}
