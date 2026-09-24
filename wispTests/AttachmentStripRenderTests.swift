import Foundation
import SwiftUI
import Testing
import UIKit
@testable import wisp

/// Renders the composer's attachment strip with known slots (described,
/// undescribed, video) at 375pt and writes a PNG so the chip layout is
/// verifiable without a device. Hermetic: the slots render from localBytes,
/// never the network.
@MainActor
struct AttachmentStripRenderTests {

    private func freshKeypair() -> Keypair {
        let priv = Schnorr.randomPrivkey()
        let pub = try! Schnorr.xonlyPubkey(privkey32: priv)
        return Keypair(privkey: Hex.encode(priv), pubkey: Hex.encode(pub))
    }

    private func solidJPEG(_ rgb: (CGFloat, CGFloat, CGFloat), size: CGSize = CGSize(width: 300, height: 300)) -> Data {
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { ctx in
            UIColor(red: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1).setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: size.width, height: size.height))
        }
        return image.jpegData(compressionQuality: 0.9) ?? Data()
    }

    @Test func strip_renders_chipsOnTopLeadingCorner() throws {
        let kp = freshKeypair()
        let key = "compose_autosave_new_\(kp.pubkey)"
        UserDefaults.standard.removeObject(forKey: key)
        let vm = ComposeViewModel(keypair: kp, mode: .new)
        vm.updateContent("Soup night")
        // The WIDE slot is the regression: a 16:9 source made `scaledToFill`
        // grow the cell's layout union to ~142pt in an 80pt cell, which
        // center-aligned the ZStack and pushed the alt chip half out of the
        // clip ("off screen"). Square images never showed it.
        let wide = ComposeAttachment(
            id: UUID(), url: "https://blossom.example/wide.jpg", mime: "image/jpeg",
            dim: CGSize(width: 1920, height: 1080), durationSec: nil, sha256Hex: nil,
            localBytes: solidJPEG((0.85, 0.45, 0.15), size: CGSize(width: 1920, height: 1080))
        )
        let teal = ComposeAttachment(
            id: UUID(), url: "https://blossom.example/b.jpg", mime: "image/jpeg",
            dim: CGSize(width: 300, height: 300), durationSec: nil, sha256Hex: nil,
            localBytes: solidJPEG((0.1, 0.5, 0.5))
        )
        let poster = ComposeAttachment(
            id: UUID(), url: "https://blossom.example/c.mp4", mime: "video/mp4",
            dim: CGSize(width: 300, height: 300), durationSec: 12, sha256Hex: nil,
            localBytes: solidJPEG((0.12, 0.15, 0.35))
        )
        vm.attachments = [wide, teal, poster]
        vm.setAltText("charred leeks", for: teal.id)

        let view = ComposeView(keypair: kp, viewModel: vm)
            .environment(AppSettings.shared)
            .environment(PowPreferences.shared)
            .environment(\.colorScheme, .dark)
        let host = Host(view, height: 760)
        host.pump(1.0)
        let image = try #require(host.snapshot())
        write(image, "attach-strip-render")
        #expect(!isBlank(image))
    }

    // MARK: - Harness (ComposeToolbarTests pattern)

    private func write(_ image: UIImage, _ name: String) {
        guard let dir = Self.snapshotDirectory, let data = image.pngData() else { return }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
    }

    nonisolated private static var snapshotDirectory: String? {
        let fileURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent(".zc_snapshot_dir")
        guard let raw = try? String(contentsOf: fileURL, encoding: .utf8) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func isBlank(_ image: UIImage) -> Bool {
        guard let cg = image.cgImage else { return true }
        let w = cg.width, h = cg.height
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let drew: Bool = buf.withUnsafeMutableBytes { raw in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let ctx = CGContext(
                      data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                      bytesPerRow: w * 4, space: space,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else { return false }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drew else { return true }
        let r0 = Int(buf[0]), g0 = Int(buf[1]), b0 = Int(buf[2])
        var i = 0
        while i < buf.count {
            if abs(Int(buf[i]) - r0) > 24 || abs(Int(buf[i + 1]) - g0) > 24 || abs(Int(buf[i + 2]) - b0) > 24 {
                return false
            }
            i += 4 * 7
        }
        return true
    }

    @MainActor private final class Host {
        let window: UIWindow

        init<Root: View>(_ root: Root, height: CGFloat = 120) {
            window = UIWindow(frame: CGRect(x: 0, y: 0, width: 375, height: height))
            window.windowScene = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first
            window.backgroundColor = .black
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

        func snapshot() -> UIImage? {
            let format = UIGraphicsImageRendererFormat()
            format.scale = 2
            return UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
        }
    }
}
