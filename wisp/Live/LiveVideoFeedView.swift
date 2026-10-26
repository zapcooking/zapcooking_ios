import SwiftUI

/// The Live Video feed: every NIP-53 stream discovery currently reports as
/// live, Sidecar-style — the fork's replacement for Wisp's top-of-feed live
/// strip, which spent most of its life empty. Rows tap through to the stream
/// view; discovery itself is fed by `FeedViewModel`/`LiveStreamCoordinator`
/// and re-kicked on appear, so entering the kind refreshes.
struct LiveVideoFeedView: View {
    /// Presents the stream view. Re-kicks discovery, honoring the "Show live
    /// streams" switch.
    let onSelect: (LiveStream) -> Void
    let onRefresh: () -> Void

    @State private var repo = LiveStreamRepository.shared
    @Environment(AppSettings.self) private var settings

    var body: some View {
        Group {
            if !settings.showsLiveContent {
                state(
                    icon: "video.slash",
                    title: "Live video is off",
                    detail: "Turn it back on in Settings → Interface → Show live streams."
                )
            } else if repo.liveNowSorted.isEmpty {
                state(
                    icon: "dot.radiowaves.left.and.right",
                    title: "No one is streaming right now",
                    detail: "Live streams on your relays appear here the moment they start."
                )
            } else {
                list
            }
        }
        .onAppear { onRefresh() }
        .refreshable { onRefresh(); try? await Task.sleep(for: .seconds(1.2)) }
        .background(Color.wispBackground.ignoresSafeArea())
        .accessibilityIdentifier("live-video-feed")
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(repo.liveNowSorted) { stream in
                    row(stream)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
    }

    private func row(_ stream: LiveStream) -> some View {
        let key = stream.activity.streamerPubkey ?? stream.activity.hostPubkey
        let profile = repo.hostProfiles[key]
        return Button {
            onSelect(stream)
        } label: {
            HStack(spacing: 12) {
                CachedAvatarView(url: profile?.picture, size: 52)
                    .overlay(alignment: .bottomTrailing) {
                        Text("LIVE")
                            .font(.system(size: 9, weight: .heavy))
                            .kerning(0.5)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color(red: 0.898, green: 0.224, blue: 0.208), in: RoundedRectangle(cornerRadius: 4))
                            .offset(x: 4, y: 4)
                    }
                VStack(alignment: .leading, spacing: 3) {
                    Text(stream.activity.title ?? profile?.displayName ?? "Live Stream")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.wispOnSurface)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(profile?.displayName ?? String(key.prefix(12)))
                        .font(.caption)
                        .foregroundStyle(Color.wispOnSurfaceVariant)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 4) {
                    Label("\(stream.chatters.count)", systemImage: "bubble.right")
                        .font(.caption2)
                        .foregroundStyle(Color.wispOnSurfaceVariant)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.wispOnSurfaceVariant.opacity(0.6))
                }
            }
            .padding(12)
            .background(Color.wispSurface, in: RoundedRectangle(cornerRadius: 14))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("live-video-row")
    }

    private func state(icon: String, title: String, detail: String) -> some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: icon)
                .font(.system(size: 40))
                .foregroundStyle(Color.wispOnSurfaceVariant.opacity(0.6))
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.wispOnSurface)
            Text(detail)
                .font(.system(size: 13))
                .foregroundStyle(Color.wispOnSurfaceVariant)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Navigation route for opening a `LiveStreamView` from the Live Video feed.
struct LiveStreamRoute: Hashable {
    let aTagValue: String
    let hostPubkey: String
    let dTag: String
    let relayHints: [String]
}
