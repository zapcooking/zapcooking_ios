import Foundation
import Testing
import UIKit
@testable import wisp

/// The Gadgets converter's arithmetic, ported from Zap Cooking Android's
/// `CookingUtilitiesSheet`. Units are checked against the same factors
/// Android ships, and the temperature branch — the one that cannot be a
/// plain scale factor — is pinned in both directions.
struct CookingConverterTests {

    private func u(_ a: String) -> CookingConverter.Unit { CookingConverter.unit(a) }

    @Test func catalog_matchesAndroid() {
        #expect(CookingConverter.allUnits.map(\.abbrev) == [
            "tsp", "tbsp", "cup", "fl oz", "mL", "L",
            "g", "kg", "oz", "lb", "°C", "°F",
        ])
        #expect(CookingConverter.defaultFrom == "cup")
        #expect(CookingConverter.defaultTo == "mL")
        #expect(CookingConverter.quickPresets.map(\.label) == [
            "1 tsp", "1 tbsp", "1 cup", "250 mL", "100 g", "1 oz",
        ])
    }

    @Test func volume_convertsThroughMillilitres() throws {
        let cupToMl = try #require(CookingConverter.convert(1, from: u("cup"), to: u("mL")))
        #expect(abs(cupToMl - 236.588) < 0.001)
        let tbspToTsp = try #require(CookingConverter.convert(1, from: u("tbsp"), to: u("tsp")))
        #expect(abs(tbspToTsp - 3) < 0.001)
        let lToMl = try #require(CookingConverter.convert(2, from: u("L"), to: u("mL")))
        #expect(abs(lToMl - 2000) < 0.001)
    }

    @Test func weight_convertsThroughGrams() throws {
        let lbToG = try #require(CookingConverter.convert(1, from: u("lb"), to: u("g")))
        #expect(abs(lbToG - 453.592) < 0.001)
        let kgToOz = try #require(CookingConverter.convert(1, from: u("kg"), to: u("oz")))
        #expect(abs(kgToOz - 35.274) < 0.01)
    }

    /// Fahrenheit carries an offset, not just a ratio — the one unit a plain
    /// `toBase` factor cannot express.
    @Test func temperature_carriesTheOffset_bothWays() throws {
        let freezing = try #require(CookingConverter.convert(32, from: u("°F"), to: u("°C")))
        #expect(abs(freezing) < 0.001)
        let boiling = try #require(CookingConverter.convert(100, from: u("°C"), to: u("°F")))
        #expect(abs(boiling - 212) < 0.001)
        let oven = try #require(CookingConverter.convert(180, from: u("°C"), to: u("°F")))
        #expect(abs(oven - 356) < 0.001)
        // −40 is the crossing point, so a sign error shows up immediately.
        let crossing = try #require(CookingConverter.convert(-40, from: u("°C"), to: u("°F")))
        #expect(abs(crossing + 40) < 0.001)
    }

    /// Grams into millilitres is a density question, not a conversion.
    @Test func crossCategory_isRefused() {
        #expect(CookingConverter.convert(1, from: u("g"), to: u("mL")) == nil)
        #expect(CookingConverter.convert(1, from: u("cup"), to: u("°C")) == nil)
        #expect(CookingConverter.convert(1, from: u("lb"), to: u("L")) == nil)
    }

    @Test func sameUnit_isIdentity() throws {
        let same = try #require(CookingConverter.convert(7.5, from: u("cup"), to: u("cup")))
        #expect(same == 7.5)
    }

    /// Round-tripping must not drift — the picker's swap button relies on it.
    @Test func conversions_roundTrip() throws {
        for (a, b) in [("cup", "mL"), ("lb", "g"), ("°C", "°F"), ("tsp", "L")] {
            let there = try #require(CookingConverter.convert(3, from: u(a), to: u(b)))
            let back = try #require(CookingConverter.convert(there, from: u(b), to: u(a)))
            #expect(abs(back - 3) < 0.0001, "\(a)->\(b)->\(a) gave \(back)")
        }
    }

    @Test func formatting_matchesAndroid() {
        #expect(CookingConverter.formatResult(240) == "240")
        #expect(CookingConverter.formatResult(1) == "1")
        #expect(CookingConverter.formatResult(236.588) == "236.6")
        #expect(CookingConverter.formatResult(0.5) == "0.5")
        // Trailing zeros are trimmed rather than padded out to four digits.
        #expect(CookingConverter.formatResult(2.5) == "2.5")
    }

    /// Picking across categories drags the partner along so the pair is never
    /// left describing an impossible conversion.
    @Test func partner_staysInTheNewCategory() {
        let partner = CookingConverter.partner(for: u("°F"))
        #expect(partner.category == .temperature)
        #expect(partner != u("°F"))
        #expect(CookingConverter.partner(for: u("mL")).category == .volume)
        #expect(CookingConverter.partner(for: u("lb")).category == .weight)
    }

    /// A stored unit this build no longer ships falls back instead of trapping.
    @Test func storedUnit_fallsBackWhenUnknown() {
        #expect(CookingConverter.unit(stored: "tbsp", fallback: "cup").abbrev == "tbsp")
        #expect(CookingConverter.unit(stored: "furlong", fallback: "cup").abbrev == "cup")
        #expect(CookingConverter.unit(stored: nil, fallback: "mL").abbrev == "mL")
    }
}

/// The countdown face. Android draws its timer digits in Orbitron Bold
/// (`CookingFonts.kt`, used by both the sheet card and the floating bar);
/// iOS was falling back to SF Mono, which is why the two never matched.
@MainActor
struct TimerFontTests {

    /// The font has to be registered with the app bundle. `Font.custom`
    /// silently substitutes the body face on a miss, so a missing
    /// `UIAppFonts` entry is invisible at runtime — exactly the kind of
    /// mismatch worth failing a test over.
    @Test func orbitron_isRegisteredWithTheBundle() {
        #expect(AppFont.isOrbitronAvailable, "Orbitron-Bold is not registered; check UIAppFonts in Info.plist")
        #expect(UIFont(name: AppFont.orbitronBold, size: 28) != nil)
    }

    /// The bundled file is the same face Android ships.
    @Test func orbitron_isBundledAtTheExpectedName() throws {
        let url = try #require(Bundle.main.url(forResource: "Orbitron-Bold", withExtension: "ttf"))
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    /// Both timer surfaces draw at the sizes Android uses — 28 in the sheet
    /// card, 26 in the floating bar.
    @Test func timerDisplay_keepsItsSize() {
        for size in [CGFloat(26), 28] {
            let font = UIFont(name: AppFont.orbitronBold, size: size)
            #expect(font?.pointSize == size)
        }
    }
}
