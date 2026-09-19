import Testing
import UIKit
@testable import wisp

/// Every glyph in the drawer's Settings section has to resolve on iOS.
///
/// A name SF Symbols does not ship renders as nothing — no crash, no
/// warning, just a blank row — and macOS and iOS do not carry identical
/// catalogs, so checking a symbol on the build host proves nothing about
/// the app. This runs on the simulator, where it counts.
@MainActor
struct DrawerIconTests {

    /// Keep in sync with `SidebarDrawerView.settingsItems`.
    static let settingsIcons = [
        "paintpalette",                          // Interface
        "server.rack",                           // Relays
        "cloud",                                 // Media Servers
        "key",                                   // Keys
        "hand.raised",                           // Safety
        "shield",                                // Proof of Work
        "point.3.connected.trianglepath.dotted", // Social Graph
        "face.smiling",                          // Custom Emojis
        "info.circle",                           // About
    ]

    @Test func everySettingsIcon_resolvesOnThisPlatform() {
        for name in Self.settingsIcons {
            #expect(UIImage(systemName: name) != nil, "\(name) does not resolve")
        }
    }

    /// Interface is the artist's palette, matching Android's
    /// `Icons.Outlined.Palette` in `WispDrawerContent.kt`.
    @Test func interfaceIcon_isThePalette() {
        #expect(Self.settingsIcons.first == "paintpalette")
    }
}
