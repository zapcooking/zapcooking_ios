import Foundation
import SwiftUI
import Testing
import UIKit
@testable import wisp

/// The hosted render tests (AttachmentStrip, ColorHierarchyRender,
/// ComposeToolbar, EntryPresentation, FeedStickToTop, KeptMountedFeedBodies,
/// Lazarus renders, …) attach a `UIWindow` to the host app's first connected
/// window scene and draw or lay it out. They are only meaningful when the host
/// has a foreground-active scene. On the Studio the iOS 27.2 simulator's
/// SpringBoard sometimes aborts during a cold boot after xcodebuild has
/// launched the host; the restarted SpringBoard adopts the host in the
/// background with no scene, and ~17 render tests then fail together with
/// "drew nothing" / "did not lay out".
///
/// This probe turns that run-wide state into one explicit failure that names
/// the cause, so the gate reader re-runs (after `ci_scripts/preboot-sim.sh`)
/// instead of debugging the render tests. It checks the same two things the
/// render tests depend on: a foreground-active scene exists, and a window
/// attached to it actually draws.
@Suite(.serialized) @MainActor struct HostSceneProbeTests {
    @Test func hostApp_hasAForegroundScene_thatDraws() {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let active = scenes.filter { $0.activationState == .foregroundActive }
        #expect(!active.isEmpty, """
            Host app has no foreground-active window scene (connected scenes: \(scenes.count), \
            app state: \(UIApplication.shared.applicationState.rawValue)). Hosted render tests in this \
            run are invalid: the simulator's SpringBoard most likely restarted after the host launched. \
            Run `sh ci_scripts/preboot-sim.sh <udid>` and re-run.
            """)
        guard let scene = active.first ?? scenes.first else { return }

        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 100, height: 100))
        window.windowScene = scene
        window.backgroundColor = .black
        window.rootViewController = UIHostingController(rootView: Color.red.frame(width: 50, height: 50))
        window.isHidden = false
        defer { window.isHidden = true }
        let end = Date().addingTimeInterval(0.5)
        while Date() < end { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
        window.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        #expect(Self.hasContrast(image), "A window attached to the host's scene drew nothing; hosted render tests in this run are invalid.")
    }

    /// Same rule as the render tests' `isBlank`, inverted.
    private static func hasContrast(_ image: UIImage) -> Bool {
        guard let cg = image.cgImage else { return false }
        let w = cg.width, h = cg.height
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let drew: Bool = buf.withUnsafeMutableBytes { raw in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drew else { return false }
        var i = 0
        while i < buf.count {
            if abs(Int(buf[i]) - Int(buf[0])) > 24 || abs(Int(buf[i + 1]) - Int(buf[1])) > 24
                || abs(Int(buf[i + 2]) - Int(buf[2])) > 24 { return true }
            i += 4 * 7
        }
        return false
    }
}
