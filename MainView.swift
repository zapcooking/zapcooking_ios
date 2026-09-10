import SwiftUI

/// Identifiable wrapper so a PiP-restore request can drive a
/// `fullScreenCover(item:)` for re-opening a popped-out video.
private struct PiPVideoRestoreItem: Identifiable {
    let id = UUID()
    let url: String
    let startSeconds: Double
}

struct MainView: View {
    let keypair: Keypair
    let onLogout: () -> Void

    private var isWatchOnly: Bool { NostrKey.isWatchOnly(pubkey: keypair.pubkey) }
    var onSwitchAccount: (Keypair) -> Void = { _ in }
    @State private var viewModel: FeedViewModel
    @State private var messagesVM: MessagesViewModel
    @State private var notificationsVM: NotificationsViewModel
    @State private var groupListVM: GroupListViewModel
    @State private var searchVM: SearchViewModel
    @State private var walletStore: WalletStore
    // Food-first default (Concern 1.5). `.kitchen` is the My Kitchen hub
    // (Concern 3.2). `.feed` is the one feed surface (unified feed PR 2): it
    // renders the OnlyFood list or the general feed by `viewModel.currentKind`.
    @State private var selectedTab: BottomTab = .recipes
    @State private var feedPath = NavigationPath()
    @State private var recipesPath = NavigationPath()
    /// Hoisted out of `MessagesView` (unified feed PR 6) so Messages, now a
    /// bar tab, pops to root on re-tap through `popToRoot` like every other
    /// tab, and so its navigation state survives leaving the switch-mounted
    /// tab and coming back.
    @State private var messagesPath = NavigationPath()
    @State private var kitchenPath = NavigationPath()
    @State private var placeholderPath = NavigationPath()
    @State private var notificationsPath = NavigationPath()
    @State private var searchPath = NavigationPath()
    /// Per-tab side-channel mirroring the eventIds of any ThreadRoute pushes on
    /// the matching path, in stack order. Lets ThreadView smart-pop back to an
    /// already-visited ancestor instead of pushing a duplicate. Maintained by
    /// ThreadView's `.task` (append) + `.onDisappear` (remove-tail).
    @State private var feedThreadChain: [String] = []
    @State private var recipesThreadChain: [String] = []
    @State private var kitchenThreadChain: [String] = []
    @State private var notificationsThreadChain: [String] = []
    @State private var searchThreadChain: [String] = []
    @State private var recipeFeedVM = RecipeFeedViewModel()
    @State private var onlyfoodFeedVM: OnlyFoodFeedViewModel
    @State private var drawerOpen = false
    @State private var drawerDragOffset: CGFloat = 0
    @State private var engagementRepo = EngagementRepository.shared
    @State private var showInterfaceSettings = false
    @State private var showKeys = false
    @State private var showCustomEmojis = false
    @State private var showHashtagSets = false
    @State private var showLists = false
    @State private var showPolls = false
    @State private var showCompose = false
    @State private var showRecipeCompose = false
    @State private var showSousChef = false
    @State private var showCheffy = false
    /// App-level router for reply / quote / emoji-reaction composers triggered
    /// from any feed card. Hosted from this view's stable root (see body) so the
    /// composer sheet is never anchored to a recyclable `LazyVStack` row, which
    /// is what caused the rare open/close loop. Injected into the environment so
    /// every card in every tab routes through it.
    @State private var composePresenter = ComposePresenter()
    /// Hosted at the tab root so Report is never anchored to a recyclable
    /// feed / recipe / profile row (same reason `composePresenter` lives here).
    @State private var reportPresenter = ReportPresenter.shared
    @State private var showDraftsScheduled = false
    @State private var showCookingUtilitiesSheet = false
    @State private var cookingTimers = CookingTimerStore.shared
    @Environment(\.scenePhase) private var scenePhase
    /// Set on `.background`, consumed on the next `.active` — see the
    /// `scenePhase` handler.
    @State private var wasBackgrounded = false
    @State private var showRelayPicker = false
    @State private var showOnlineSheet = false
    @State private var showSocialGraph = false
    /// Read in `onlyFoodBody` for the live OnlyFood WoT toggle (§4).
    private var safetyPrefs: SafetyPreferences { SafetyPreferences.shared }
    @State private var showSafety = false
    @State private var showProofOfWork = false
    @State private var showAbout = false
    @State private var showMediaServers = false
    @State private var hashtagSetRepo = HashtagSetRepository.shared
    @Environment(AudioPlayerStore.self) private var audioPlayer
    @State private var showRelaySettings = false
    @State private var pendingAuthRequest: PendingAuthRequest?
    @State private var feedFabOpacity: Double = 1.0
    /// Written by every `ComposeView` autosave-on-dismiss (new / reply / quote
    /// alike). Watched here and translated into the shared `SuccessToast` so
    /// the pill fires no matter which navigation surface presented the composer.
    @State private var draftToast = DraftSavedToastStore.shared
    /// Set to reopen the composer pointed at an existing draft (populated by
    /// the draft-saved toast tap). Separate from `showCompose` so SwiftUI
    /// mounts a fresh `ComposeView` keyed off the draft's dTag.
    @State private var reopenDraft: Nip37.Draft?
    /// Set when the Share Extension hands off media via `wisp://share` (see
    /// `PendingShareStore` / `wispApp.onOpenURL`). Drives its own
    /// `.sheet(item:)`, separate from `showCompose`, so SwiftUI mounts a
    /// fresh `ComposeView` carrying the hand-off's attachments.
    @State private var pendingShare: PendingShareItem?
    /// Bumped from `popToRoot(.feed)` so the feed `ScrollViewReader` can scroll
    /// to the top anchor. Tap-on-active-tab clears the nav stack first; on a
    /// subsequent tap (when the stack is already empty) it animates to the top.
    @State private var feedScrollToTopTrigger: Int = 0
    /// Tracks whether the feed is parked at the top. While false, live events
    /// are held in the view model's `pendingNewCount` so the new-posts pill
    /// has something to surface. Treats anything within 8pt of zero as "at
    /// top" because rubber-banding can briefly leave the offset slightly
    /// positive even when the user is visually parked at the top.
    @State private var feedAtTop: Bool = true
    /// Active Picture-in-Picture session, observed so the floating window's
    /// "return to app" button can re-open the live stream / fullscreen video.
    @State private var pipCoordinator = VideoPiPCoordinator.shared
    /// Drives the fullscreen-video restore cover (set when a popped-out feed or
    /// fullscreen video's restore button is tapped).
    @State private var pipRestoreVideo: PiPVideoRestoreItem?

    private let drawerWidth: CGFloat = 320

    var onAddAccount: () -> Void = {}

    init(keypair: Keypair, onLogout: @escaping () -> Void = {}, onSwitchAccount: @escaping (Keypair) -> Void = { _ in }, onAddAccount: @escaping () -> Void = {}) {
        self.keypair = keypair
        self.onLogout = onLogout
        self.onSwitchAccount = onSwitchAccount
        self.onAddAccount = onAddAccount
        _viewModel = State(initialValue: FeedViewModel(keypair: keypair))
        _messagesVM = State(initialValue: MessagesViewModel(keypair: keypair))
        _notificationsVM = State(initialValue: NotificationsViewModel(keypair: keypair))
        _groupListVM = State(initialValue: GroupListViewModel(keypair: keypair))
        _searchVM = State(initialValue: SearchViewModel(keypair: keypair))
        _walletStore = State(initialValue: WalletStore(keypair: keypair))
        _onlyfoodFeedVM = State(initialValue: OnlyFoodFeedViewModel(pubkey: keypair.pubkey))
    }

    var body: some View {
        @Bindable var presenter = composePresenter
        return ZStack(alignment: .leading) {
            mainShell

            if drawerOpen {
                Color.black
                    .opacity(0.4)
                    .ignoresSafeArea()
                    .transition(.opacity)
                    .onTapGesture { closeDrawer() }
            }

            SidebarDrawerView(
                profile: viewModel.userProfile,
                keypair: keypair,
                onClose: { closeDrawer() },
                onSelectTab: { tab in
                    selectedTab = tab
                    closeDrawer()
                },
                onLogout: {
                    closeDrawer()
                    Task {
                        // Multi-account branch: when another saved account exists, only
                        // delete the current account's keychain + per-pubkey UserDefaults
                        // and hand off to the next account. The full `AppDataWipe` path
                        // was throwing every saved account out of the app, forcing a
                        // multi-account user back through the splash login / signup flow
                        // on every logout.
                        let currentPubkey = keypair.pubkey
                        let nextPubkey = NostrKey.accounts().first { $0 != currentPubkey }
                        if let nextPubkey, let nextKp = NostrKey.switchAccount(pubkey: nextPubkey) {
                            NostrKey.deleteAccount(pubkey: currentPubkey)
                            onSwitchAccount(nextKp)
                        } else {
                            await AppDataWipe.wipeEverything()
                            onLogout()
                        }
                    }
                },
                onSwitchAccount: { newKeypair in
                    closeDrawer()
                    onSwitchAccount(newKeypair)
                },
                onAddAccount: {
                    closeDrawer()
                    onAddAccount()
                },
                onOpenProfile: {
                    closeDrawer()
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(280))
                        selectedTab = .feed
                        feedPath.append(ProfileRoute(pubkey: keypair.pubkey))
                    }
                },
                onOpenProfileByPubkey: { scannedPubkey in
                    closeDrawer()
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(280))
                        selectedTab = .feed
                        feedPath.append(ProfileRoute(pubkey: scannedPubkey))
                    }
                },
                onOpenInterface: {
                    closeDrawer()
                    showInterfaceSettings = true
                },
                onOpenKeys: {
                    closeDrawer()
                    showKeys = true
                },
                onOpenDraftsScheduled: {
                    closeDrawer()
                    showDraftsScheduled = true
                },
                onOpenGadgets: {
                    closeDrawer()
                    showCookingUtilitiesSheet = true
                },
                onOpenCustomEmojis: {
                    closeDrawer()
                    showCustomEmojis = true
                },
                onOpenLists: {
                    closeDrawer()
                    showLists = true
                },
                onOpenPolls: {
                    closeDrawer()
                    showPolls = true
                },
                onOpenHashtagSets: {
                    closeDrawer()
                    showHashtagSets = true
                },
                onOpenSocialGraph: {
                    closeDrawer()
                    showSocialGraph = true
                },
                onOpenSafety: {
                    closeDrawer()
                    showSafety = true
                },
                onOpenProofOfWork: {
                    closeDrawer()
                    showProofOfWork = true
                },
                onOpenRelays: {
                    closeDrawer()
                    showRelaySettings = true
                },
                onOpenMediaServers: {
                    closeDrawer()
                    showMediaServers = true
                },
                onOpenAbout: {
                    closeDrawer()
                    showAbout = true
                }
            )
            .frame(width: drawerWidth)
            .frame(maxHeight: .infinity)
            .background(Color.wispBackground)
            .offset(x: drawerOpen ? drawerDragOffset : -drawerWidth)
            .animation(.smooth(duration: 0.25), value: drawerOpen)
            .gesture(drawerDragGesture)
        }
        .background(Color.wispBackground)
        .overlay(SuccessToastOverlay())
        .overlay(PostStatusPillOverlay())
        .overlay {
            TimerCompletionOverlay(
                timer: cookingTimers.completion,
                onDismiss: { cookingTimers.dismissCompletion() }
            )
        }
        .onChange(of: scenePhase) { _, phase in
            cookingTimers.handleScenePhase(phase)
            // OnlyFood resume (§3.3): only on a genuine background → active
            // return, not on the launch-time inactive → active transition, so
            // the first load is never followed by an immediate second REQ.
            switch phase {
            case .background:
                wasBackgrounded = true
            case .active where wasBackgrounded:
                wasBackgrounded = false
                FeedTabRouting.resumeOnlyFoodIfActive(kind: viewModel.currentKind, onlyFood: onlyfoodFeedVM)
            default:
                break
            }
        }
        .task {
            await cookingTimers.prepareNotifications()
        }
        .environment(walletStore)
        .environment(composePresenter)
        .onReceive(NotificationCenter.default.publisher(for: .openWalletTab)) { _ in
            // PostCardView posts this when the user tries to zap without
            // a configured wallet and chooses "Set Up Wallet" on the
            // resulting prompt — switch to the wallet tab so they land on
            // the setup UI directly.
            selectedTab = .wallet
        }
        .onReceive(NotificationCenter.default.publisher(for: .openWispChatLink)) { note in
            // RichInlineTextView posts this when the user taps a
            // `wss://host'<groupid>` link in a note. Stash the parsed
            // invite on the shared GroupListViewModel and switch tabs;
            // MessagesView observes `pendingChatDeepLink` and handles
            // the join + push.
            guard let info = note.userInfo,
                  let relay = info["relay"] as? String,
                  let group = info["group"] as? String else { return }
            // Watch-only accounts can't participate in group chat — ignore the
            // deep link rather than landing them on a tab that isn't there.
            if isWatchOnly { return }
            let code = info["code"] as? String
            groupListVM.pendingChatDeepLink = ChatDeepLink(
                relayUrl: relay, groupId: group, code: code
            )
            selectedTab = .messages
        }
        .task {
            GroupListViewModelRegistry.register(groupListVM)

            // NIP-42 AUTH wiring. Set the static hooks before any RelayPool call so
            // pre-approved relays auto-sign their challenges. The approval check reads
            // UserDefaults directly (thread-safe, callable from socket task contexts);
            // the signer captures the active keypair via closure.
            let activeKeypair = keypair
            let activePubkey = keypair.pubkey
            RelayPool.authApprovalCheck = { url in
                RelaySettingsRepository.isAuthApproved(url, pubkey: activePubkey)
            }
            RelayPool.authSigner = { url, challenge in
                try? Nip42.buildAuthEvent(challenge: challenge, relayUrl: url, keypair: activeKeypair)
            }

            // Drain pending AUTH challenges into the approval sheet state.
            Task { @MainActor in
                for await req in RelayPool.pendingAuth {
                    if pendingAuthRequest == nil {
                        pendingAuthRequest = req
                    }
                }
            }

            // Safety bootstrap — bind the per-account stores, rebuild the lockless filter
            // snapshot, then kick the off-main work (NSpam warmup, mute sync, optional WoT
            // recompute). All four ingest paths consult the snapshot lockless on every event,
            // so this must run before any subscription opens.
            let privkey32 = Hex.decode(keypair.privkey)
            ReportedContent.shared.bind(activePubkey: keypair.pubkey)
            MuteRepository.shared.bind(
                activePubkey: keypair.pubkey,
                privkey32: privkey32,
                keypair: keypair
            )
            SafetyPreferences.shared.bind(activePubkey: keypair.pubkey)
            PrivateInteractionStore.shared.bind(activePubkey: keypair.pubkey)
            await ExtendedNetworkRepository.shared.bind(activePubkey: keypair.pubkey)
            await SafetyFilter.shared.rebuildSnapshot()
            Task.detached { try? await SpamScorer.shared.warmUp() }
            // Background fetcher for kind-0 profiles whose pubkey we've seen
            // but haven't cached. Hooks into EventPersistQueue, EngagementRepository,
            // and individual VMs (which call observe / observePubkeys); also runs
            // a periodic sweep over registered event sources at 3s/8s/15s/120s.
            MissingProfileWatcher.shared.start(activePubkey: keypair.pubkey)
            if let priv = privkey32 {
                MuteRepository.shared.startSync(privkey32: priv)
            }
            Task.detached(priority: .utility) {
                guard await SafetyPreferences.shared.wotFilterEnabled,
                      await ExtendedNetworkRepository.shared.isStale() else { return }
                // With WoT enabled the filter is FAIL-CLOSED: an empty/corrupt
                // cached network hides all non-exempt content until a recompute
                // lands. Retry with backoff (launch offline, flaky relays)
                // rather than staying dark until the next cold launch. A
                // stale-but-populated network keeps filtering on the cached set
                // after one freshen attempt — only the empty case retries.
                // Deliberately NO auto-disable on failure: the user opted into
                // a filter that gates graphic content; failing open without
                // consent is worse than a temporarily empty feed.
                for attempt in 0..<3 {
                    await ExtendedNetworkRepository.shared.recompute()
                    let summary = await ExtendedNetworkRepository.shared.summary()
                    if summary.qualifiedCount > 0 { return }
                    if attempt < 2 {
                        try? await Task.sleep(for: .seconds(20 * (attempt + 1)))
                    }
                }
            }

            // Run all VM startups concurrently — sequential awaits made notifications wait
            // ~5-8s for feed + messages to finish their relay round trips before even opening
            // a single websocket of their own.
            async let feed: Void = viewModel.start()
            async let messages: Void = messagesVM.start()
            async let notifications: Void = notificationsVM.start()
            async let groups: Void = groupListVM.start()
            async let emoji: Void = EmojiRepository.shared.refresh(for: keypair.pubkey)
            async let hashtagSets: Void = HashtagSetRepository.shared.bootstrap(keypair: keypair)
            async let peopleLists: Void = PeopleListRepository.shared.bootstrap(keypair: keypair)
            async let noteLists: Void = NoteListRepository.shared.bootstrap(keypair: keypair)
            async let relaySettings: Void = RelaySettingsRepository.shared.bootstrap(keypair: keypair)
            // Pre-warm the wallet at app start so the wallet tab opens with live data
            // instead of waiting for the user to land on it before kicking off the
            // 3-8s Spark SDK init or NWC relay handshake.
            async let wallet: Void = walletStore.startIfConfigured()
            _ = await (feed, messages, notifications, groups, emoji, hashtagSets, peopleLists, noteLists, relaySettings, wallet)
        }
        .onDisappear {
            viewModel.stop()
            messagesVM.stop()
            notificationsVM.stop()
            groupListVM.stop()
            searchVM.stop()
            MissingProfileWatcher.shared.stop()
        }
        .sheet(isPresented: $showInterfaceSettings) {
            NavigationStack {
                InterfaceSettingsView()
            }
        }
        .sheet(isPresented: $showKeys) {
            NavigationStack {
                KeysSettingsView(keypair: keypair)
            }
        }
        .sheet(isPresented: $showRelaySettings) {
            NavigationStack {
                RelaySettingsView(keypair: keypair)
            }
        }
        .sheet(item: $pendingAuthRequest) { req in
            RelayAuthApprovalSheet(
                relayUrl: req.relayUrl,
                keypair: keypair,
                onDismiss: { pendingAuthRequest = nil }
            )
        }
        .sheet(isPresented: $showCustomEmojis) {
            NavigationStack {
                CustomEmojiSettingsView(keypair: keypair)
            }
        }
        .sheet(isPresented: $showLists) {
            NavigationStack {
                ListsHubView(
                    keypair: keypair,
                    onViewPeopleFeed: { list in
                        showLists = false
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(350))
                            feedPath.append(PeopleListFeedRoute(dTag: list.dTag))
                            selectedTab = .feed
                        }
                    },
                    onViewNoteFeed: { list in
                        showLists = false
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(350))
                            feedPath.append(NoteListFeedRoute(dTag: list.dTag))
                            selectedTab = .feed
                        }
                    }
                )
                .navigationDestination(for: PeopleListEditorRoute.self) { route in
                    PeopleListEditorView(
                        keypair: keypair,
                        dTag: route.dTag,
                        onViewFeed: { list in
                            showLists = false
                            Task { @MainActor in
                                try? await Task.sleep(for: .milliseconds(350))
                                feedPath.append(PeopleListFeedRoute(dTag: list.dTag))
                                selectedTab = .feed
                            }
                        }
                    )
                }
                .navigationDestination(for: NoteListEditorRoute.self) { route in
                    NoteListEditorView(
                        keypair: keypair,
                        dTag: route.dTag,
                        onViewFeed: { list in
                            showLists = false
                            Task { @MainActor in
                                try? await Task.sleep(for: .milliseconds(350))
                                feedPath.append(NoteListFeedRoute(dTag: list.dTag))
                                selectedTab = .feed
                            }
                        }
                    )
                }
            }
        }
        .sheet(isPresented: $showHashtagSets) {
            NavigationStack {
                HashtagSetsView(
                    keypair: keypair,
                    onViewFeed: { set in
                        showHashtagSets = false
                        Task { @MainActor in
                            try? await Task.sleep(for: .milliseconds(350))
                            feedPath.append(HashtagFeedRoute(setDTag: set.dTag))
                            selectedTab = .feed
                        }
                    }
                )
            }
        }
        .sheet(isPresented: $showCompose) {
            ComposeView(keypair: keypair, mode: .new)
        }
        // Reply / quote / emoji-reaction composers and the zap sheet from any
        // feed card present here, from the stable root — never from the
        // recyclable card row. See `ComposePresenter`.
        .sheet(item: $presenter.request) { req in
            switch req {
            case .reply(let parent, let root):
                ComposeView(keypair: keypair, mode: .reply(parent: parent, root: root))
            case .quote(let event):
                ComposeView(keypair: keypair, mode: .quote(event))
            case .newNote(let text):
                ComposeView(keypair: keypair, initialText: text)
            case .emoji(_, let onPick):
                EmojiLibrarySheet(mode: .pickForReaction { picked in
                    onPick(picked)
                    composePresenter.request = nil
                })
            case .zap(let zap):
                // Hosted here for the same reason as the composers: the zap
                // sheet raises the keyboard, and presenting it from the
                // recyclable card row produced the open/close loop (a
                // diagnostic trace on 2026-06-07 showed keyboard willShow →
                // presenting row recycled ~2ms later → sheet torn down → the
                // card's surviving @State re-presents, looping).
                ZapSheet(
                    store: walletStore,
                    recipientPubkey: zap.recipientPubkey,
                    recipientLud16: zap.recipientLud16,
                    recipientName: zap.recipientName,
                    eventId: zap.eventId,
                    relayHints: zap.relayHints,
                    extraTags: zap.extraTags,
                    forcePrivate: zap.forcePrivate,
                    onSuccess: zap.onSuccess,
                    dismiss: { composePresenter.request = nil }
                )
            }
        }
        .sheet(item: $reopenDraft) { draft in
            ComposeView(keypair: keypair, draft: draft)
        }
        .sheet(item: $reportPresenter.target) { target in
            ReportSheet(target: target, keypair: keypair)
        }
        .sheet(item: $pendingShare) { share in
            if let text = share.text {
                ComposeView(keypair: keypair, initialText: text)
            } else {
                ComposeView(keypair: keypair, pendingAttachmentProviders: share.providers)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .pendingShareReceived)) { note in
            guard let item = note.object as? PendingShareItem else { return }
            pendingShare = item
        }
        .onChange(of: draftToast.pendingDraft?.dTag) { _, dTag in
            // ComposeView's autosave-on-dismiss writes the draft here from
            // whichever surface presented it; translate that into the shared
            // success pill, with a tap action that reopens the draft. Consume
            // the store entry so the same draft doesn't re-fire on next change.
            guard dTag != nil, let draft = draftToast.pendingDraft else { return }
            draftToast.pendingDraft = nil
            SuccessToast.shared.show(
                "Draft saved",
                icon: "tray.and.arrow.down.fill",
                duration: 3.5
            ) {
                reopenDraft = draft
            }
        }
        .sheet(isPresented: $showRelayPicker) {
            RelayPickerSheet(
                keypair: keypair,
                onSelectRelay: { url in viewModel.selectRelay(url: url) },
                onSelectRelaySet: { set in viewModel.selectRelaySet(set) }
            )
        }
        .sheet(isPresented: $showSocialGraph) {
            SocialGraphView(keypair: keypair)
        }
        .sheet(isPresented: $showSafety) {
            NavigationStack {
                SafetySettingsView(keypair: keypair)
            }
        }
        .sheet(isPresented: $showProofOfWork) {
            NavigationStack {
                ProofOfWorkSettingsView()
            }
        }
        .sheet(isPresented: $showAbout) {
            NavigationStack {
                AboutView()
            }
        }
        .sheet(isPresented: $showMediaServers) {
            NavigationStack {
                MediaServersView(keypair: keypair)
            }
        }
        .sheet(isPresented: $showDraftsScheduled) {
            DraftsScheduledView(keypair: keypair)
        }
        .sheet(isPresented: $showCookingUtilitiesSheet) {
            CookingUtilitiesSheet(
                store: cookingTimers,
                onDismiss: { showCookingUtilitiesSheet = false }
            )
        }
        .sheet(isPresented: $showPolls) {
            PollsView(keypair: keypair, onOpenPoll: { eventId, authorPubkey in
                showPolls = false
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(350))
                    feedPath.append(ThreadRoute(eventId: eventId, authorPubkey: authorPubkey))
                    selectedTab = .feed
                }
            })
        }
        .sheet(isPresented: $showOnlineSheet) {
            OnlineNowSheet(
                networkPubkeys: viewModel.onlineNetworkPubkeys,
                globalCount: viewModel.globalOnlineCount,
                profiles: viewModel.profiles,
                onTapProfile: { pubkey in
                    showOnlineSheet = false
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(350))
                        feedPath.append(ProfileRoute(pubkey: pubkey))
                        selectedTab = .feed
                    }
                }
            )
            .presentationDetents([.medium, .large])
        }
        .onChange(of: pipCoordinator.restoreRequest) { _, request in
            guard let request else { return }
            switch request {
            case .liveStream(let route):
                selectedTab = .feed
                feedPath.append(route)
            case .fullscreenVideo(let url, let atSeconds):
                pipRestoreVideo = PiPVideoRestoreItem(url: url, startSeconds: atSeconds)
            }
            pipCoordinator.clearRestoreRequest()
        }
        .fullScreenCover(item: $pipRestoreVideo) { item in
            FullScreenVideoView(url: item.url, startSeconds: item.startSeconds)
        }
    }


    /// The feed tab's navigation stack — the one feed surface (OnlyFood or
    /// the general feed by `viewModel.currentKind`). Rendered ALWAYS (see
    /// `mainShell`), merely hidden when another tab is active, so its feed
    /// `ScrollView` is never torn down on a tab switch. SwiftUI preserves the scroll position of
    /// views it doesn't destroy, so the user returns to exactly where they were
    /// — with zero scroll tracking and nothing added to the scroll hot path.
    private var feedTab: some View {
        NavigationStack(path: $feedPath) {
            ZStack(alignment: .bottomTrailing) {
                feedContent
                // Compose FAB (§8): on OnlyFood, the visible, removable
                // `#foodstr` seed through the app-level `ComposePresenter`
                // (Concern C-H); every other kind opens the plain composer.
                // Same drawer / watch-only gating as before.
                if !drawerOpen && !isWatchOnly {
                    ComposeFAB {
                        if let prefill = FeedTabRouting.composePrefill(for: viewModel.currentKind) {
                            composePresenter.openNewNote(initialText: prefill)
                        } else {
                            showCompose = true
                        }
                    }
                        .accessibilityIdentifier(viewModel.currentKind == .onlyFood ? "new-food-post" : "new-post")
                        .padding(.trailing, 18)
                        .padding(.bottom, 32 + (audioPlayer.currentTrack != nil ? MiniAudioPlayerView.collapsedHeight : 0))
                        .opacity(feedFabOpacity)
                        .animation(.easeInOut(duration: 0.2), value: feedFabOpacity)
                        .animation(.smooth(duration: 0.22), value: audioPlayer.currentTrack != nil)
                }
            }
            // Frosted unified top header — same `.regularMaterial` look as
            // ProfileView. Inside the NavigationStack so it auto-disappears
            // when the user pushes a destination, and content scrolls under
            // it instead of starting below an opaque bar.
            // One flat alpha layer over the status-bar strip and the bar
            // together (Android wraps the whole top app bar in a 0.85-alpha
            // Box); a gradient reads as a seam between the two.
            .safeAreaInset(edge: .top, spacing: 0) {
                topBar.background(Color.wispBackground.opacity(0.85))
            }
            .navigationDestination(for: ProfileRoute.self) { route in
                ProfileView(
                    pubkey: route.pubkey,
                    activeUserPubkey: keypair.pubkey,
                    onProfileTap: { pk in feedPath.append(ProfileRoute(pubkey: pk)) },
                    onNoteTap: { eid in feedPath.append(ThreadRoute(eventId: eid, authorPubkey: route.pubkey)) },
                    onHashtagTap: { tag in feedPath.append(HashtagFeedRoute(tag: tag)) },
                    path: $feedPath
                )
            }
            .navigationDestination(for: ThreadRoute.self) { route in
                ThreadView(
                    seedEventId: route.eventId,
                    authorHint: route.authorPubkey,
                    keypair: keypair,
                    path: $feedPath,
                    chain: $feedThreadChain,
                    scrollToId: route.scrollToId
                )
            }
            .navigationDestination(for: LiveStreamRoute.self) { route in
                LiveStreamView(route: route, keypair: keypair)
                    .environment(walletStore)
            }
            .navigationDestination(for: ArticleRoute.self) { route in
                ArticleView(route: route, keypair: keypair, path: $feedPath)
            }
            .recipeNavigation(keypair: keypair, path: $feedPath)
            .navigationDestination(for: HashtagFeedRoute.self) { route in
                hashtagFeedView(for: route)
            }
            .navigationDestination(for: PeopleListFeedRoute.self) { route in
                PeopleListFeedView(
                    keypair: keypair,
                    dTag: route.dTag,
                    onProfileTap: { pubkey in
                        feedPath.append(ProfileRoute(pubkey: pubkey))
                    },
                    onNoteTap: { eventId in
                        feedPath.append(ThreadRoute(eventId: eventId, authorPubkey: ""))
                    },
                    onHashtagTap: { tag in
                        feedPath.append(HashtagFeedRoute(tag: tag))
                    }
                )
            }
            .navigationDestination(for: NoteListFeedRoute.self) { route in
                NoteListFeedView(
                    keypair: keypair,
                    dTag: route.dTag,
                    onProfileTap: { pubkey in
                        feedPath.append(ProfileRoute(pubkey: pubkey))
                    },
                    onNoteTap: { eventId in
                        feedPath.append(ThreadRoute(eventId: eventId, authorPubkey: ""))
                    },
                    onHashtagTap: { tag in
                        feedPath.append(HashtagFeedRoute(tag: tag))
                    }
                )
            }
            // OnlyFood's one-shot start lives on the feed tab's appear path
            // (it used to be OnlyFoodFeedView's `.task`), gated on the kind.
            // `start()` is latched, so tab re-appears and kind switches never
            // re-issue the REQ (§7.4); no prewarming for other kinds.
            .onAppear {
                FeedTabRouting.ensureOnlyFoodStarted(kind: viewModel.currentKind, onlyFood: onlyfoodFeedVM)
            }
            .onChange(of: viewModel.currentKind) { _, kind in
                FeedTabRouting.ensureOnlyFoodStarted(kind: kind, onlyFood: onlyfoodFeedVM)
            }
            .navigationDestination(for: TrendingFeedRoute.self) { _ in
                TrendingFeedView(
                    keypair: keypair,
                    onProfileTap: { pubkey in
                        feedPath.append(ProfileRoute(pubkey: pubkey))
                    },
                    onNoteTap: { eventId in
                        feedPath.append(ThreadRoute(eventId: eventId, authorPubkey: ""))
                    },
                    onHashtagTap: { tag in
                        feedPath.append(HashtagFeedRoute(tag: tag))
                    }
                )
            }
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    private var recipesTab: some View {
        NavigationStack(path: $recipesPath) {
            ZStack(alignment: .bottomTrailing) {
                RecipeFeedView(
                    keypair: keypair,
                    path: $recipesPath,
                    onOpenDrawer: openDrawer,
                    avatarURL: viewModel.userProfile?.picture,
                    onSousChef: SousChefGate.entryVisible() ? { showSousChef = true } : nil,
                    onCheffy: CheffyGate.entryVisible() ? { showCheffy = true } : nil,
                    viewModel: recipeFeedVM
                )
                if !drawerOpen && !isWatchOnly {
                    RecipeComposeFAB { showRecipeCompose = true }
                        .padding(.trailing, 18)
                        .padding(.bottom, 32 + (audioPlayer.currentTrack != nil ? MiniAudioPlayerView.collapsedHeight : 0))
                        .animation(.smooth(duration: 0.22), value: audioPlayer.currentTrack != nil)
                }
            }
            .navigationDestination(for: ProfileRoute.self) { route in
                ProfileView(
                    pubkey: route.pubkey,
                    activeUserPubkey: keypair.pubkey,
                    onProfileTap: { pk in recipesPath.append(ProfileRoute(pubkey: pk)) },
                    onNoteTap: { eid in recipesPath.append(ThreadRoute(eventId: eid, authorPubkey: route.pubkey)) },
                    onHashtagTap: { _ in },
                    path: $recipesPath
                )
            }
            .navigationDestination(for: ThreadRoute.self) { route in
                ThreadView(
                    seedEventId: route.eventId,
                    authorHint: route.authorPubkey,
                    keypair: keypair,
                    path: $recipesPath,
                    chain: $recipesThreadChain,
                    scrollToId: route.scrollToId
                )
            }
            .navigationDestination(for: ArticleRoute.self) { route in
                ArticleView(route: route, keypair: keypair, path: $recipesPath)
            }
            .recipeNavigation(keypair: keypair, path: $recipesPath)
            .toolbar(.hidden, for: .navigationBar)
            .fullScreenCover(isPresented: $showRecipeCompose) {
                RecipeComposeView(
                    keypair: keypair,
                    session: .create,
                    onPublished: { author, dTag in
                        showRecipeCompose = false
                        recipesPath.append(RecipeRoute(author: author, dTag: dTag))
                    },
                    onDismiss: { showRecipeCompose = false }
                )
            }
            .fullScreenCover(isPresented: $showSousChef) {
                SousChefView(
                    keypair: keypair,
                    onPublished: { author, dTag, savedToCookbook in
                        showSousChef = false
                        if savedToCookbook {
                            SuccessToast.shared.show(SousChefGate.savedToast)
                        }
                        recipesPath.append(RecipeRoute(author: author, dTag: dTag))
                    },
                    onDismiss: { showSousChef = false }
                )
            }
            .fullScreenCover(isPresented: $showCheffy) {
                CheffyView(
                    keypair: keypair,
                    onPublished: { author, dTag in
                        showCheffy = false
                        recipesPath.append(RecipeRoute(author: author, dTag: dTag))
                    },
                    onDismiss: { showCheffy = false }
                )
            }
        }
    }

    /// My Kitchen (Concern 3.2). Switch-mounted like Search/Notifications —
    /// the Saved and Published repositories are singletons with their own
    /// one-shot load guards, so a tab re-entry cannot re-issue an identical
    /// filter (§7.4).
    private var kitchenTab: some View {
        NavigationStack(path: $kitchenPath) {
            MyKitchenView(
                keypair: keypair,
                path: $kitchenPath,
                onOpenDrawer: openDrawer,
                avatarURL: viewModel.userProfile?.picture
            )
            .navigationDestination(for: ProfileRoute.self) { route in
                ProfileView(
                    pubkey: route.pubkey,
                    activeUserPubkey: keypair.pubkey,
                    onProfileTap: { pk in kitchenPath.append(ProfileRoute(pubkey: pk)) },
                    onNoteTap: { eid in kitchenPath.append(ThreadRoute(eventId: eid, authorPubkey: route.pubkey)) },
                    onHashtagTap: { _ in },
                    path: $kitchenPath
                )
            }
            .navigationDestination(for: ThreadRoute.self) { route in
                ThreadView(
                    seedEventId: route.eventId,
                    authorHint: route.authorPubkey,
                    keypair: keypair,
                    path: $kitchenPath,
                    chain: $kitchenThreadChain,
                    scrollToId: route.scrollToId
                )
            }
            .navigationDestination(for: ArticleRoute.self) { route in
                ArticleView(route: route, keypair: keypair, path: $kitchenPath)
            }
            .recipeNavigation(keypair: keypair, path: $kitchenPath)
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    private var mainShell: some View {
        VStack(spacing: 0) {
            ZStack {
                // The feed is kept mounted (hidden) rather than switched away,
                // so its ScrollViews survive tab changes and SwiftUI restores
                // the scroll position for free, and so the OnlyFood VM's
                // one-shot cache survives too (§7.4). See `feedTab`.
                feedTab
                    .opacity(selectedTab == .feed ? 1 : 0)
                    .allowsHitTesting(selectedTab == .feed)
                    .accessibilityHidden(selectedTab != .feed)

                // Recipes is the launch tab. Kept mounted so the cache-seeded
                // grid and its ScrollView survive tab changes — the same
                // reason home stays mounted, and so `.task` cannot re-issue
                // the feed REQ (§7.4).
                recipesTab
                    .opacity(selectedTab == .recipes ? 1 : 0)
                    .allowsHitTesting(selectedTab == .recipes)
                    .accessibilityHidden(selectedTab != .recipes)

                switch selectedTab {
                case .feed, .recipes:
                    EmptyView()
                case .messages:
                    MessagesView(viewModel: messagesVM, groupListVM: groupListVM, path: $messagesPath)
                case .search:
                    NavigationStack(path: $searchPath) {
                        SearchView(keypair: keypair, viewModel: searchVM, path: $searchPath)
                            .navigationDestination(for: ProfileRoute.self) { route in
                                ProfileView(
                                    pubkey: route.pubkey,
                                    activeUserPubkey: keypair.pubkey,
                                    onProfileTap: { pk in searchPath.append(ProfileRoute(pubkey: pk)) },
                                    onNoteTap: { eid in searchPath.append(ThreadRoute(eventId: eid, authorPubkey: route.pubkey)) },
                                    onHashtagTap: { _ in },
                                    path: $searchPath
                                )
                            }
                            .navigationDestination(for: ThreadRoute.self) { route in
                                ThreadView(
                                    seedEventId: route.eventId,
                                    authorHint: route.authorPubkey,
                                    keypair: keypair,
                                    path: $searchPath,
                                    chain: $searchThreadChain,
                                    scrollToId: route.scrollToId
                                )
                            }
                            .navigationDestination(for: ArticleRoute.self) { route in
                                ArticleView(route: route, keypair: keypair, path: $searchPath)
                            }
                            .recipeNavigation(keypair: keypair, path: $searchPath)
                            .toolbar(.hidden, for: .navigationBar)
                    }
                case .notifications:
                    NavigationStack(path: $notificationsPath) {
                        NotificationsView(
                            viewModel: notificationsVM,
                            onPeerTap: { pubkey in
                                notificationsPath.append(ProfileRoute(pubkey: pubkey))
                            },
                            onDmTap: { _ in
                                selectedTab = .messages
                            },
                            onNoteTap: { eventId, authorHint in
                                // Kind-30023 (recipe vs article) is classified
                                // from the cached notification event. Cache miss
                                // or a regular note still opens the thread —
                                // never a recipe screen with no event.
                                if let event = NotificationRepository.shared.event(forId: eventId),
                                   event.kind == RecipeParser.recipeKind {
                                    ArticleTapRouting.appendLongForm(
                                        to: &notificationsPath,
                                        event: event,
                                        author: event.pubkey,
                                        dTag: RecipeParser.dTag(event)
                                    )
                                } else {
                                    // Prefer the actual reply author (passed up from
                                    // the row) over keypair.pubkey — gives ThreadView
                                    // a relay set that actually has the focal +
                                    // ancestors instead of the user's own inbox.
                                    notificationsPath.append(ThreadRoute(
                                        eventId: eventId,
                                        authorPubkey: authorHint ?? keypair.pubkey
                                    ))
                                }
                            }
                        )
                        .navigationDestination(for: ProfileRoute.self) { route in
                            ProfileView(
                                pubkey: route.pubkey,
                                activeUserPubkey: keypair.pubkey,
                                onProfileTap: { pk in notificationsPath.append(ProfileRoute(pubkey: pk)) },
                                onNoteTap: { eid in notificationsPath.append(ThreadRoute(eventId: eid, authorPubkey: route.pubkey)) },
                                onHashtagTap: { _ in },
                                path: $notificationsPath
                            )
                        }
                        .navigationDestination(for: ThreadRoute.self) { route in
                            ThreadView(
                                seedEventId: route.eventId,
                                authorHint: route.authorPubkey,
                                keypair: keypair,
                                path: $notificationsPath,
                                chain: $notificationsThreadChain,
                                scrollToId: route.scrollToId
                            )
                        }
                        .navigationDestination(for: ArticleRoute.self) { route in
                            ArticleView(route: route, keypair: keypair, path: $notificationsPath)
                        }
                        .recipeNavigation(keypair: keypair, path: $notificationsPath)
                        .toolbar(.hidden, for: .navigationBar)
                    }
                case .kitchen:
                    kitchenTab
                // 3.2 retired the `.kitchen` placeholder — every tab now
                // has real content, so the switch is exhaustive without a
                // placeholder fall-through.
                case .wallet:
                    NavigationStack {
                        WalletView(store: walletStore)
                            .toolbar(.hidden, for: .navigationBar)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Animation modifier scoped to the audio-player slot only. Hoisting
            // it onto the surrounding VStack made the player toggle catch any
            // unrelated state change in the active tab (notifications,
            // timeline) in the same frame, producing a "float-down" of late
            // arriving rows over existing content.
            FloatingTimerBar(
                store: cookingTimers,
                isSheetVisible: showCookingUtilitiesSheet,
                onExpand: { showCookingUtilitiesSheet = true }
            )

            Group {
                if audioPlayer.currentTrack != nil {
                    MiniAudioPlayerView()
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                } else {
                    Divider().overlay(Color.wispSurfaceVariant.opacity(0.5))
                }
            }
            .animation(.smooth(duration: 0.22), value: audioPlayer.currentTrack != nil)

            bottomBar
        }
        .background(Color.wispBackground)
    }

    // MARK: - Drawer

    private func openDrawer() {
        drawerDragOffset = 0
        withAnimation(.smooth(duration: 0.25)) { drawerOpen = true }
    }

    private func closeDrawer() {
        withAnimation(.smooth(duration: 0.25)) {
            drawerOpen = false
            drawerDragOffset = 0
        }
    }

    private var drawerDragGesture: some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                guard drawerOpen else { return }
                drawerDragOffset = min(0, value.translation.width)
            }
            .onEnded { value in
                guard drawerOpen else { return }
                if value.translation.width < -drawerWidth * 0.3 {
                    closeDrawer()
                } else {
                    withAnimation(.smooth(duration: 0.2)) { drawerDragOffset = 0 }
                }
            }
    }

    // MARK: - Top Bar

    private var topBar: some View {
        HStack(spacing: 12) {
            profileAvatar
            // Neither the content filter nor the relay-count pill applies to
            // the hashtag-backed OnlyFood feed.
            if viewModel.currentKind != .onlyFood {
                contentFilterButton
            }

            Spacer()

            HStack(spacing: 8) {
                if !viewModel.onlineNetworkPubkeys.isEmpty {
                    Button {
                        showOnlineSheet = true
                    } label: {
                        statusPill(
                            icon: "person.fill",
                            value: formatCount(viewModel.onlineNetworkPubkeys.count),
                            color: .wispRepostColor
                        )
                    }
                    .buttonStyle(.plain)
                }

                if viewModel.currentKind != .onlyFood {
                    Menu {
                        if viewModel.connectedRelays.isEmpty {
                            Text("Not connected")
                        } else {
                            ForEach(viewModel.connectedRelays, id: \.url) { relay in
                                let host = URL(string: relay.url)?.host ?? relay.url
                                Button {
                                    viewModel.selectRelay(url: relay.url)
                                } label: {
                                    Text("\(host) (\(relay.authorCount))")
                                }
                            }
                        }
                    } label: {
                        statusPill(
                            icon: "network",
                            value: "\(viewModel.connectedRelayCount)",
                            color: viewModel.connectedRelayCount > 0 ? .wispRepostColor : .red
                        )
                    }
                }
            }
        }
        .overlay(feedPicker)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var profileAvatar: some View {
        Button {
            openDrawer()
        } label: {
            CachedAvatarView(url: viewModel.userProfile?.picture, size: 32)
        }
        .buttonStyle(.plain)
    }

    /// Cycles the feed's client-side content filter: ALL → notes →
    /// gallery → polls → ALL. Icon reflects the active filter. While
    /// any non-default filter is active the icon picks up the primary
    /// tint so it's obvious the feed is filtered. Mirrors Wisp Android's
    /// `ContentFilter` toggle next to the feed selector — see
    /// barrydeen/wisp commit a6a4a4a for the cross-platform shape.
    private var contentFilterButton: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                viewModel.cycleContentFilter()
            }
        } label: {
            Image(systemName: viewModel.contentFilter.iconName)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(
                    viewModel.contentFilter == .all
                        ? AnyShapeStyle(.secondary)
                        : AnyShapeStyle(Color.wispPrimary)
                )
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Content filter — \(viewModel.contentFilter.rawValue)")
    }

    /// Feed picker. OnlyFood leads, then a divider, then the rest in
    /// Android's order (unified-feed §2.3).
    private var feedPicker: some View {
        Menu {
            Button {
                viewModel.selectOnlyFood()
            } label: {
                Label("OnlyFood", systemImage: viewModel.currentKind == .onlyFood ? "checkmark" : "leaf")
            }

            Divider()

            Button {
                viewModel.selectFollows()
            } label: {
                Label("Follows", systemImage: viewModel.currentKind == .follows ? "checkmark" : "person.2")
            }

            Button {
                viewModel.selectExtendedNetwork()
            } label: {
                Label(
                    "Extended Network",
                    systemImage: viewModel.currentKind == .extendedNetwork
                        ? "checkmark"
                        : "point.3.connected.trianglepath.dotted"
                )
            }

            Button {
                feedPath.append(TrendingFeedRoute())
            } label: {
                Label("Trending", systemImage: "flame")
            }

            Button {
                showRelayPicker = true
            } label: {
                let active: Bool = {
                    switch viewModel.currentKind {
                    case .onlyFood, .follows, .extendedNetwork: return false
                    case .relay, .relaySet: return true
                    }
                }()
                Label("Relay", systemImage: active ? "checkmark" : "antenna.radiowaves.left.and.right")
            }

            Button {
                showHashtagSets = true
            } label: {
                Label("Hashtags", systemImage: "number")
            }

            Button {
                showLists = true
            } label: {
                Label("Lists", systemImage: "list.bullet")
            }
        } label: {
            HStack(spacing: 4) {
                // Tail truncation at 140pt, as Android (`widthIn(max = 140.dp)`
                // + Ellipsis); `.middle` mangled relay hostnames.
                Text(viewModel.currentKind.displayName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 140)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(Color.wispSurfaceVariant.opacity(0.5), in: RoundedRectangle(cornerRadius: 20))
            .foregroundStyle(Color.primary)
        }
    }

    private func statusPill(icon: String, value: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(color)
            Text(value)
                .font(.caption.weight(.medium))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.wispSurfaceVariant.opacity(0.5), in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Feed Content

    private var emptyStateTitle: String {
        // When a content filter is engaged and the underlying feed has
        // events (just none of the active type), use the filter-specific
        // caption — saying "No posts yet" while the user is staring at
        // a filtered view is misleading. The base-state titles below
        // apply when the raw feed itself is still empty.
        if viewModel.contentFilter != .all && !viewModel.events.isEmpty {
            return viewModel.contentFilter.emptyStateCaption
        }
        switch viewModel.currentKind {
        case .onlyFood: return "No food posts yet"  // unreachable: OnlyFood renders `onlyFoodBody`
        case .follows: return "No posts yet"
        case .relay: return "Connecting…"
        case .relaySet: return "Connecting…"
        case .extendedNetwork:
            return SocialGraphCache.load(pubkey: keypair.pubkey) == nil
                ? "No extended network yet"
                : "Connecting…"
        }
    }

    private var emptyStateSubtitle: String {
        switch viewModel.currentKind {
        case .onlyFood:
            return "Pull down to refresh."  // unreachable: OnlyFood renders `onlyFoodBody`
        case .follows:
            return "Follow some people to see their posts here"
        case .relay(let url):
            return "Waiting for events from \(URL(string: url)?.host ?? url)."
        case .relaySet(let set):
            return "Waiting for events across \(set.relays.count) relay\(set.relays.count == 1 ? "" : "s")."
        case .extendedNetwork:
            if SocialGraphCache.load(pubkey: keypair.pubkey) == nil {
                return "Compute your social graph to see posts from accounts followed by your follows."
            }
            return "Waiting for events from your extended network."
        }
    }

    @ViewBuilder
    private var emptyStateExtraAction: some View {
        switch viewModel.currentKind {
        case .extendedNetwork where SocialGraphCache.load(pubkey: keypair.pubkey) == nil:
            emptyStateActionButton("Compute Now") { showSocialGraph = true }
        case .onlyFood, .follows, .relay, .relaySet, .extendedNetwork:
            EmptyView()
        }
    }

    private func emptyStateActionButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 24)
                .padding(.vertical, 10)
                .background(Color.wispPrimary, in: RoundedRectangle(cornerRadius: 12))
                .foregroundStyle(.white)
        }
        .padding(.top, 8)
    }

    @ViewBuilder
    private var relayFeedStatusBanner: some View {
        switch viewModel.currentKind {
        case .follows, .onlyFood:
            EmptyView()
        case .relay, .relaySet, .extendedNetwork:
            switch viewModel.relayFeedStatus {
            case .idle, .streaming:
                EmptyView()
            case .connecting:
                statusBanner(text: "Connecting…", color: .secondary)
            case .noEvents:
                statusBanner(text: "No events received yet", color: .orange)
            case .timedOut:
                statusBanner(text: "Connection timed out", color: .red)
            case .connectionFailed(let msg):
                statusBanner(text: msg, color: .red)
            }
        }
    }

    private func statusBanner(text: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text).font(.caption)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(Color.wispSurfaceVariant.opacity(0.4))
    }

    /// One surface, two bodies (unified feed PR 2). OnlyFood renders
    /// `OnlyFoodFeedViewModel`'s list; every other kind renders the general
    /// feed. Affordances stay with their body: the relay-status banner, the
    /// live-now strip, the new-posts pill and the content filter belong to
    /// the general feed; OnlyFood has its own loading / empty / relay-miss
    /// states. Both share the top bar, the picker and `feedPath`.
    @ViewBuilder
    private var feedContent: some View {
        switch FeedTabRouting.body(for: viewModel.currentKind) {
        case .onlyFood:
            onlyFoodBody
        case .general:
            VStack(spacing: 0) {
                relayFeedStatusBanner
                feedBody
            }
        }
    }

    // MARK: - OnlyFood body (moved from the deleted OnlyFoodFeedView)

    /// Four states plus the list: loading, relay miss, WoT hid everything,
    /// genuine empty — one truth table in
    /// `OnlyFoodFeedViewModel.displayState(wotEnabled:)`. The WoT branch is
    /// gated on the LIVE toggle (§4), so a stale count from a now-disabled
    /// filter can never claim posts were hidden.
    @ViewBuilder
    private var onlyFoodBody: some View {
        switch onlyfoodFeedVM.displayState(wotEnabled: safetyPrefs.onlyFoodWotEnabled) {
        case .loading:
            onlyFoodLoadingState
        case .relayMiss:
            onlyFoodErrorState
        case .wotHidden(let count):
            onlyFoodWotHiddenState(count: count)
        case .empty:
            onlyFoodEmptyState
        case .list:
            onlyFoodList
        }
    }

    /// The web-of-trust filter dropped everything the load accepted (§4,
    /// Android `FeedScreen`'s OnlyFood branch). "Show all" flips the toggle
    /// off; the toggle's change notification reloads the feed.
    private func onlyFoodWotHiddenState(count: Int) -> some View {
        VStack(spacing: 12) {
            Spacer()
            Text("🍳")
                .font(.system(size: 40))
            Text("\(count) \(count == 1 ? "post" : "posts") hidden by your web-of-trust filter")
                .font(AppFont.bodyLarge)
                .foregroundStyle(Color.wispOnSurfaceVariant)
                .multilineTextAlignment(.center)
            Button("Show all") {
                safetyPrefs.onlyFoodWotEnabled = false
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 4)
            Button("Go to social graph") {
                showSocialGraph = true
            }
            .buttonStyle(.bordered)
            Spacer()
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .refreshable { await onlyfoodFeedVM.refreshAndWait() }
        .accessibilityLabel("\(count) \(count == 1 ? "post" : "posts") hidden by your web-of-trust filter")
    }

    private var onlyFoodLoadingState: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text("Loading food posts\u{2026}")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityLabel("Fetching food posts")
    }

    /// Genuine empty: EOSE arrived and nothing was accepted.
    private var onlyFoodEmptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Text("🍳")
                .font(.system(size: 40))
            Text("No food posts yet")
                .font(AppFont.bodyLarge)
                .foregroundStyle(Color.wispOnSurfaceVariant)
            Text("Pull down to refresh.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .refreshable { await onlyfoodFeedVM.refreshAndWait() }
        .accessibilityLabel("No food posts yet")
    }

    /// Relay miss (timeout / dropped send / connect fail). Must not reuse
    /// the genuine-empty copy — a down search relay is not "no food posts."
    private var onlyFoodErrorState: some View {
        VStack(spacing: 8) {
            Spacer()
            Text("Couldn't reach the food feed")
                .font(AppFont.bodyLarge)
                .foregroundStyle(Color.wispOnSurface)
                .multilineTextAlignment(.center)
            Text("Pull down to retry.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .refreshable { await onlyfoodFeedVM.refreshAndWait() }
        .accessibilityLabel("Couldn't reach the food feed")
    }

    private var onlyFoodList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    // Same anchor as the general feed so a feed-tab re-tap
                    // scrolls this list to the top too.
                    Color.clear.frame(height: 0).id("feedTop")
                    ForEach(Array(onlyfoodFeedVM.notes.enumerated()), id: \.element.id) { index, event in
                        PostCardView(
                            event: event,
                            profile: onlyfoodFeedVM.profiles[event.pubkey],
                            profiles: onlyfoodFeedVM.profiles,
                            engagement: nil,
                            onProfileTap: { pubkey in
                                feedPath.append(ProfileRoute(pubkey: pubkey))
                            },
                            onNoteTap: { eventId in
                                feedPath.append(ThreadRoute(eventId: eventId, authorPubkey: event.pubkey))
                            },
                            onHashtagTap: { tag in
                                feedPath.append(HashtagFeedRoute(tag: tag))
                            }
                        )
                        .equatable()
                        // Same programmatic push as the general feed (not a
                        // NavigationLink wrapper): the link's press gesture
                        // loses races against the inner avatar / action-bar /
                        // link buttons, so taps on empty card space needed
                        // two presses. One tap behavior across the surface.
                        .contentShape(Rectangle())
                        .onTapGesture {
                            ArticleTapRouting.appendCardTap(to: &feedPath, event: event)
                        }
                        .onAppear {
                            engagementRepo.markVisible(event: event)
                            MediaLookaheadPrefetcher.shared.noteAppeared(
                                eventId: event.id,
                                in: onlyfoodFeedVM.notes,
                                profiles: onlyfoodFeedVM.profiles
                            )
                            onlyfoodFeedVM.loadMoreIfNeeded(
                                currentIndex: index,
                                total: onlyfoodFeedVM.notes.count
                            )
                        }
                        .onDisappear {
                            engagementRepo.markInvisible(event: event)
                        }
                        Divider().overlay(Color.wispSurfaceVariant.opacity(0.3))
                    }
                    if onlyfoodFeedVM.isPaging {
                        ProgressView()
                            .padding(16)
                            .frame(maxWidth: .infinity)
                    }
                }
            }
            .ignoresSafeArea(.keyboard, edges: .bottom)
            .refreshable { await onlyfoodFeedVM.refreshAndWait() }
            .onScrollPhaseChange { _, newPhase in
                switch newPhase {
                case .tracking, .interacting:
                    feedFabOpacity = 0.35
                case .decelerating, .animating:
                    feedFabOpacity = 0.75
                case .idle:
                    feedFabOpacity = 1.0
                @unknown default:
                    feedFabOpacity = 1.0
                }
            }
            .onChange(of: feedScrollToTopTrigger) { _, _ in
                withAnimation(.easeInOut(duration: 0.3)) {
                    proxy.scrollTo("feedTop", anchor: .top)
                }
            }
        }
    }

    private var feedBody: some View {
        Group {
            if viewModel.isLoading && viewModel.events.isEmpty {
                VStack(spacing: 16) {
                    ProgressView()
                    Text("Loading your feed\u{2026}")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.filteredEvents.isEmpty {
                VStack(spacing: 16) {
                    Image(systemName: "text.bubble")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                    Text(emptyStateTitle)
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Text(emptyStateSubtitle)
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                    emptyStateExtraAction
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { feedProxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        // Anchor for tap-Home-on-Home → scroll-to-top. Zero-height
                        // so it doesn't reserve layout space.
                        Color.clear.frame(height: 0).id("feedTop")
                        // Self-contained so live-chat `streams` mutations
                        // don't re-evaluate this feed body (and every
                        // PostCardView in it) — see `FeedLiveNowSection`.
                        // Not shown on OnlyFood (§2.3).
                        if viewModel.currentKind != .onlyFood {
                            FeedLiveNowSection(
                                profiles: viewModel.profiles,
                                onSelect: { stream in
                                    feedPath.append(LiveStreamRoute(
                                        aTagValue: stream.aTagValue,
                                        hostPubkey: stream.activity.hostPubkey,
                                        dTag: stream.activity.dTag,
                                        relayHints: stream.activity.relayHints
                                    ))
                                }
                            )
                        }
                        // Iterating events directly with `id: \.id` keeps row
                        // identity stable when the array shifts (new posts
                        // prepended). The previous `Array(events.enumerated())`
                        // wrapper changed every row's underlying tuple
                        // identity on every prepend, forcing SwiftUI to
                        // re-instantiate every visible PostCardView.
                        // `filteredEvents` applies the content-filter
                        // toggle (`viewModel.contentFilter`). Identity is
                        // still `\.id` so row reuse is unaffected by the
                        // filter swap — flipping the filter dissolves
                        // rows rather than tearing down PostCardView
                        // state. Load-more uses index in the filtered
                        // list so reaching the bottom of what the user
                        // sees triggers a fetch even when the underlying
                        // `events` list is much longer (most events
                        // were rejected by the filter).
                        let visible = viewModel.filteredEvents
                        // Optimistic post row — appears the instant the user
                        // taps Post in the composer and dissolves when the
                        // real published event arrives via the existing
                        // `.nostrEventPublished` observer on FeedViewModel
                        // (which inserts the event into `visible` above this
                        // pending row in the same render). See PendingPostStore.
                        // Gate on `!pendingIsReply` so the home feed never
                        // shows a reply that belongs to a thread view.
                        if let pending = PendingPostStore.shared.pending,
                           !PendingPostStore.shared.pendingIsReply {
                            PendingPostRow(pending: pending)
                                .padding(.vertical, 4)
                        }
                        // Precompute the last-5 ids once per body eval so each
                        // row's onAppear is an O(1) Set lookup instead of an
                        // O(n) `firstIndex` scan (which made deep scroll O(n²)).
                        let loadMoreTriggerIds = Set(visible.suffix(5).map(\.id))
                        ForEach(visible, id: \.id) { event in
                            PostCardView(
                                event: event,
                                profile: viewModel.profiles[event.pubkey],
                                profiles: viewModel.profiles,
                                engagement: nil,
                                onProfileTap: { pubkey in
                                    Task { await viewModel.requestProfileIfNeeded(pubkey) }
                                },
                                onNoteTap: { eventId in
                                    feedPath.append(ThreadRoute(eventId: eventId, authorPubkey: event.pubkey))
                                },
                                onHashtagTap: { tag in
                                    feedPath.append(HashtagFeedRoute(tag: tag))
                                }
                            )
                            // Skip re-rendering rows whose inputs are unchanged
                            // (the LazyVStack re-invokes this builder with fresh
                            // closures on every scroll tick). See PostCardView ==.
                            .equatable()
                            // Programmatic push instead of wrapping the card in a
                            // NavigationLink — the link's press gesture loses races
                            // against the inner avatar / action-bar / link buttons,
                            // so taps on empty card space frequently needed two
                            // presses to fire. Inner Buttons still capture their
                            // own taps before this gesture runs.
                            .contentShape(Rectangle())
                            .onTapGesture {
                                ArticleTapRouting.appendCardTap(to: &feedPath, event: event)
                            }
                            .onAppear {
                                engagementRepo.markVisible(event: event)
                                // Warm media (images / GIF bytes / posters /
                                // avatars) for the next ~10 rows so they're
                                // decoded before they scroll in. O(1) per
                                // appear (internally cached index map).
                                MediaLookaheadPrefetcher.shared.noteAppeared(
                                    eventId: event.id,
                                    in: visible,
                                    profiles: viewModel.profiles
                                )
                                if loadMoreTriggerIds.contains(event.id) {
                                    // Routes Follows → disk-replay scroll-back,
                                    // relay/extended → relay loadMore.
                                    viewModel.loadOlder()
                                }
                            }
                            .onDisappear {
                                engagementRepo.markInvisible(event: event)
                            }
                            Divider()
                                .overlay(Color.wispSurfaceVariant.opacity(0.3))
                        }
                        // Defensively strip any ambient animation from row
                        // diffs so a late-arriving event merged into
                        // `viewModel.events` can't ride a sibling animation
                        // transaction (audio-player slide, new-posts-pill
                        // toggle, etc.) and visibly "float down" from its
                        // insertion index into its sorted position. The
                        // upstream `withTransaction(animation: nil)` around
                        // `events = ...` in `flushPendingInserts` doesn't
                        // carry across the `@Observable` render-pass
                        // boundary; this is the last line of defense.
                        .transaction { $0.animation = nil }
                    }
                }
                // Keep the feed's layout stable when a composer raises the
                // keyboard — without this the safe-area shrink reflows the
                // LazyVStack and recycles rows. Parity with every other feed
                // (Search, Hashtag, Trending, NoteList, PeopleList, Thread).
                .ignoresSafeArea(.keyboard, edges: .bottom)
                .refreshable { await viewModel.refresh() }
                .onScrollPhaseChange { _, newPhase in
                    switch newPhase {
                    case .tracking, .interacting:
                        feedFabOpacity = 0.35
                    case .decelerating, .animating:
                        feedFabOpacity = 0.75
                    case .idle:
                        feedFabOpacity = 1.0
                    @unknown default:
                        feedFabOpacity = 1.0
                    }
                }
                // Drive the new-posts hold flag from the live scroll offset.
                // 8pt slop covers rubber-band overshoot at the top so we
                // don't flicker the pill on/off while the user is parked
                // there.
                .onScrollGeometryChange(for: Bool.self) { geo in
                    geo.contentOffset.y <= 8
                } action: { _, atTop in
                    feedAtTop = atTop
                    viewModel.setHoldNewPosts(!atTop)
                }
                .onChange(of: feedScrollToTopTrigger) { _, _ in
                    withAnimation(.easeInOut(duration: 0.3)) {
                        feedProxy.scrollTo("feedTop", anchor: .top)
                    }
                }
                .overlay(alignment: .top) {
                    // Animation modifier scoped INSIDE the overlay so the pill's
                    // enter/exit transition fires, but the row LazyVStack above
                    // is not part of the same value-scoped transaction. Hoisting
                    // this onto the ScrollView caused stragglers from a sorted
                    // insert to visibly "float down" whenever pendingNewCount
                    // toggled in the same frame as a merge.
                    Group {
                        if viewModel.pendingNewCount > 0 && !feedAtTop {
                            NewPostsPill(
                                count: viewModel.pendingNewCount,
                                onTap: {
                                    viewModel.applyPendingNewPosts()
                                    // Defer to the next runloop so the LazyVStack
                                    // has a chance to lay out the prepended rows
                                    // before we resolve `feedTop`. Without this,
                                    // `scrollTo` runs against the pre-merge
                                    // layout and only nudges the offset by a
                                    // single row's height.
                                    DispatchQueue.main.async {
                                        withAnimation(.easeInOut(duration: 0.35)) {
                                            feedProxy.scrollTo("feedTop", anchor: .top)
                                        }
                                    }
                                },
                                onDismiss: {
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        viewModel.dismissPendingNewPosts()
                                    }
                                }
                            )
                            .padding(.top, 8)
                            .opacity(feedFabOpacity)
                            .animation(.easeInOut(duration: 0.2), value: feedFabOpacity)
                            .transition(.move(edge: .top).combined(with: .opacity))
                        }
                    }
                    .animation(.pillDropFast, value: viewModel.pendingNewCount > 0)
                }
                }
            }
        }
    }

    // MARK: - Bottom Bar

    /// Android `WispBottomBar` minus the raised wallet: icon only, no labels,
    /// 24pt glyphs (Feed 26pt, as Android bumps its flame to 24dp next to
    /// 21dp siblings), an 8pt amber unread dot on Messages and Notifications.
    /// Watch-only accounts get Android's read-only bar shape: Messages is
    /// dropped (it is drawer-gated for them today for the same reason).
    private var bottomBar: some View {
        HStack {
            ForEach(BottomTab.bottomBarCases(watchOnly: isWatchOnly), id: \.self) { tab in
                Button {
                    if selectedTab == tab {
                        popToRoot(tab)
                    } else {
                        selectedTab = tab
                    }
                } label: {
                    Image(systemName: tab == selectedTab ? tab.selectedIcon : tab.icon)
                        .font(.system(size: tab.barGlyphSize))
                        .frame(height: 30)
                        .frame(maxWidth: .infinity)
                        .overlay(alignment: .topTrailing) {
                            if hasUnreadBadge(tab) {
                                Circle()
                                    .fill(BottomTab.unreadDotColor)
                                    .frame(width: 8, height: 8)
                                    .offset(x: -10, y: 2)
                            }
                        }
                }
                .foregroundStyle(tab == selectedTab ? Color.wispPrimary : .secondary)
                .accessibilityLabel(tab.title)
                .accessibilityIdentifier("tab-\(tab.rawValue)")
            }
        }
        .padding(.vertical, 10)
        .padding(.bottom, 2)
    }

    /// Android drives `hasUnreadMessages` / `hasUnreadNotifications` into the
    /// same `SideNavItem` dot; both badged tabs read the same way here.
    private func hasUnreadBadge(_ tab: BottomTab) -> Bool {
        switch tab {
        case .notifications: return notificationsVM.hasUnread
        case .messages: return messagesVM.hasUnread
        case .feed, .recipes, .search, .kitchen, .wallet: return false
        }
    }

    // MARK: - Helpers

    /// Tapping the already-selected tab pops its navigation stack back to the
    /// tab's root view. Mirrors the standard iOS tab-bar gesture.
    /// For Home, also bump `feedScrollToTopTrigger` — when the stack is already
    /// empty (already on the feed root) the path-clear is a no-op and only the
    /// scroll-to-top fires; when there's something pushed, the path-clear pops
    /// first and the scroll-to-top runs against the now-visible feed.
    private func popToRoot(_ tab: BottomTab) {
        switch tab {
        case .feed:
            FeedTabRouting.popFeedToRoot(
                kind: viewModel.currentKind,
                path: &feedPath,
                scrollToTopTrigger: &feedScrollToTopTrigger
            )
        case .recipes: recipesPath = NavigationPath()
        case .wallet: placeholderPath = NavigationPath()
        case .search: searchPath = NavigationPath()
        case .notifications: notificationsPath = NavigationPath()
        case .messages: messagesPath = NavigationPath()
        case .kitchen: kitchenPath = NavigationPath()
        }
    }

    private func formatCount(_ n: Int) -> String {
        switch n {
        case 1_000_000...: String(format: "%.1fM", Double(n) / 1_000_000)
        case 1_000...: String(format: "%.1fk", Double(n) / 1_000)
        default: "\(n)"
        }
    }

    @ViewBuilder
    private func hashtagFeedView(for route: HashtagFeedRoute) -> some View {
        if let tag = route.tag {
            HashtagFeedView(
                keypair: keypair,
                source: .single(tag),
                onHashtagTap: { newTag in
                    feedPath.append(HashtagFeedRoute(tag: newTag))
                }
            )
        } else if let dTag = route.setDTag,
                  let set = hashtagSetRepo.hashtagSet(dTag: dTag) {
            HashtagFeedView(
                keypair: keypair,
                source: .set(set),
                onHashtagTap: { newTag in
                    feedPath.append(HashtagFeedRoute(tag: newTag))
                }
            )
        } else {
            VStack(spacing: 12) {
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 40))
                    .foregroundStyle(.tertiary)
                Text("Set not found")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.wispBackground)
        }
    }
}

// MARK: - Bottom Tab Definition

enum BottomTab: String, CaseIterable {
    // Bottom-bar tabs (unified feed §5): Android's bar with Search in the
    // wallet's slot — Feed · Recipes · Search · Messages · Notifications.
    // Bar ORDER and LAUNCH TAB are separate settings: `MainView.selectedTab`
    // still launches on `.recipes` (Gate 0-E's food-first lock); Feed
    // defaulting to OnlyFood carries the food-first story.
    /// The one feed surface (unified feed PR 2): OnlyFood or the general
    /// feed by `FeedViewModel.currentKind`.
    case feed
    case recipes
    case search
    case messages
    case notifications

    // Drawer-only destinations — NOT rendered in the bottom bar. `wallet`
    // stays out of the bar for App Store review; `kitchen` (My Kitchen)
    // moved to the drawer in PR 6 when Messages took its slot. Their paths
    // and thread chains are unchanged; only membership moved.
    case kitchen
    case wallet

    /// The five cases rendered in the bottom bar, in display order.
    /// Drawer-only destinations are intentionally excluded.
    static let bottomBarCases: [BottomTab] = [.feed, .recipes, .search, .messages, .notifications]

    /// Android's read-only bar drops Messages (and Wallet); watch-only
    /// accounts cannot send DMs, and the drawer already gated the row.
    static func bottomBarCases(watchOnly: Bool) -> [BottomTab] {
        watchOnly ? bottomBarCases.filter { $0 != .messages } : bottomBarCases
    }

    /// Destinations reachable only from the drawer.
    static let drawerOnlyCases: [BottomTab] = allCases.filter { !bottomBarCases.contains($0) }

    /// Unread dot — brand amber-400 (`#FBBF24`), lighter than the tinted
    /// nav icons so it reads as an alert rather than blending in (Android
    /// `UnreadDotColor`).
    static let unreadDotColor = Color(red: 0xFB / 255, green: 0xBF / 255, blue: 0x24 / 255)

    /// Bar glyph point size: 24pt, Feed 26pt (Android 21dp with the flame
    /// bumped to 24dp — the flame reads small next to its siblings).
    var barGlyphSize: CGFloat { self == .feed ? 26 : 24 }

    var icon: String {
        switch self {
        case .feed: "flame"
        case .recipes: "book"
        case .search: "magnifyingglass"
        case .messages: "bubble.left.and.bubble.right"
        case .notifications: "bell"
        case .kitchen: "fork.knife"
        case .wallet: "creditcard"
        }
    }

    var selectedIcon: String {
        switch self {
        case .feed: "flame.fill"
        case .recipes: "book.fill"
        case .search: "magnifyingglass"
        case .messages: "bubble.left.and.bubble.right.fill"
        case .notifications: "bell.fill"
        case .kitchen: "fork.knife"
        case .wallet: "creditcard.fill"
        }
    }

    /// Human-readable label for placeholder surfaces and accessibility.
    var title: String {
        switch self {
        case .recipes: "Recipes"
        case .feed: "Feed"
        case .search: "Search"
        case .kitchen: "My Kitchen"
        case .notifications: "Notifications"
        case .wallet: "Wallet"
        case .messages: "Messages"
        }
    }
}

private struct OnlineNowSheet: View {
    let networkPubkeys: [String]
    let globalCount: Int?
    let profiles: [String: ProfileData]
    let onTapProfile: (String) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Online Now")
                    .font(.title2.weight(.semibold))

                row(text: "\(networkPubkeys.count) online in your network")
                if let g = globalCount {
                    row(text: "\(g) online across all of Nostr")
                }

                FlowLayout(spacing: 8) {
                    ForEach(networkPubkeys, id: \.self) { pk in
                        Button {
                            onTapProfile(pk)
                        } label: {
                            CachedAvatarView(url: profiles[pk]?.picture, size: 44)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
        }
    }

    private func row(text: String) -> some View {
        HStack(spacing: 8) {
            Circle().fill(Color.wispRepostColor).frame(width: 8, height: 8)
            Text(text).font(.subheadline)
        }
    }
}
