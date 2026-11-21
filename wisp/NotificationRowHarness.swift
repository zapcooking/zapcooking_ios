#if DEBUG
import SwiftUI

/// Debug-only host for one `NotificationRowView`, reached with the
/// `-NotificationRowHarness` launch argument — the same pattern as
/// `-WalletAddressHarness`. Hosts the real row with fixture data: a zap
/// folded together with two duplicate zaps from the same actor, whose long
/// display name is the exact squeeze that used to crush the "+N more"
/// pill into a vertical character stack. No login, no relay traffic —
/// the actor's kind-0 profile is seeded locally so name resolution
/// never dials an indexer.
struct NotificationRowHarness: View {
    @State private var viewModel: NotificationsViewModel
    private let fixture: FlatNotificationItem

    init() {
        let accountKey = Self.randomKeypair()
        let actorKey = Self.randomKeypair()
        let fixture = Self.makeFixture(actorPubkey: actorKey.pubkey)
        let vm = NotificationsViewModel(keypair: accountKey)
        // Collapsed header only, in either persisted list style: folded shut
        // under `.expanded`, and never opened under the `.compact` accordion.
        vm.collapsedItemIds = [fixture.id]
        _viewModel = State(initialValue: vm)
        self.fixture = fixture
        Self.seedActorProfile(pubkey: actorKey.pubkey)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                NotificationRowView(
                    item: fixture,
                    viewModel: viewModel,
                    onPeerTap: { _ in },
                    onDmTap: { _ in }
                )
                Divider().overlay(Color.wispSurfaceVariant.opacity(0.4))
            }
        }
        .background(Color.wispBackground)
    }

    private static func randomKeypair() -> Keypair {
        let priv = Schnorr.randomPrivkey()
        let pub = (try? Schnorr.xonlyPubkey(privkey32: priv)) ?? Data(count: 32)
        return Keypair(privkey: Hex.encode(priv), pubkey: Hex.encode(pub))
    }

    /// One primary zap (13m ago) standing in for two earlier duplicates —
    /// `mergedZaps.count` drives the pill's "+2 more" label.
    private static func makeFixture(actorPubkey: String) -> FlatNotificationItem {
        let now = Int(Date().timeIntervalSince1970)
        var primary = FlatNotificationItem(
            id: "harness-zap-primary",
            kind: .zap,
            actorPubkey: actorPubkey,
            referencedEventId: "",
            timestamp: now - 13 * 60,
            zapSats: 66
        )
        primary.mergedZaps = [
            FlatNotificationItem(
                id: "harness-zap-merged-1",
                kind: .zap,
                actorPubkey: actorPubkey,
                referencedEventId: "",
                timestamp: now - 47 * 60,
                zapSats: 500
            ),
            FlatNotificationItem(
                id: "harness-zap-merged-2",
                kind: .zap,
                actorPubkey: actorPubkey,
                referencedEventId: "",
                timestamp: now - 95 * 60,
                zapSats: 21
            ),
        ]
        return primary
    }

    private static func seedActorProfile(pubkey: String) {
        let event = NostrEvent(
            id: "harness-profile-kind0",
            pubkey: pubkey,
            kind: 0,
            createdAt: Int(Date().timeIntervalSince1970),
            tags: [],
            content: #"{"name":"sondre","display_name":"Sondre | satoshiconsult.com"}"#,
            sig: ""
        )
        ProfileRepository.shared.updateFromEvent(event)
    }
}
#endif
