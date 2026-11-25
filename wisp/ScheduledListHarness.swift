#if DEBUG
import SwiftUI

/// Debug-only host for the Drafts & Scheduled screen, reached with the
/// `-ScheduledListHarness` launch argument: the real `DraftsScheduledView`,
/// no login, a throwaway keypair, and a scripted scheduler in place of the
/// network. `-ScheduledListHarnessEmpty YES` starts with nothing scheduled.
///
/// The scripted list holds one post of each shape the row has to preview (a
/// note with a picture, a poll, a picture post, a reply, a video) and one
/// that failed. Cancelling the poll is refused as already published;
/// cancelling anything else works. In empty mode a post turns up on the
/// second fetch, which is how a pull to refresh is seen to have worked. For `ScheduledListScreenshotsUITests`.
struct ScheduledListHarness: View {
    @State private var viewModel: DraftsViewModel

    init() {
        let priv = Schnorr.randomPrivkey()
        let pub = Hex.encode((try? Schnorr.xonlyPubkey(privkey32: priv)) ?? Data(count: 32))
        let vm = DraftsViewModel(keypair: Keypair(privkey: Hex.encode(priv), pubkey: pub))
        let empty = UserDefaults.standard.bool(forKey: "ScheduledListHarnessEmpty")
        vm.scheduledListing = ScriptedScheduler(privkey: priv, pubkey: pub, empty: empty)
        vm.selectedTab = .scheduled
        _viewModel = State(initialValue: vm)
    }

    @Environment(\.colorScheme) private var systemColorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        // The theme the app root resolves (`RootContainer`), so the screen is
        // shot in the colours it ships in.
        let settings = AppSettings.shared
        let resolved = settings.resolveTheme(systemColorScheme: systemColorScheme, contrast: contrast)
        ResolvedThemeProxy.update(resolved)
        return DraftsScheduledView(viewModel: viewModel)
            .environment(settings)
            .environment(\.theme, resolved)
            .preferredColorScheme(settings.preferredColorScheme)
    }
}

/// Answers the list and cancel calls from memory.
private actor ScriptedScheduler: ScheduledListing {
    private var pending: [ScheduledPost] = []
    private var failed: [ScheduledPost] = []
    private var refusedId: String?
    /// Empty mode: the post that has "been scheduled elsewhere" by the time
    /// the list is fetched a second time, so a pull on the empty list has
    /// something to show for itself.
    private var arrivesOnRefresh: ScheduledPost?
    private var pendingLoads = 0

    init(privkey: Data, pubkey: String, empty: Bool) {
        let now = NostrClock.now()
        func post(_ kind: Int, in seconds: Int, _ content: String, tags: [[String]] = [],
                  status: ScheduleStatus = .pending, attempts: Int = 0, lastError: String? = nil) -> ScheduledPost? {
            let at = now + seconds
            guard let event = try? NostrEvent.sign(privkey32: privkey, pubkey: pubkey, kind: kind,
                                                   createdAt: at, tags: tags, content: content) else { return nil }
            return ScheduledPost(id: event.id, publishAt: at, relayMode: .all, relays: [], status: status,
                                 attempts: attempts, lastError: lastError, sentAt: nil, event: event)
        }
        if empty {
            arrivesOnRefresh = post(1, in: 2 * 3_600, "Scheduled on zap.cooking a moment ago.")
            return
        }
        let poll = post(1068, in: 2 * 3_600, "Brisket or ribs for Saturday?",
                        tags: [["option", "a", "Brisket"], ["option", "b", "Ribs"], ["option", "c", "Both, obviously"]])
        refusedId = poll?.id
        pending = [
            post(1, in: 40 * 60, "Sunday roast, step by step. Start the potatoes first.\n\nhttps://harness.invalid/roast.jpg"),
            poll,
            post(20, in: 26 * 3_600, "Sourdough, day three",
                 tags: [["imeta", "url https://harness.invalid/loaf.jpg", "m image/jpeg"],
                        ["imeta", "url https://harness.invalid/crumb.jpg", "m image/jpeg"]]),
            post(1, in: 3 * 86_400, "Low and slow is the answer.",
                 tags: [["e", String(repeating: "a", count: 64), "", "root"]]),
            post(22, in: 9 * 86_400, "Knife skills in sixty seconds",
                 tags: [["imeta", "url https://harness.invalid/knife.mp4", "m video/mp4"]]),
        ].compactMap { $0 }
        failed = [
            post(1, in: -30 * 3_600, "Pickles are ready.", status: .failed, attempts: 10,
                 lastError: "blocked: spam filter"),
        ].compactMap { $0 }
    }

    func list(status: ScheduleStatus, keypair: Keypair) async -> Result<[ScheduledPost], ScheduleFailure> {
        try? await Task.sleep(for: .milliseconds(150))
        switch status {
        case .pending:
            pendingLoads += 1
            if pendingLoads > 1, let arrived = arrivesOnRefresh {
                pending = [arrived]
                arrivesOnRefresh = nil
            }
            return .success(pending)
        case .failed: return .success(failed)
        default: return .success([])
        }
    }

    func cancel(id: String, keypair: Keypair) async -> Result<ScheduleCancellation, ScheduleFailure> {
        try? await Task.sleep(for: .milliseconds(300))
        pending.removeAll { $0.id == id }
        if id == refusedId { return .failure(.notCancellable(status: .sent)) }
        return .success(ScheduleCancellation(id: id, alreadyCancelled: false))
    }
}
#endif
