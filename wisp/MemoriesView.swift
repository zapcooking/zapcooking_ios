import SwiftUI

/// Where a tap inside the Memories sheet wants to go. The sheet cannot push
/// onto the feed's `NavigationPath` itself, so `MainView` dismisses the sheet
/// and appends the matching typed route (same hand-off as `PollsView`).
enum MemoriesRoute: Equatable {
    case thread(eventId: String, authorPubkey: String)
    case profile(pubkey: String)
    case hashtag(String)
}

/// Memories — "On this day". Shows the signed-in user's own kind-1 notes from
/// this calendar day 1/2/3 years ago, grouped by years-ago. Port of Android
/// `MemoriesScreen`; each note renders through the shared `PostCardView`.
/// Read-only. Presented as a sheet from the drawer, like `PollsView`.
struct MemoriesView: View {
    let pubkey: String
    let onRoute: (MemoriesRoute) -> Void

    @State private var viewModel: MemoriesViewModel
    @State private var profiles: [String: ProfileData] = [:]
    @Environment(\.dismiss) private var dismiss

    init(pubkey: String, onRoute: @escaping (MemoriesRoute) -> Void, repo: MemoriesRepository? = nil) {
        self.pubkey = pubkey
        self.onRoute = onRoute
        _viewModel = State(initialValue: MemoriesViewModel(pubkey: pubkey, repo: repo ?? .shared))
    }

    static func yearLabel(_ yearsAgo: Int) -> String {
        yearsAgo == 1 ? "1 year ago" : "\(yearsAgo) years ago"
    }

    private static let groupDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMMMdyyyy")
        return f
    }()

    private static let todayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("EEEEMMMMdyyyy")
        return f
    }()

    var body: some View {
        NavigationStack {
            ZStack {
                Color.wispBackground.ignoresSafeArea()
                content
            }
            .navigationTitle("Memories")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await viewModel.refresh() }
                    } label: {
                        if viewModel.refreshing {
                            ProgressView()
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .disabled(viewModel.refreshing)
                    .accessibilityLabel("Refresh memories")
                }
            }
        }
        .task {
            await viewModel.load()
            profiles = await ProfileRepository.shared.ensure([pubkey])
        }
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.loading && viewModel.groups.isEmpty {
            VStack {
                Text("Looking back through your notes…")
                    .font(AppFont.bodyMedium)
                    .foregroundStyle(Color.wispOnSurfaceVariant)
                    .padding(.top, 48)
                Spacer()
            }
            .padding(24)
        } else if viewModel.allEmpty {
            emptyState
        } else {
            list
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Text("🍳").font(.system(size: 40))
            Text("No memories found for this day. Relays may not keep notes this old — or this day is still waiting for its first one.")
                .font(AppFont.bodyMedium)
                .foregroundStyle(Color.wispOnSurfaceVariant)
                .multilineTextAlignment(.center)
            Spacer()
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("A look back at notes from this day")
                        .font(AppFont.bodyMedium)
                        .foregroundStyle(Color.wispOnSurfaceVariant)
                    Text(Self.todayFormatter.string(from: Date()))
                        .font(AppFont.bodySmall)
                        .foregroundStyle(Color.wispOnSurfaceVariant)
                }
                .padding(16)

                if let notice = viewModel.refreshNotice {
                    Text(notice)
                        .font(AppFont.bodySmall)
                        .foregroundStyle(Color.wispOnSurfaceVariant)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.wispSurfaceVariant.opacity(0.5))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 4)
                        .accessibilityIdentifier("memories-refresh-notice")
                }

                ForEach(viewModel.groups, id: \.yearsAgo) { group in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Self.yearLabel(group.yearsAgo))
                            .font(AppFont.bodyLarge.weight(.semibold))
                            .foregroundStyle(Color.wispOnSurface)
                        Text(Self.groupDateFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(group.dateSec))))
                            .font(AppFont.bodySmall)
                            .foregroundStyle(Color.wispOnSurfaceVariant)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                    .padding(.bottom, 4)

                    if group.events.isEmpty {
                        Text("Nothing from \(Self.yearLabel(group.yearsAgo)) — relays may not keep notes this old.")
                            .font(AppFont.bodySmall)
                            .foregroundStyle(Color.wispOnSurfaceVariant)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                    } else {
                        ForEach(group.events, id: \.id) { event in
                            PostCardView(
                                event: event,
                                profile: profiles[event.pubkey],
                                profiles: profiles,
                                engagement: nil,
                                useAbsoluteTimestamp: true,
                                onProfileTap: { onRoute(.profile(pubkey: $0)) },
                                onNoteTap: { onRoute(.thread(eventId: $0, authorPubkey: event.pubkey)) },
                                onHashtagTap: { onRoute(.hashtag($0)) }
                            )
                            .contentShape(Rectangle())
                            .onTapGesture {
                                onRoute(.thread(eventId: event.id, authorPubkey: event.pubkey))
                            }
                            Divider().overlay(Color.wispSurfaceVariant.opacity(0.3))
                        }
                    }
                }
            }
            .padding(.bottom, 24)
        }
    }
}
