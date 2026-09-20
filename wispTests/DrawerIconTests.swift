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

/// The frying-pan logo has to stay legible on whatever ground it lands on.
///
/// `ZcLogo`'s pan ring and handle are pure white, so on the light theme's
/// #D8D8D8 ground they disappeared and only the orange disc was left. The
/// imageset now carries an ink variant for light appearance, matching the
/// web client's `zap_cooking_logo_black.svg`.
@MainActor
struct LogoAppearanceTests {

    private func resolved(_ style: UIUserInterfaceStyle) throws -> UIImage {
        let asset = try #require(UIImage(named: "ZcLogo", in: Bundle.main, with: nil))
        return asset.imageAsset?.image(with: UITraitCollection(userInterfaceStyle: style)) ?? asset
    }

    /// Light and dark resolve to genuinely different artwork — if the
    /// appearance entry were dropped from Contents.json both sides would
    /// hand back the same PNG data and this fails.
    @Test func logo_hasDistinctLightAndDarkVariants() throws {
        let light = try resolved(.light)
        let dark = try resolved(.dark)
        #expect(light.pngData() != dark.pngData())
    }

    /// The light-appearance variant is the inked one. Counting dark opaque
    /// pixels across the whole canvas rather than sampling a coordinate
    /// keeps this honest if the artwork is ever redrawn: the ink variant
    /// has a black pan ring and handle, the white variant has no dark
    /// pixels at all beyond antialiasing.
    @Test func lightVariant_isTheInkedOne() throws {
        let lightInk = try Self.darkPixelCount(of: resolved(.light))
        let darkInk = try Self.darkPixelCount(of: resolved(.dark))
        #expect(lightInk > 500, "light variant ink px \(lightInk)")
        #expect(darkInk * 10 < lightInk, "dark variant ink px \(darkInk) vs light \(lightInk)")
    }

    /// Opaque pixels dark enough to read as ink, over a 128×128 render.
    private static func darkPixelCount(of image: UIImage) throws -> Int {
        let side = 128
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side))
        let flat = renderer.image { _ in
            image.draw(in: CGRect(x: 0, y: 0, width: side, height: side))
        }
        let cg = try #require(flat.cgImage)
        var buf = [UInt8](repeating: 0, count: side * side * 4)
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let ctx = try #require(CGContext(
            data: &buf, width: side, height: side, bitsPerComponent: 8,
            bytesPerRow: side * 4, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))

        var n = 0
        for i in stride(from: 0, to: buf.count, by: 4) {
            guard buf[i + 3] > 200 else { continue }
            let luma = (0.2126 * Double(buf[i]) + 0.7152 * Double(buf[i + 1]) + 0.0722 * Double(buf[i + 2])) / 255
            if luma < 0.25 { n += 1 }
        }
        return n
    }
}
