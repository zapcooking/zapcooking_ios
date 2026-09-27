import Foundation
import Testing
@testable import wisp

/// The Open-on setting: Feed by default, Recipes when the user picks it,
/// persisted across launches, and a stored value from an older build never
/// crashes the picker. The decode helper is exactly what `AppSettings.init`
/// runs against UserDefaults, so these tests cover the load path.
@MainActor
struct StartupScreenTests {

    @Test func theTwoChoicesCarryTheBarLabels() {
        #expect(AppSettings.StartupScreen.allCases == [.recipes, .feed])
        #expect(AppSettings.StartupScreen.recipes.label == "Recipes")
        #expect(AppSettings.StartupScreen.feed.label == "Feed")
    }

    /// What the settings initializer loads for every stored value: the real
    /// decode, not just the enum's failable init.
    @Test func theStoredValueLoadsAsTheChosenScreen() {
        #expect(AppSettings.decodeStartupScreen(nil) == .feed)
        #expect(AppSettings.decodeStartupScreen("feed") == .feed)
        #expect(AppSettings.decodeStartupScreen("recipes") == .recipes)
        #expect(AppSettings.decodeStartupScreen("kitchen") == .feed)
        #expect(AppSettings.decodeStartupScreen("") == .feed)
    }

    @Test func theChoicePersistsAndRestores() {
        let settings = AppSettings.shared
        let saved = settings.startupScreen
        defer { settings.startupScreen = saved }

        settings.startupScreen = .recipes
        #expect(UserDefaults.standard.string(forKey: "wisp_settings_startup_screen") == "recipes")
        #expect(AppSettings.decodeStartupScreen(
            UserDefaults.standard.string(forKey: "wisp_settings_startup_screen")
        ) == .recipes)

        settings.startupScreen = .feed
        #expect(UserDefaults.standard.string(forKey: "wisp_settings_startup_screen") == "feed")
        #expect(AppSettings.decodeStartupScreen(
            UserDefaults.standard.string(forKey: "wisp_settings_startup_screen")
        ) == .feed)
    }
}
