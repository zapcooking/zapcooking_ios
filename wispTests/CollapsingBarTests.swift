import SwiftUI
import Testing
import UIKit
@testable import wisp

/// `CollapsingBar`, hosted in a real window and measured — not assumed.
/// The collapse hands the row's height back to the layout, and the
/// re-expansion restores the full row. The second half is the regression:
/// while collapsed, the zero-height frame proposes zero height to its own
/// content, so the height measurement must never record that proposal over
/// the row's natural size (a bar that "returns" as a sliver).
@MainActor
struct CollapsingBarTests {

    @Observable
    final class Visible {
        var flag = true
    }

    final class HeightBox {
        var value: CGFloat?
    }

    struct Probe: View {
        let box: HeightBox

        var body: some View {
            Rectangle()
                .fill(.clear)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { _, height in
                    box.value = height
                }
        }
    }

    struct Hosted: View {
        let visible: Visible
        let box: HeightBox

        var body: some View {
            CollapsingBar(visible: visible.flag, anchor: .top) {
                Color.red.frame(height: 52)
            }
            .background(Probe(box: box))
        }
    }

    @Test func hideHandsHeightBackAndReturnRestoresTheFullRow() async throws {
        let visible = Visible()
        let box = HeightBox()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.windowScene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first
        window.rootViewController = UIHostingController(rootView: Hosted(visible: visible, box: box))
        window.isHidden = false
        defer {
            window.isHidden = true
            window.rootViewController = nil
        }

        func pump(_ seconds: TimeInterval) {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end {
                RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
            }
            window.layoutIfNeeded()
        }

        pump(0.3)
        #expect(box.value == 52, "visible row lays out at its natural height, got \(box.value ?? -1)")

        visible.flag = false
        pump(0.4)
        #expect(box.value == 0, "hidden row hands its height back, got \(box.value ?? -1)")

        visible.flag = true
        pump(0.4)
        #expect(box.value == 52, "the row returns at full height after a collapse, got \(box.value ?? -1)")
    }
}
