import Foundation
import Testing
@testable import wisp

/// LIVE regression test for the notification deep-link into a mixed
/// kind-1 / kind-1111 thread with muted participants (#220 follow-ups).
///
/// The thread: TheGrinder's note `4786a7c2` ← Seraf `d16ccce6` ← Daniel's
/// kind-1 `00000156` ← … a kind-1 by Toddstr (`108d80b3`) answering a muted
/// comment (a "stray" kind-1 on a comment, hidden from the tree) ← Daniel's
/// comment chain `00000d0d → a4c9d040 → 00000dbc → 082b11ac → 00000595 →
/// 00000c52` (the tapped note) ← TheGrinder's reply `7589bcfe`.
///
/// Two defects used to make the tapped note vanish:
/// 1. The root climb stopped after one hop (a comment's `E` anchor), so the
///    thread opened on `00000156` with everything above it invisible.
/// 2. The hidden stray severed its whole subtree — including the tapped
///    comment — because its children only attached through it.
@MainActor
struct LiveNotificationDeepLinkThreadTests {

    private static let me = "ee6ea13ab9fe5c4a68eaf9b1a34fe014a66b40117c50ee2a614f4cda959b6e74"
    private static let seraf = "5eb2c642d40a58795422121625be7fbe47e8901485a1a8bc01e1907b8aea0a9b"
    private static let verita = "4b56bbf41c92e586e88927acb78836eb49f2b184081ef852625cf78be7d56bd6"
    private static let tapped = "00000c521275bc4824d8911d7afa4043cad20197947a904d4c0fe9ff1509822f"
    private static let trueRoot = "4786a7c289ffc30816f4e40ad65eca87fab3033f4c128c4e22dc52be09dafce2"

    @Test func tappedCommentRendersUnderTheTrueRootWithMutedAncestors() async throws {
        SafetyFilter.shared.install(SafetyFilterSnapshot(
            mutedWords: [], blockedPubkeys: [Self.seraf, Self.verita], mutedThreads: [],
            wotEnabled: false, qualifiedNetwork: [], userPubkey: Self.me))
        defer { SafetyFilter.shared.install(.empty) }

        let keypair = Keypair(privkey: String(repeating: "1", count: 64), pubkey: Self.me)
        let vm = ThreadViewModel(seedEventId: Self.tapped, authorHint: Self.me, keypair: keypair)
        defer { vm.stop() }
        await vm.start()

        let wanted: Set<String> = [Self.tapped, "00000595ff0a0c9ef1bfbf7a4b1459c2750f620fde31b3c3d72d5c6619fa1691"]
        let deadline = Date().addingTimeInterval(45)
        while Date() < deadline, !wanted.isSubset(of: Set(vm.nestedReplies.map(\.id))) {
            try await Task.sleep(for: .seconds(2))
        }

        let rendered = Set(vm.nestedReplies.map(\.id))
        print("LIVE-DEEPLINK root=\(vm.rootId.prefix(8)) count=\(rendered.count)")
        #expect(vm.rootId == Self.trueRoot, "the climb must reach the true conversation root, not stop at the comment's E anchor")
        #expect(rendered.contains(Self.tapped), "tapped comment missing from the rendered thread")
        #expect(rendered.contains(wanted.subtracting([Self.tapped]).first!), "tapped comment's parent comment missing")
        #expect(vm.scrollTargetId == Self.tapped, "scroll target should be armed on the tapped note")
    }
}
