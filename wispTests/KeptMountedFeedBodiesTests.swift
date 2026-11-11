import Foundation
import SwiftUI
import Testing
import UIKit
@testable import wisp

/// The keyed form of `KeptMountedFeedBodies`, hosted in a real window: a body
/// mounts on its first selection and not before, then stays mounted with its
/// `ScrollView` and offset intact while any other key mounts or shows. Three
/// lists of distinct heights stand in for the three bodies; `FeedStickToTopTests`
/// covers the two-body form and the hidden body's row cost.
@MainActor
struct KeptMountedFeedBodiesTests {

    @Test func bodyOrder_isAllCasesOrder() {
        #expect(FeedTabRouting.Body.allCases == [.onlyFood, .general, .liveVideo, .fresh])
    }

    @Test func eachBody_mountsOnFirstSelection_andKeepsItsScrollView() {
        let model = KeyedModel()
        let host = KeyedHost(KeyedHarness(model: model))
        defer { host.tearDown() }
        host.pump(0.5)

        #expect(host.scroll(for: .onlyFood) != nil, "active body mounted")
        #expect(host.scroll(for: .general) == nil, "general not mounted before it is shown")
        #expect(host.scroll(for: .liveVideo) == nil, "live not mounted before it is shown")
        guard let onlyFood = host.scroll(for: .onlyFood) else { return }
        onlyFood.setContentOffset(CGPoint(x: 0, y: 1200), animated: false)
        host.pump(0.3)

        model.active = .general
        host.pump(0.5)
        guard let general = host.scroll(for: .general) else {
            Issue.record("general did not lay out: \(host.heights())")
            return
        }
        general.setContentOffset(CGPoint(x: 0, y: 700), animated: false)
        host.pump(0.3)
        #expect(host.scroll(for: .liveVideo) == nil, "live still not mounted")

        model.active = .liveVideo
        host.pump(0.5)
        #expect(host.scroll(for: .liveVideo) != nil, "live mounted on selection")
        #expect(host.scroll(for: .onlyFood) === onlyFood, "mounting a third body keeps the first")
        #expect(host.scroll(for: .general) === general, "mounting a third body keeps the second")

        model.active = .onlyFood
        host.pump(0.5)
        #expect(host.scroll(for: .onlyFood) === onlyFood)
        #expect(abs(onlyFood.contentOffset.y - 1200) < 1, "onlyFood offset \(onlyFood.contentOffset.y)")
        model.active = .general
        host.pump(0.5)
        #expect(host.scroll(for: .general) === general)
        #expect(abs(general.contentOffset.y - 700) < 1, "general offset \(general.contentOffset.y)")
        #expect(host.scrollViews().count == 3, "one ScrollView per mounted key, none duplicated")
    }

    @Test func hiddenBodies_areNotHitTestable() {
        let model = KeyedModel()
        let host = KeyedHost(KeyedHarness(model: model))
        defer { host.tearDown() }
        host.pump(0.5)
        model.active = .general
        host.pump(0.5)
        model.active = .liveVideo
        host.pump(0.5)
        // Back to the bottom of the stack: both bodies above it are hidden.
        model.active = .onlyFood
        host.pump(0.5)

        let center = CGPoint(x: 195, y: 422)
        guard let hit = host.window.hitTest(center, with: nil),
              let onlyFood = host.scroll(for: .onlyFood) else {
            Issue.record("nothing hit-testable at the centre: \(host.heights())")
            return
        }
        #expect(hit.isDescendant(of: onlyFood), "touches pass through the hidden bodies above to the visible one")
    }
}

// MARK: - Harness

@Observable
@MainActor
private final class KeyedModel {
    var active: FeedTabRouting.Body = .onlyFood
}

/// Row counts give each body's `ScrollView` a distinct content height.
private func rowCount(_ key: FeedTabRouting.Body) -> Int {
    switch key {
    case .onlyFood: return 60
    case .general: return 40
    case .liveVideo: return 20
    case .fresh: return 30
    }
}

private struct KeyedList: View {
    let rows: Int

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(0..<rows, id: \.self) { _ in
                    Color.green.frame(height: 100)
                }
            }
        }
    }
}

private struct KeyedHarness: View {
    let model: KeyedModel

    var body: some View {
        NavigationStack {
            KeptMountedFeedBodies(active: model.active) { key in
                switch key {
                case .onlyFood: KeyedList(rows: rowCount(.onlyFood))
                case .general: KeyedList(rows: rowCount(.general))
                case .liveVideo: KeyedList(rows: rowCount(.liveVideo))
                case .fresh: KeyedList(rows: rowCount(.fresh))
                }
            }
        }
    }
}

@MainActor
private final class KeyedHost {
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

    func scrollViews() -> [UIScrollView] {
        var found: [UIScrollView] = []
        func walk(_ view: UIView) {
            if let scroll = view as? UIScrollView { found.append(scroll) }
            view.subviews.forEach(walk)
        }
        walk(window)
        return found
    }

    func scroll(for key: FeedTabRouting.Body) -> UIScrollView? {
        let height = CGFloat(rowCount(key) * 100)
        return scrollViews().first { abs($0.contentSize.height - height) < 1 }
    }

    func heights() -> [CGFloat] { scrollViews().map(\.contentSize.height) }

    func tearDown() {
        window.isHidden = true
        window.rootViewController = nil
    }
}
