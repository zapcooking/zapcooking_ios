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
        // `&buf` would hand CGContext a pointer that is only valid for the
        // call; the context keeps it, so draw inside the scoped access.
        let drew: Bool = buf.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(
                data: raw.baseAddress, width: side, height: side, bitsPerComponent: 8,
                bytesPerRow: side * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        try #require(drew)

        var n = 0
        for i in stride(from: 0, to: buf.count, by: 4) {
            guard buf[i + 3] > 200 else { continue }
            let luma = (0.2126 * Double(buf[i]) + 0.7152 * Double(buf[i + 1]) + 0.0722 * Double(buf[i + 2])) / 255
            if luma < 0.25 { n += 1 }
        }
        return n
    }
}

/// Bar glyphs that come from the Android vector drawables rather than SF
/// Symbols. They are separate assets, and nothing in the build catches it
/// when two of them are accidentally the same artwork.
@MainActor
struct NavGlyphAssetTests {

    /// The feed tab's selected and unselected flames must be *different*
    /// drawings. They were byte-identical — both carrying Android's filled
    /// `ic_flame`, so the unselected tab rendered as a solid flame instead
    /// of the outline Android shows.
    @Test func flame_outlineAndFill_areDifferentArtwork() throws {
        let outline = try #require(UIImage(named: "ZapNavFlame"))
        let fill = try #require(UIImage(named: "ZapNavFlameFill"))
        #expect(Self.render(outline) != Self.render(fill))
    }

    /// The outline is the lighter of the two: rasterised at the same size it
    /// covers markedly fewer opaque pixels than the solid flame.
    @Test func flame_outlineIsLighterThanFill() throws {
        let outline = try #require(Self.opaqueCount(UIImage(named: "ZapNavFlame")))
        let fill = try #require(Self.opaqueCount(UIImage(named: "ZapNavFlameFill")))
        #expect(outline < fill, "outline \(outline) px vs fill \(fill) px")
    }

    /// The Gadgets cup is its own artwork, not a reused nav glyph, and it
    /// has to be template-rendered so the bar's tint reaches it.
    @Test func gadgetsCup_isBundled_andTemplateRendered() throws {
        let cup = try #require(UIImage(named: "ZapNavGadgets"))
        #expect(cup.renderingMode != .alwaysOriginal)
        for other in ["ZapNavFlame", "ZapNavRecipes"] {
            let sibling = try #require(UIImage(named: other))
            #expect(Self.render(cup) != Self.render(sibling), "cup matches \(other)")
        }
    }

    private static func render(_ image: UIImage) -> Data? {
        let side: CGFloat = 64
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { _ in
            image.draw(in: CGRect(x: 0, y: 0, width: side, height: side))
        }.pngData()
    }

    private static func opaqueCount(_ image: UIImage?) -> Int? {
        guard let image else { return nil }
        let side = 64
        let flat = UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { _ in
            image.draw(in: CGRect(x: 0, y: 0, width: side, height: side))
        }
        guard let cg = flat.cgImage,
              let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var buf = [UInt8](repeating: 0, count: side * side * 4)
        // `&buf` would hand CGContext a pointer only valid for the duration
        // of that argument, and the context outlives it — the dangling-
        // pointer form Copilot caught on #94's LogoAppearanceTests. Same
        // fix here: keep the buffer borrowed for as long as we draw.
        let drew: Bool = buf.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(
                data: raw.baseAddress, width: side, height: side, bitsPerComponent: 8,
                bytesPerRow: side * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drew else { return nil }
        return stride(from: 3, to: buf.count, by: 4).reduce(0) { $0 + (buf[$1] > 128 ? 1 : 0) }
    }
}
