import SwiftUI

// Fresh's special cards in the list (`MainView.freshList`, behind
// `FeatureFlags.freshSpecialsEnabled`): "From the recipe box" (one older
// recipe as a full post card) and a topic spotlight (a title and a row of
// a few posts from one topic). Free tier only: no "See more" link (web's
// opens the members' topic feed), no topic screen, no "Show fewer" or
// "Hide this topic" (Seth, 2026-11-11).
//
// ≠ web: spotlight posts carry their own Report and Block menu (web's mini
// posts have none). Report or Block sends `.contentHidden`, and the view
// model drops that post from the card at once.

/// "From the recipe box": a label above the recipe's own post card (which
/// brings the post's usual menu, Report and Block included).
struct FreshRecipeBoxCard<Content: View>: View {
    static var label: String { "From the recipe box" }

    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Label(Self.label, systemImage: "archivebox")
                .font(AppFont.bodySmall.weight(.semibold))
                .foregroundStyle(Color.wispPrimary)
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .accessibilityAddTraits(.isHeader)
            content
        }
        .background(Color.wispPrimary.opacity(0.06))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("fresh-recipe-box-card")
    }
}

/// A topic spotlight: the topic's title and its posts side by side.
struct FreshSpotlightCard: View {
    let topic: FreshSpotlightTopic
    let posts: [NostrEvent]
    let profiles: [String: ProfileData]
    /// The signed-in account: its own posts get no Report / Block.
    let me: String
    var onPostTap: (NostrEvent) -> Void = { _ in }
    var onProfileTap: (String) -> Void = { _ in }

    static let tileWidth: CGFloat = 232

    @Environment(AppSettings.self) private var settings

    /// Tiles share one height: room for a picture when any post shows one.
    private var tileHeight: CGFloat {
        settings.autoLoadMedia && posts.contains { FreshSpotlightTile.firstImage($0) != nil } ? 248 : 168
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(topic.title)
                .font(AppFont.titleMedium)
                .foregroundStyle(Color.wispOnSurface)
                .padding(.horizontal, 16)
                .accessibilityAddTraits(.isHeader)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(posts, id: \.id) { event in
                        FreshSpotlightTile(
                            event: event,
                            profile: profiles[event.pubkey],
                            canModerate: event.pubkey != me,
                            onTap: { onPostTap(event) },
                            onProfileTap: { onProfileTap(event.pubkey) },
                            profiles: profiles
                        )
                        .frame(width: Self.tileWidth, height: tileHeight)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
        .padding(.vertical, 14)
        .background(Color.wispPrimary.opacity(0.06))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("fresh-spotlight-card")
    }
}

/// One spotlight post: author, a few lines, the first picture. Tap opens the
/// thread; the "…" button (and a long press) has Report and Block.
struct FreshSpotlightTile: View {
    let event: NostrEvent
    let profile: ProfileData?
    let canModerate: Bool
    let onTap: () -> Void
    let onProfileTap: () -> Void

    @Environment(AppSettings.self) private var settings

    private var name: String { profile?.displayString ?? Nip19.shortNpub(hex: event.pubkey) }
    private var image: URL? { FreshSpotlightTile.firstImage(event).flatMap(URL.init(string:)) }
    /// Every profile the card knows (the author's and anyone mentioned).
    var profiles: [String: ProfileData] = [:]

    private var text: String { FreshSpotlightTile.plainText(event, profiles: profiles) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button(action: onProfileTap) {
                    HStack(spacing: 8) {
                        CachedAvatarView(url: profile?.picture, size: 28)
                        Text(name)
                            .font(AppFont.bodySmall.weight(.semibold))
                            .foregroundStyle(Color.wispOnSurface)
                            .lineLimit(1)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(name)
                Spacer(minLength: 0)
                if canModerate {
                    Menu { moderationButtons } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Color.wispOnSurfaceVariant)
                            .frame(width: 32, height: 28)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("More")
                    .accessibilityIdentifier("fresh-spotlight-post-menu")
                }
            }
            Button(action: onTap) {
                VStack(alignment: .leading, spacing: 8) {
                    if let image, settings.autoLoadMedia {
                        Color.clear
                            .frame(height: 120)
                            .overlay {
                                RetryingAsyncImage(
                                    url: image,
                                    content: { $0.resizable().scaledToFill() },
                                    loading: { Color.wispSurfaceVariant.opacity(0.4) },
                                    failure: { Color.wispSurfaceVariant.opacity(0.4) }
                                )
                            }
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .accessibilityHidden(true)
                    }
                    Text(text)
                        .font(AppFont.bodyMedium)
                        .foregroundStyle(Color.wispOnSurface)
                        .lineLimit(image != nil && settings.autoLoadMedia ? 3 : 4)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    Spacer(minLength: 0)
                }
                .frame(maxHeight: .infinity, alignment: .top)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(text)
            .accessibilityHint("Opens the post")
            .accessibilityIdentifier("fresh-spotlight-post")
        }
        .padding(12)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.wispSurface, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.wispSurfaceVariant.opacity(0.5), lineWidth: 1))
        .contextMenu {
            if canModerate { moderationButtons }
        }
    }

    @ViewBuilder private var moderationButtons: some View {
        Button(role: .destructive) {
            ReportPresenter.shared.present(.event(event))
        } label: {
            Label("Report", systemImage: "flag")
        }
        .accessibilityIdentifier("report-spotlight-post")
        Button(role: .destructive) {
            MuteRepository.shared.blockUser(event.pubkey, context: .event(id: event.id, kind: event.kind))
        } label: {
            Label("Block User", systemImage: "person.crop.circle.badge.xmark")
        }
        .accessibilityIdentifier("block-spotlight-post")
    }

    nonisolated private static let urlRegex = try! NSRegularExpression(pattern: #"https?://\S+"#)
    nonisolated private static let imageExtensions = [".jpg", ".jpeg", ".png", ".gif", ".webp", ".avif"]

    /// The `image` tag, else the first image URL in the text (the test
    /// `FreshSpecials.hasImage` uses).
    nonisolated static func firstImage(_ event: NostrEvent) -> String? {
        if let tag = event.tags.first(where: { $0.count >= 2 && $0[0] == "image" && !$0[1].isEmpty }) {
            return tag[1]
        }
        let content = event.content
        for match in urlRegex.matches(in: content, range: NSRange(content.startIndex..., in: content)) {
            guard let r = Range(match.range, in: content) else { continue }
            let url = String(content[r])
            if imageExtensions.contains(where: { url.lowercased().contains($0) }) { return url }
        }
        return nil
    }

    /// The tile's text, from the app's own parse (`ContentParser`):
    /// - a profile mention (`nostr:npub…` / `nprofile…`) reads "@name", by
    ///   the same rule as the feed (`RichInlineTextView.mentionName`: the
    ///   display name, else a short npub);
    /// - note, event and address references (`nostr:note…` / `nevent…` /
    ///   `naddr…`), links, media and invoices are dropped (the picture shows
    ///   on its own);
    /// - hashtags keep their "#", custom emoji their ":shortcode:";
    /// - whitespace collapsed.
    static func plainText(_ event: NostrEvent, profiles: [String: ProfileData]) -> String {
        var out = ""
        for segment in ContentParser.parse(content: event.content, tags: event.tags) {
            switch segment {
            case .text(let text):
                out += text
            case .nostrProfile(let pubkey, _):
                let profile = profiles[pubkey] ?? ProfileRepository.shared.get(pubkey)
                out += "@" + RichInlineTextView.mentionName(pubkey: pubkey, profile: profile)
            case .hashtag(let tag):
                out += "#" + tag
            case .customEmoji(let shortcode, _):
                out += ":\(shortcode):"
            case .lightningAddress(let address):
                out += address
            case .nostrNote, .nostrAddressable, .link, .inlineLink, .image, .video, .audio,
                 .unknownMedia, .lightningInvoice, .lnurlPayable:
                out += " "
            }
        }
        return out.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}
