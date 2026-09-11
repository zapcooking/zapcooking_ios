import Foundation
import SwiftUI
import Testing
import UIKit
@testable import wisp

/// feed/onlyfood-polish gates (TestFlight 2.1 (2) follow-ups): the live rail
/// on every kind including OnlyFood, a top bar with no online-users pill and
/// no relay-count menu, the Cheffy entry behind its gate at a 44 pt target,
/// the drawer's Feed Relay row carrying the count with red-at-zero, the
/// picker staying centred with lopsided edges (hosted and measured), and the
/// bolt as the zap-glyph default with explicit picks and fiat mode untouched.
@MainActor
struct FeedTopBarPolishTests {

    private let pk = String(repeating: "ab", count: 32)
    private var everyKind: [FeedKind] {
        [
            .onlyFood,
            .follows,
            .extendedNetwork,
            .relay(url: "wss://nos.lol"),
            .relaySet(RelaySet(pubkey: pk, dTag: "cooks", name: "Cooks", relays: ["wss://nos.lol"], createdAt: 1)),
        ]
    }

    // MARK: - Item 2: live rail on OnlyFood

    @Test func liveRail_rendersOnEveryKind_includingOnlyFood() {
        for kind in everyKind {
            #expect(FeedTabRouting.showsLiveRail(for: kind), "\(kind)")
        }
    }

    // MARK: - Item 3: no online-users pill, no relay-count menu

    @Test func topBar_hasNoOnlinePillOrRelayMenu_onAnyKind() {
        // The control vocabulary itself has no pill: the only way a pill
        // could come back is a new case here, which this pins.
        #expect(Set(FeedTopBarControl.allCases) == [.avatar, .contentFilter, .feedPicker, .cheffy])
        for kind in everyKind {
            for cheffy in [true, false] {
                let controls = FeedTopBarLayout.controls(kind: kind, cheffyVisible: cheffy)
                #expect(controls.first == .avatar, "\(kind)")
                #expect(controls.contains(.feedPicker), "\(kind)")
                #expect(controls.contains(.contentFilter) == (kind != .onlyFood), "\(kind)")
                #expect(controls.contains(.cheffy) == cheffy, "\(kind) cheffy=\(cheffy)")
                #expect(controls.filter { $0 == .cheffy }.count <= 1)
            }
        }
    }

    // MARK: - Item 5: Cheffy entry

    @Test func cheffyEntry_presentWhenGateOpen_absentWhenClosed_onEveryKind() {
        for kind in everyKind {
            let open = FeedTopBarLayout.controls(kind: kind, cheffyVisible: CheffyGate.entryVisible(flagEnabled: true))
            let closed = FeedTopBarLayout.controls(kind: kind, cheffyVisible: CheffyGate.entryVisible(flagEnabled: false))
            #expect(open.contains(.cheffy), "\(kind)")
            #expect(!closed.contains(.cheffy), "\(kind)")
        }
    }

    @Test func cheffyButton_rendersAtThe44ptTarget_withAvatarWeightGlyph() {
        #expect(FeedTopBarLayout.cheffyTargetSize == 44)
        // 32 pt avatar on the leading side; the glyph sits within ±2 pt of it.
        #expect(abs(FeedTopBarLayout.cheffyGlyphSize - 32) <= 2)
        let renderer = ImageRenderer(content:
            CheffyIcon(size: FeedTopBarLayout.cheffyGlyphSize)
                .frame(width: FeedTopBarLayout.cheffyTargetSize, height: FeedTopBarLayout.cheffyTargetSize)
        )
        renderer.scale = 1
        let size = renderer.uiImage?.size ?? .zero
        #expect(size.width >= 44 && size.height >= 44, "\(size)")
    }

    // MARK: - Item 4: drawer Feed Relay row

    /// The pill was hidden on OnlyFood; the general feed's count is not that
    /// feed's connectivity, so the row shows no value there and the count
    /// on every general kind.
    @Test func drawerRelayRow_hidesTheCountOnOnlyFood_likeThePillDid() {
        #expect(DrawerRelayRow.count(kind: .onlyFood, generalConnected: 0) == nil)
        #expect(DrawerRelayRow.count(kind: .onlyFood, generalConnected: 9) == nil)
        for kind in everyKind where kind != .onlyFood {
            #expect(DrawerRelayRow.count(kind: kind, generalConnected: 0) == 0, "\(kind)")
            #expect(DrawerRelayRow.count(kind: kind, generalConnected: 4) == 4, "\(kind)")
        }
    }

    @Test func drawerRelayRow_showsTheCount_redAtZero() {
        #expect(DrawerRelayRow.value(count: 0) == "0")
        #expect(DrawerRelayRow.value(count: 7) == "7")
        #expect(DrawerRelayRow.tint(count: 0) == .red)
        #expect(DrawerRelayRow.tint(count: 1) == Color.wispRepostColor)
        #expect(DrawerRelayRow.tint(count: 12) == Color.wispRepostColor)
    }

    // MARK: - Watch-for: the picker stays centred

    /// Hosts the bar container with lopsided edges and measures the centre
    /// slot's midpoint against the bar's: the overlay centres on the bar,
    /// not on the gap the edges leave.
    @Test func feedPicker_staysCentred_whateverSitsAtTheEdges() {
        let cases: [(leading: CGFloat, trailing: CGFloat)] = [
            (32, 44),   // avatar vs. the Cheffy target
            (32 + 12 + 32, 44), // avatar + content filter vs. Cheffy
            (200, 0),   // pathological
            (0, 200),
        ]
        for edges in cases {
            let probe = FrameProbe()
            let host = Host(
                FeedTopBarFrame {
                    Color.red.frame(width: edges.leading, height: 32)
                } center: {
                    Color.blue
                        .frame(width: 120, height: 32)
                        .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { probe.center = $0 }
                } trailing: {
                    Color.green.frame(width: edges.trailing, height: 44)
                }
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { probe.bar = $0 }
                .padding(.horizontal, 16)
            )
            host.pump(0.3)
            guard let bar = probe.bar, let center = probe.center else {
                Issue.record("bar did not lay out for edges \(edges)")
                continue
            }
            #expect(abs(center.midX - bar.midX) < 1, "edges \(edges): centre \(center.midX) vs bar \(bar.midX)")
            #expect(center.width == 120)
        }
    }

    // MARK: - Item 6: zap glyph default

    @Test func zapGlyph_defaultsToBolt_onFreshInstall() {
        #expect(AppSettings.ZapIconStyle.default == .bolt)
        #expect(AppSettings.ZapIconStyle.resolve(stored: nil) == .bolt)
        // An unknown raw value is "unset", not "bitcoin".
        #expect(AppSettings.ZapIconStyle.resolve(stored: "junk") == .bolt)
    }

    @Test func zapGlyph_explicitBitcoinPick_survives_andFiatStillCoinStack() {
        #expect(AppSettings.ZapIconStyle.resolve(stored: "bitcoin") == .bitcoin)
        #expect(AppSettings.ZapIconStyle.resolve(stored: "bolt") == .bolt)
        #expect(AppSettings.zapGlyph(fiatMode: false, style: .bolt) == .symbol("bolt.fill"))
        #expect(AppSettings.zapGlyph(fiatMode: false, style: .bitcoin) == .symbol("bitcoinsign"))
        #expect(AppSettings.zapGlyph(fiatMode: true, style: .bolt) == .coinStack)
        #expect(AppSettings.zapGlyph(fiatMode: true, style: .bitcoin) == .coinStack)
    }
}

// MARK: - Hosting

@MainActor
private final class FrameProbe {
    var bar: CGRect?
    var center: CGRect?
}

/// A real window on the simulator, pumped by hand (the `FeedStickToTopTests`
/// pattern).
@MainActor
private final class Host {
    let window: UIWindow

    init<Root: View>(_ root: Root) {
        window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.windowScene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first
        window.rootViewController = UIHostingController(rootView: root)
        window.isHidden = false
    }

    func pump(_ seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        window.layoutIfNeeded()
    }
}
