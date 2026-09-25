#if DEBUG
import ImageIO
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Records what the reorder gesture actually did, so a failing UI test can
/// say which phase never fired instead of only "nothing moved".
@MainActor @Observable
final class ReorderTrace {
    static let shared = ReorderTrace()
    private(set) var events: [String] = []
    private let t0 = Date()
    func note(_ e: String) {
        events.append("\(Int(Date().timeIntervalSince(t0) * 1000) % 100_000)ms \(e)")
        if events.count > 24 { events.removeFirst(events.count - 24) }
    }
    func reset() { events = [] }
    private var lastBucket: Int?
    /// The finger's x during a drag, noted only when it crosses a 40pt bucket.
    func noteDrag(_ x: CGFloat) {
        let bucket = Int((x / 40).rounded(.down))
        guard bucket != lastBucket else { return }
        lastBucket = bucket
        note("x=\(Int(x))")
    }
    func endDrag() { lastBucket = nil }
    private var lastScrollBucket = 0
    /// The strip's content offset, noted only when it crosses a 10pt bucket
    /// — so "the row moved" is an event a test can look for.
    func noteScroll(_ x: CGFloat) {
        let bucket = Int((x / 10).rounded(.towardZero))
        guard bucket != lastScrollBucket else { return }
        lastScrollBucket = bucket
        note("scroll x=\(Int(x))")
    }
}

/// Debug-only host for the composer's attachment strip, reached with the
/// `-ComposerDragHarness` launch argument.
///
/// Drag-to-reorder was rewritten five times against a simulator driven by a
/// mouse, and nobody could tell whether a failure was the gesture, the swap
/// math, or the cursor. This hosts the *real* `ComposeView` — no login,
/// a throwaway keypair — with seeded slots A, B, C… and a readout of their
/// order, so `ComposerDragReorderUITests` can drive genuine touch events
/// (`press(forDuration:thenDragTo:)`) and read the result.
///
/// Three slots by default (they fit the strip); `-ComposerDragHarnessSlots 6`
/// overflows it, so the strip genuinely scrolls. `-ComposerDragHarnessGIFs YES`
/// makes every slot an animated GIF, which the strip draws with a UIKit
/// `UIImageView` instead of a SwiftUI `Image`.
struct ComposerDragHarness: View {
    @State private var viewModel: ComposeViewModel
    private let labels: [UUID: String]
    private let keypair: Keypair

    init() {
        let priv = Schnorr.randomPrivkey()
        let pub = (try? Schnorr.xonlyPubkey(privkey32: priv)) ?? Data(count: 32)
        let kp = Keypair(privkey: Hex.encode(priv), pubkey: Hex.encode(pub))
        UserDefaults.standard.removeObject(forKey: "compose_autosave_new_\(kp.pubkey)")

        let vm = ComposeViewModel(keypair: kp, mode: .new)
        let palette: [(String, (CGFloat, CGFloat, CGFloat))] = [
            ("A", (0.85, 0.30, 0.20)),
            ("B", (0.15, 0.55, 0.35)),
            ("C", (0.20, 0.35, 0.85)),
            ("D", (0.80, 0.65, 0.15)),
            ("E", (0.55, 0.25, 0.70)),
            ("F", (0.20, 0.65, 0.75)),
            ("G", (0.75, 0.40, 0.55)),
            ("H", (0.45, 0.45, 0.45)),
        ]
        let requested = UserDefaults.standard.integer(forKey: "ComposerDragHarnessSlots")
        let seeds = palette.prefix(requested > 0 ? min(requested, palette.count) : 3)
        let gifs = UserDefaults.standard.bool(forKey: "ComposerDragHarnessGIFs")
        var labels: [UUID: String] = [:]
        vm.attachments = seeds.map { name, rgb in
            let id = UUID()
            labels[id] = name
            return ComposeAttachment(
                id: id, url: "https://harness.invalid/\(name).\(gifs ? "gif" : "jpg")",
                mime: gifs ? "image/gif" : "image/jpeg",
                dim: CGSize(width: 300, height: 300), durationSec: nil, sha256Hex: nil,
                localBytes: gifs ? Self.animatedGIF(rgb) : Self.solidJPEG(rgb)
            )
        }
        _viewModel = State(initialValue: vm)
        self.labels = labels
        self.keypair = kp
    }

    @State private var presented = true

    var body: some View {
        // Presented as a sheet because that is how the app presents the
        // composer (`MainView`'s `.sheet(isPresented: $showCompose)`), and a
        // sheet brings its own interactive-dismiss pan into the gesture
        // arbitration. Hosting ComposeView bare would test a different
        // environment than the one that fails.
        Color.wispBackground
            .ignoresSafeArea()
            .sheet(isPresented: $presented) {
                ComposeView(keypair: keypair, viewModel: viewModel)
                    .environment(AppSettings.shared)
                    .environment(PowPreferences.shared)
                    // Readouts ride in an overlay, never in the layout: an
                    // earlier version stacked them above the composer, and
                    // a trace line appearing mid-hold pushed the strip down
                    // 10pt under a stationary finger — enough to fail the
                    // long press it was measuring.
                    .overlay(alignment: .bottomLeading) { readouts }
            }
    }

    private var readouts: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("order:" + viewModel.attachments.map { labels[$0.id] ?? "?" }.joined(separator: ","))
                .font(.system(size: 11, design: .monospaced))
                .accessibilityIdentifier("harness-order")
            Text(ReorderTrace.shared.events.suffix(12).joined(separator: " | "))
                .font(.system(size: 8, design: .monospaced))
                .lineLimit(3)
                .accessibilityIdentifier("harness-trace")
        }
        .frame(width: 300, height: 48, alignment: .topLeading)
        .padding(4)
        .background(.black.opacity(0.6))
        .foregroundStyle(.white)
        .allowsHitTesting(false)
        .padding(.bottom, 4)
    }

    /// Two frames, full and dimmed, looping.
    private static func animatedGIF(_ rgb: (CGFloat, CGFloat, CGFloat)) -> Data {
        let size = CGSize(width: 150, height: 150)
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.gif.identifier as CFString, 2, nil) else {
            return Data()
        }
        CGImageDestinationSetProperties(dest, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0],
        ] as CFDictionary)
        for shade in [CGFloat(1), 0.6] {
            let frame = UIGraphicsImageRenderer(size: size).image { ctx in
                UIColor(red: rgb.0 * shade, green: rgb.1 * shade, blue: rgb.2 * shade, alpha: 1).setFill()
                ctx.fill(CGRect(origin: .zero, size: size))
            }
            guard let cg = frame.cgImage else { continue }
            CGImageDestinationAddImage(dest, cg, [
                kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.5],
            ] as CFDictionary)
        }
        CGImageDestinationFinalize(dest)
        return data as Data
    }

    private static func solidJPEG(_ rgb: (CGFloat, CGFloat, CGFloat)) -> Data {
        let size = CGSize(width: 300, height: 300)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            UIColor(red: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
        }.jpegData(compressionQuality: 0.9) ?? Data()
    }
}
#endif
