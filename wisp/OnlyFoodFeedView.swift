import SwiftUI

/// OnlyFood 🍳 — the foodstr social feed (Concern 3.3). A Global / Following
/// toggle over the expanded food-hashtag set. Notes render via the shared
/// `PostCardView`. Pull-to-refresh is the only re-query path (§7.4).
///
/// Empty Following is a clear invite to Global — never a spinner, never an error.
struct OnlyFoodFeedView: View {
    let keypair: Keypair
    @Binding var path: NavigationPath
    var onOpenDrawer: () -> Void
    var avatarURL: String?

    @Bindable var viewModel: OnlyFoodFeedViewModel
    @State private var engagementRepo = EngagementRepository.shared

    init(
        keypair: Keypair,
        path: Binding<NavigationPath>,
        onOpenDrawer: @escaping () -> Void,
        avatarURL: String? = nil,
        viewModel: OnlyFoodFeedViewModel
    ) {
        self.keypair = keypair
        self._path = path
        self.onOpenDrawer = onOpenDrawer
        self.avatarURL = avatarURL
        self.viewModel = viewModel
    }

    var body: some View {
        content
            .background(Color.wispBackground)
            .wispTopHeader { header }
            .toolbar(.hidden, for: .navigationBar)
            .task { viewModel.start() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Button(action: onOpenDrawer) {
                    CachedAvatarView(url: avatarURL, size: 32, alwaysLoad: true)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Open menu")

                Text("OnlyFood 🍳")
                    .font(AppFont.titleMedium)
                    .foregroundStyle(Color.wispOnSurface)

                Spacer(minLength: 0)
            }

            Picker("Feed mode", selection: modeBinding) {
                Text("Global").tag(OnlyFoodFeedViewModel.Mode.global)
                Text("Following").tag(OnlyFoodFeedViewModel.Mode.following)
            }
            .pickerStyle(.segmented)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var modeBinding: Binding<OnlyFoodFeedViewModel.Mode> {
        Binding(
            get: { viewModel.mode },
            set: { viewModel.setMode($0) }
        )
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.emptyFollows {
            emptyFollowsState
        } else if viewModel.isAwaitingFirstPaint {
            loadingState
        } else if viewModel.isEmpty {
            emptyState
        } else {
            feedList
        }
    }

    private var loadingState: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text("Loading food posts\u{2026}")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityLabel("Fetching food posts")
    }

    /// Following with an empty follow list. Invites Global; not a spinner.
    private var emptyFollowsState: some View {
        VStack(spacing: 12) {
            Spacer()
            Text("🍳")
                .font(.system(size: 40))
            Text("You're not following anyone yet")
                .font(AppFont.bodyLarge)
                .foregroundStyle(Color.wispOnSurface)
                .multilineTextAlignment(.center)
            Text("Switch to Global to see food posts from the network.")
                .font(.subheadline)
                .foregroundStyle(Color.wispOnSurfaceVariant)
                .multilineTextAlignment(.center)
            Button("View Global") {
                viewModel.setMode(.global)
            }
            .buttonStyle(.borderedProminent)
            .padding(.top, 4)
            Spacer()
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyState: some View {
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
        .refreshable { await viewModel.refreshAndWait() }
    }

    private var feedList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(viewModel.notes.enumerated()), id: \.element.id) { index, event in
                    FeedEventNavigationLink(event: event) {
                        PostCardView(
                            event: event,
                            profile: viewModel.profiles[event.pubkey],
                            profiles: viewModel.profiles,
                            engagement: nil,
                            onProfileTap: { pubkey in
                                path.append(ProfileRoute(pubkey: pubkey))
                            },
                            onNoteTap: { eventId in
                                path.append(ThreadRoute(eventId: eventId, authorPubkey: event.pubkey))
                            },
                            onHashtagTap: { tag in
                                path.append(HashtagFeedRoute(tag: tag))
                            }
                        )
                    }
                    .buttonStyle(.plain)
                    .onAppear {
                        engagementRepo.markVisible(event: event)
                        MediaLookaheadPrefetcher.shared.noteAppeared(
                            eventId: event.id,
                            in: viewModel.notes,
                            profiles: viewModel.profiles
                        )
                        viewModel.loadMoreIfNeeded(
                            currentIndex: index,
                            total: viewModel.notes.count
                        )
                    }
                    .onDisappear {
                        engagementRepo.markInvisible(event: event)
                    }
                    Divider().overlay(Color.wispSurfaceVariant.opacity(0.3))
                }
                if viewModel.isPaging {
                    ProgressView()
                        .padding(16)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .refreshable { await viewModel.refreshAndWait() }
    }
}
