import SwiftUI
import Testing
import UIKit
@testable import wisp

/// The 2.5 blank "Continue with Nostr" sheet (Guideline 2.1, on the sign-in
/// path the review notes send the reviewer down). The splash and the account
/// switcher's `LoginView` presented their flows on a Bool while the flow's
/// content was `if let acceptance { … }`, with both set in the same tap. On
/// first presentation SwiftUI renders the content closure against the
/// optional as it was before the tap, so the sheet came up empty; the second
/// tap worked. A hosted probe of that exact shape on this SDK rendered the
/// empty branch (content 0, empty 1) — see gates/ for the run.
///
/// The fix presents on `PendingAgreement` with `item:`. These tests hold both
/// halves: the shape renders its flow the first time, for a sheet and a full
/// screen cover, and the entry files never regain the Bool + `if let` shape.
@Suite(.serialized)
@MainActor
struct EntryPresentationTests {

    final class Box {
        var fire: () -> Void = {}
        var rendered: [String] = []
    }

    /// Mirrors `ContentView`'s splash wiring: one tap sets the pending
    /// agreement, and the flow reads it from the closure argument.
    struct ItemShape: View {
        let box: Box
        let fullScreen: Bool
        @State private var pending: PendingAgreement?

        var body: some View {
            Group {
                if fullScreen {
                    Color.black.fullScreenCover(item: $pending) { p in
                        Text(p.acceptance.version).onAppear { box.rendered.append(p.acceptance.version) }
                    }
                } else {
                    Color.black.sheet(item: $pending) { p in
                        Text(p.acceptance.version).onAppear { box.rendered.append(p.acceptance.version) }
                    }
                }
            }
            .onAppear { box.fire = { pending = PendingAgreement(.now()) } }
        }
    }

    private func presentOnce(fullScreen: Bool) -> [String] {
        let box = Box()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.windowScene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }.first
        window.rootViewController = UIHostingController(rootView: ItemShape(box: box, fullScreen: fullScreen))
        window.isHidden = false
        defer { window.isHidden = true }
        pump(0.5)
        box.fire()
        pump(1.5)
        return box.rendered
    }

    private func pump(_ seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
    }

    @Test func sheet_rendersTheFlowOnFirstPresentation() {
        #expect(presentOnce(fullScreen: false) == [TermsAcceptance.currentVersion])
    }

    @Test func fullScreenCover_rendersTheFlowOnFirstPresentation() {
        #expect(presentOnce(fullScreen: true) == [TermsAcceptance.currentVersion])
    }

    // MARK: - Tripwire on the entry files

    /// Line numbers of Bool-presented sheets / covers whose content opens
    /// with `if let` / `guard let` — the 2.5 shape.
    private func boolPresentedOptionalContent(in text: String) -> [Int] {
        let lines = text.components(separatedBy: "\n")
        var hits: [Int] = []
        for (i, line) in lines.enumerated()
        where line.contains(".sheet(isPresented:") || line.contains(".fullScreenCover(isPresented:") {
            let next = lines[(i + 1)...].lazy
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .first { !$0.isEmpty && !$0.hasPrefix("//") }
            if let next, next.hasPrefix("if let") || next.hasPrefix("guard let") {
                hits.append(i + 1)
            }
        }
        return hits
    }

    /// Every presentation in the files that hold the sign-in entry points.
    @Test func entryFiles_neverPresentOnABoolWithOptionalContent() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        var offenders: [String] = []
        for file in ["wisp/ContentView.swift", "wisp/SplashView.swift", "LoginView.swift"] {
            let text = try String(contentsOf: root.appendingPathComponent(file), encoding: .utf8)
            offenders += boolPresentedOptionalContent(in: text).map { "\(file):\($0)" }
        }
        #expect(offenders.isEmpty, "present on PendingAgreement with item:, not a Bool: \(offenders)")
    }

    /// The tripwire can fail: the 2.5 splash wiring (4f38921) trips it.
    @Test func tripwire_catchesThe25Shape() {
        let v25 = """
                .sheet(isPresented: $showNostrSheet) {
                    if let splashAcceptance {
                        NostrLoginSheet(acceptance: splashAcceptance)
                    }
                }
                .fullScreenCover(isPresented: $showAppleAuth) {
                    if let splashAcceptance {
                        AppleAuthView(acceptance: splashAcceptance)
                    }
                }
                .fullScreenCover(isPresented: $showQRScanner) {
                    QRCodeScannerView()
                }
            """
        #expect(boolPresentedOptionalContent(in: v25) == [1, 6])
    }
}
