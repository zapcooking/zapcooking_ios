import Foundation
import SwiftUI
import Testing
import UIKit
@testable import wisp

/// Unified-feed PR 6 gates (§5, §6): bar membership and order, drawer-only
/// destinations, Feed's flame glyph and glyph sizes, the amber unread dot,
/// and — measured, not asserted from constants — every action-row control
/// rendering at ≥ 44×44 and the worst-case row fitting the narrowest
/// supported device.
@MainActor
struct BottomBarAndActionRowTests {

    // MARK: - §5 bottom bar

    @Test func bottomBar_isFeedRecipesSearchMessagesNotifications() {
        #expect(BottomTab.bottomBarCases == [.feed, .recipes, .search, .messages, .notifications])
        #expect(BottomTab.bottomBarCases.count == 5)
    }

    @Test func kitchenAndWallet_areDrawerOnly_andAbsentFromTheBar() {
        #expect(!BottomTab.bottomBarCases.contains(.kitchen))
        #expect(!BottomTab.bottomBarCases.contains(.wallet))
        #expect(Set(BottomTab.drawerOnlyCases) == [.kitchen, .wallet])
        // Every case is either in the bar or drawer-only — nothing is stranded.
        for tab in BottomTab.allCases {
            #expect(BottomTab.bottomBarCases.contains(tab) != BottomTab.drawerOnlyCases.contains(tab), "\(tab)")
        }
    }

    @Test func watchOnlyBar_dropsMessages_likeAndroidReadOnly() {
        #expect(BottomTab.bottomBarCases(watchOnly: true) == [.feed, .recipes, .search, .notifications])
        #expect(BottomTab.bottomBarCases(watchOnly: false) == BottomTab.bottomBarCases)
    }

    @Test func feed_usesFlame_andGlyphSizesMatchSpec() {
        #expect(BottomTab.feed.icon == "ZapNavFlame")
        #expect(BottomTab.feed.selectedIcon == "ZapNavFlameFill")
        #expect(BottomTab.feed.barGlyphSize == 26)
        for tab in BottomTab.bottomBarCases where tab != .feed {
            #expect(tab.barGlyphSize == 24, "\(tab)")
        }
        #expect(BottomTab.messages.icon == "ZapNavChat")
        #expect(BottomTab.kitchen.title == "My Kitchen")
    }

    /// Android's custom nav vectors (flame, utensils, chat, alert) carry the
    /// bar; Search keeps the SF Symbol magnifier and the drawer-only rows
    /// keep their symbols.
    @Test func customGlyphs_coverTheAndroidNavTabs_only() {
        #expect(Set(BottomTab.bottomBarCases.filter { $0.usesCustomGlyph }) == [.feed, .recipes, .messages, .notifications])
        for tab in BottomTab.bottomBarCases {
            if tab.usesCustomGlyph {
                #expect(tab.icon.hasPrefix("ZapNav"), "\(tab)")
                #expect(tab.selectedIcon.hasPrefix("ZapNav"), "\(tab)")
            } else {
                #expect(UIImage(systemName: tab.icon) != nil, "\(tab)")
            }
        }
        for tab in [BottomTab.kitchen, .wallet] {
            #expect(!tab.usesCustomGlyph, "\(tab)")
        }
    }

    @Test func unreadDot_isAmber400OnDark_amber700OnLight() {
        for (isDark, hex) in [(true, (0xFB, 0xBF, 0x24)), (false, (0xB4, 0x53, 0x09))] {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            #expect(UIColor(BottomTab.unreadDotColor(isDark: isDark)).getRed(&r, green: &g, blue: &b, alpha: &a))
            #expect(abs(r - CGFloat(hex.0) / 255) < 0.01, "isDark \(isDark)")
            #expect(abs(g - CGFloat(hex.1) / 255) < 0.01, "isDark \(isDark)")
            #expect(abs(b - CGFloat(hex.2) / 255) < 0.01, "isDark \(isDark)")
            #expect(a == 1)
        }
    }

    // MARK: - §6 action row

    @Test func actionRowItem_constantsMatchSpec() {
        #expect(ActionRowItem.targetSize == 44)
        #expect(ActionRowItem.glyphSize == 20)
    }

    /// Renders each glyph kind, with and without a count label, and measures
    /// the result: the control's frame must be at least 44×44 points.
    @Test func everyActionRowControl_rendersAtLeast44by44() {
        let glyphs: [(String, ActionRowItem.Glyph)] = [
            ("symbol", .symbol("bubble.right")),
            ("wide symbol", .symbol("arrow.2.squarepath")),
            ("chevron", .symbol("chevron.down")),
            ("image", .image(Image(systemName: "bolt.fill"))),
            ("emoji text", .text("🔥")),
            ("custom", .custom(AnyView(Color.red))),
        ]
        for (name, glyph) in glyphs {
            for label in [nil, "12", "1.2k", "0"] {
                let item = ActionRowItem(glyph: glyph, label: label, tint: nil)
                let renderer = ImageRenderer(content: item)
                renderer.scale = 1
                guard let image = renderer.uiImage else {
                    Issue.record("\(name) / \(label ?? "no label") did not render")
                    continue
                }
                #expect(image.size.width >= 44, "\(name) / \(label ?? "no label") width \(image.size.width)")
                #expect(image.size.height >= 44, "\(name) / \(label ?? "no label") height \(image.size.height)")
                if label == nil {
                    // Without a label the control IS the 44×44 target — no wider.
                    #expect(image.size.width == 44, "\(name) bare width \(image.size.width)")
                }
            }
        }
    }

    /// Narrowest supported device (iPhone SE, 375pt) minus the card's 16pt
    /// gutters leaves 343pt for the row. PostCardView's worst case is six
    /// controls with four wide counts (reply, reaction, repost and zap all
    /// at "1.2k", plus bare bookmark and expand); their measured widths
    /// must fit with room for the spacers, or the row pushes its trailing
    /// controls past the card edge.
    @Test func worstCaseRow_fitsTheNarrowestSupportedWidth() {
        let controls: [ActionRowItem] = [
            ActionRowItem(glyph: .symbol("bubble.right"), label: "1.2k"),
            ActionRowItem(glyph: .text("🔥"), label: "1.2k"),
            ActionRowItem(glyph: .symbol("arrow.2.squarepath"), label: "1.2k"),
            ActionRowItem(glyph: .image(Image(systemName: "bolt.fill")), label: "1.2k"),
            ActionRowItem(glyph: .symbol("bookmark")),
            ActionRowItem(glyph: .symbol("chevron.down")),
        ]
        var total: CGFloat = 0
        for control in controls {
            let renderer = ImageRenderer(content: control)
            renderer.scale = 1
            let width = renderer.uiImage?.size.width ?? 0
            #expect(width >= 44)
            total += width
        }
        let available: CGFloat = 375 - 2 * 16
        #expect(total <= available - 5 * 4, "row content \(total)pt of \(available)pt")
    }

    /// The adaptive Cheffy Note Review slot makes the row seven controls
    /// wide. Measured 2026-09-19 (MacBook Air, Xcode 26.3, iPhone 17 /
    /// iOS 26.2): reply "1.2k" 51, react "1.2k" 50, repost "1.2k" 54, zap
    /// "1.2k" 45, bookmark / Cheffy / expand 44 each — 332pt, over the
    /// 343pt row's gap budget at 375pt. So the slot is adaptive:
    /// `NoteReviewTrigger.inlineMinRowWidth` (356 = 7 × 44 + 6 × 4 gaps + 24
    /// count headroom) keeps a 375pt device menu-only and lets 390pt and
    /// wider carry the slot. This pins both halves: the seven-control worst
    /// case fits the threshold width with the gap rule, and does NOT fit
    /// the narrowest device.
    @Test func sevenControlRow_fitsTheInlineThreshold_notTheNarrowestDevice() {
        let controls: [ActionRowItem] = [
            ActionRowItem(glyph: .symbol("bubble.right"), label: "1.2k"),
            ActionRowItem(glyph: .text("🔥"), label: "1.2k"),
            ActionRowItem(glyph: .symbol("arrow.2.squarepath"), label: "1.2k"),
            ActionRowItem(glyph: .image(Image(systemName: "bolt.fill")), label: "1.2k"),
            ActionRowItem(glyph: .symbol("bookmark")),
            ActionRowItem(glyph: .custom(AnyView(CheffyIcon(size: ActionRowItem.glyphSize)))),
            ActionRowItem(glyph: .symbol("chevron.down")),
        ]
        var total: CGFloat = 0
        for control in controls {
            let renderer = ImageRenderer(content: control)
            renderer.scale = 1
            let width = renderer.uiImage?.size.width ?? 0
            #expect(width >= 44)
            total += width
        }
        let gaps: CGFloat = 6 * 4
        let narrowest: CGFloat = 375 - 2 * 16
        #expect(total > narrowest - gaps, "seven controls fit 375pt after all (\(total)pt) — the slot could be unconditional")
        #expect(total <= NoteReviewTrigger.inlineMinRowWidth - gaps, "seven-control worst case \(total)pt exceeds the inline threshold's budget")
        #expect(!NoteReviewTrigger.meetsInlineWidth(narrowest))
        #expect(NoteReviewTrigger.meetsInlineWidth(390 - 2 * 16))
    }

    @Test func actionRowButton_rendersItsItemAtFullTarget() {
        let button = ActionRowButton(item: ActionRowItem(glyph: .symbol("bookmark"))) {}
        let renderer = ImageRenderer(content: button)
        renderer.scale = 1
        let size = renderer.uiImage?.size ?? .zero
        #expect(size.width >= 44 && size.height >= 44, "\(size)")
    }
}
