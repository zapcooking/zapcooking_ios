import SwiftUI

/// Tabbed list view for the user's drafts (NIP-37 on write relays) and
/// scheduled posts (held by Zap Cooking's scheduler API until their time).
struct DraftsScheduledView: View {
    let keypair: Keypair

    @State private var viewModel: DraftsViewModel
    @State private var openedDraft: Nip37.Draft?
    @Environment(\.dismiss) private var dismiss

    init(keypair: Keypair) {
        self.keypair = keypair
        _viewModel = State(initialValue: DraftsViewModel(keypair: keypair))
    }

    /// For the DEBUG harness: a view model with its scheduler seam set.
    init(viewModel: DraftsViewModel) {
        self.keypair = viewModel.keypair
        _viewModel = State(initialValue: viewModel)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.wispBackground.ignoresSafeArea()

                VStack(spacing: 0) {
                    Picker("", selection: $viewModel.selectedTab) {
                        Text("Drafts").tag(DraftsViewModel.Tab.drafts)
                        Text("Scheduled").tag(DraftsViewModel.Tab.scheduled)
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 12)

                    Divider().overlay(Color.wispSurfaceVariant.opacity(0.5))

                    switch viewModel.selectedTab {
                    case .drafts:
                        draftsList
                    case .scheduled:
                        scheduledList
                    }
                }
            }
            .navigationTitle("Drafts & Scheduled")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                }
            }
        }
        // Every time the screen appears both lists are fetched again, side by
        // side, so a post scheduled a moment ago is there.
        .task {
            async let drafts: Void = viewModel.loadDrafts()
            async let scheduled: Void = viewModel.loadScheduledPosts()
            _ = await (drafts, scheduled)
        }
        .sheet(item: $openedDraft) { draft in
            ComposeView(keypair: keypair, draft: draft)
                .id(draft.dTag)
                .onDisappear {
                    // The draft may have been posted, or scheduled.
                    Task { await viewModel.loadDrafts() }
                    Task { await viewModel.loadScheduledPosts() }
                }
        }
        .onChange(of: viewModel.selectedTab) { _, tab in
            switch tab {
            case .drafts where viewModel.drafts.isEmpty && !viewModel.isLoadingDrafts:
                Task { await viewModel.loadDrafts() }
            case .scheduled where !viewModel.isLoadingScheduled:
                Task { await viewModel.loadScheduledPosts() }
            default:
                break
            }
        }
    }

    // MARK: - Drafts tab

    @ViewBuilder
    private var draftsList: some View {
        if viewModel.isLoadingDrafts && viewModel.drafts.isEmpty {
            loadingView
        } else if viewModel.drafts.isEmpty {
            emptyState(icon: "doc.text", title: "No drafts", subtitle: "Drafts you save while composing will appear here.")
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(viewModel.drafts, id: \.dTag) { draft in
                        DraftRow(
                            draft: draft,
                            authorPubkey: keypair.pubkey,
                            onOpen: { openedDraft = draft },
                            onDelete: {
                                Task { await viewModel.deleteDraft(dTag: draft.dTag) }
                            }
                        )
                        Divider().overlay(Color.wispSurfaceVariant.opacity(0.3))
                    }
                }
            }
            .refreshable { await viewModel.loadDrafts() }
        }
    }

    // MARK: - Scheduled tab

    /// Always a scroll view, so pull to refresh works on the empty list, on
    /// the error and while loading, not only when there are rows.
    private var scheduledList: some View {
        ScrollView {
            // What a cancel ran into stays on screen even when the refresh
            // that follows leaves the list empty.
            if let notice = viewModel.scheduledNotice {
                scheduledBanner(notice, identifier: "scheduled-notice") { viewModel.scheduledNotice = nil }
            }
            if viewModel.scheduledPosts.isEmpty {
                Group {
                    if viewModel.isLoadingScheduled {
                        loadingView
                    } else if let error = viewModel.scheduledLoadError {
                        emptyState(icon: "exclamationmark.triangle", title: "Couldn't load scheduled posts", subtitle: error)
                            .accessibilityIdentifier("scheduled-load-error")
                    } else {
                        emptyState(icon: "clock", title: "No scheduled posts",
                                   subtitle: "Posts you schedule here or on zap.cooking appear in this list until they go out.")
                            .accessibilityIdentifier("scheduled-empty")
                    }
                }
                .containerRelativeFrame(.vertical)
            } else {
                LazyVStack(spacing: 0) {
                    if let error = viewModel.scheduledLoadError {
                        scheduledBanner(error, identifier: "scheduled-load-error", onDismiss: nil)
                    }
                    ForEach(viewModel.pendingPosts) { post in
                        scheduledRow(post)
                    }
                    if !viewModel.failedPosts.isEmpty {
                        Text("Didn't post")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 14)
                            .padding(.top, 16)
                            .padding(.bottom, 6)
                        ForEach(viewModel.failedPosts) { post in
                            scheduledRow(post)
                        }
                    }
                }
            }
        }
        .refreshable { await viewModel.loadScheduledPosts() }
        .accessibilityIdentifier("scheduled-list")
    }

    @ViewBuilder
    private func scheduledRow(_ post: ScheduledPost) -> some View {
        ScheduledPostRow(
            post: post,
            isCancelling: viewModel.cancellingIds.contains(post.id),
            onCancel: {
                Task { await viewModel.cancelScheduledPost(id: post.id) }
            }
        )
        Divider().overlay(Color.wispSurfaceVariant.opacity(0.3))
    }

    private func scheduledBanner(_ text: String, identifier: String, onDismiss: (() -> Void)?) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.orange)
            Text(text)
                .font(.caption.weight(.medium))
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }

    // MARK: - Shared

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Loading\u{2026}").font(.subheadline).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func emptyState(icon: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
                .foregroundStyle(.secondary)
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Draft row

private struct DraftRow: View {
    let draft: Nip37.Draft
    let authorPubkey: String
    let onOpen: () -> Void
    let onDelete: () -> Void

    @State private var contentExpanded = false

    /// Char-count threshold above which the row clamps the body and
    /// surfaces a "Show more" pill. ~280 chars typically fills 6+ lines
    /// at the row's font size.
    private static let longDraftCharCount = 280

    /// Height the collapsed draft body clips to. `.lineLimit` doesn't
    /// reach `RichInlineTextView` (it's a `UITextView`-backed renderer,
    /// so SwiftUI's line cap is silently ignored), so we cap visible
    /// height instead and rely on `.clipped()` to truncate.
    private static let collapsedBodyHeight: CGFloat = 130

    private var profile: ProfileData? { ProfileRepository.shared.get(authorPubkey) }
    private var isReply: Bool {
        draft.tags.contains { $0.count >= 2 && $0[0] == "e" }
    }
    private var formattedTimestamp: String {
        let date = Date(timeIntervalSince1970: TimeInterval(draft.createdAt))
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, h:mm a"
        return formatter.string(from: date)
    }

    var body: some View {
        let extraction = Self.extractMedia(from: draft.content)
        let isLong = extraction.text.count > Self.longDraftCharCount

        HStack(alignment: .top, spacing: 10) {
            CachedAvatarView(url: profile?.picture, size: 36)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(profile?.displayString ?? Nip19.shortNpub(hex: authorPubkey))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if isReply {
                        Text("REPLY")
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.wispSurfaceVariant, in: Capsule())
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(formattedTimestamp)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                let collapsed = isLong && !contentExpanded
                let bodyCap: CGFloat? = collapsed ? Self.collapsedBodyHeight : nil
                RichContentView(
                    content: extraction.text,
                    tags: draft.tags,
                    profiles: ProfileRepository.shared.getAll(referencedPubkeys(in: draft)),
                    showLinkPreviews: false
                )
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxHeight: bodyCap, alignment: .top)
                .clipped()
                .overlay(alignment: .bottom) {
                    if collapsed {
                        LinearGradient(
                            colors: [Color.wispBackground.opacity(0), Color.wispBackground],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .frame(height: 32)
                        .allowsHitTesting(false)
                    }
                }

                if isLong {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            contentExpanded.toggle()
                        }
                    } label: {
                        Text(contentExpanded ? "Show less" : "Show more")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.wispPrimary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .background(Color.wispSurfaceVariant.opacity(0.6), in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }

                if !extraction.imageUrls.isEmpty {
                    thumbnailRow(extraction.imageUrls)
                }
            }

            Button(action: onDelete) {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(8)
                    .background(Color.wispSurfaceVariant.opacity(0.6), in: Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture { onOpen() }
    }

    /// Up to 4 fixed-size thumbnails for any image URLs in the draft. We
    /// keep the row compact (60×60 tiles) so a draft with multiple images
    /// can't blow up vertically; if there are more than 4, the last tile
    /// shows a `+N` overflow badge.
    @ViewBuilder
    private func thumbnailRow(_ urls: [String]) -> some View {
        let visible = Array(urls.prefix(4))
        let overflow = urls.count - visible.count
        HStack(spacing: 6) {
            ForEach(Array(visible.enumerated()), id: \.offset) { idx, url in
                ZStack(alignment: .bottomTrailing) {
                    RetryingAsyncImage(
                        url: URL(string: url),
                        content: { image in
                            image.resizable()
                                .aspectRatio(contentMode: .fill)
                        },
                        loading: {
                            Color.wispSurfaceVariant.opacity(0.6)
                                .overlay { ProgressView().scaleEffect(0.7) }
                        },
                        failure: {
                            Color.wispSurfaceVariant.opacity(0.6)
                                .overlay {
                                    Image(systemName: "photo")
                                        .foregroundStyle(.secondary)
                                }
                        }
                    )
                    .frame(width: 60, height: 60)
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                    if overflow > 0, idx == visible.count - 1 {
                        Text("+\(overflow)")
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(.ultraThinMaterial, in: Capsule())
                            .padding(4)
                    }
                }
            }
        }
    }

    private func referencedPubkeys(in draft: Nip37.Draft) -> [String] {
        draft.tags.compactMap { tag in
            guard tag.count >= 2, tag[0] == "p" else { return nil }
            return tag[1]
        }
    }

    /// Strip media URLs out of the draft body so `RichContentView`
    /// renders a stable, single-row-height text preview, and separately
    /// collect any image URLs so the row can show small fixed-size
    /// thumbnails for them. Video/audio URLs become `[video]` / `[audio]`
    /// placeholders in the text since we don't have a small inline
    /// presentation for them yet. Mirrors the URL-classification regex
    /// used in `NotificationRowView`.
    static func extractMedia(from content: String) -> (text: String, imageUrls: [String]) {
        let pattern = #"https?://\S+\.(?:jpg|jpeg|png|gif|webp|heic|heif|avif|svg|mp4|mov|webm|m3u8|mp3|wav|ogg|m4a|flac|aac)(?:\?\S*)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return (content, [])
        }
        let ns = content as NSString
        let matches = regex.matches(in: content, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return (content, []) }
        var text = ""
        var imageUrls: [String] = []
        var lastEnd = 0
        for match in matches {
            text += ns.substring(with: NSRange(location: lastEnd, length: match.range.location - lastEnd))
            let url = ns.substring(with: match.range)
            let path = url.lowercased().split(separator: "?").first.map(String.init) ?? url.lowercased()
            let ext = (path as NSString).pathExtension
            switch ext {
            case "mp4", "mov", "webm", "m3u8":
                text += "[video]"
            case "mp3", "wav", "ogg", "m4a", "flac", "aac":
                text += "[audio]"
            default:
                imageUrls.append(url)
            }
            lastEnd = match.range.upperBound
        }
        text += ns.substring(from: lastEnd)
        return (text, imageUrls)
    }
}

// MARK: - Scheduled post row

/// One scheduled post: who, when, its status, and a preview that works for
/// every kind the scheduler takes (text, the first picture, a poll's options).
private struct ScheduledPostRow: View {
    let post: ScheduledPost
    let isCancelling: Bool
    let onCancel: () -> Void

    /// `RichContentView` ignores `.lineLimit` (it is `UITextView`-backed), so
    /// a long post is clipped by height, as the drafts row does.
    private static let bodyHeightCap: CGFloat = 130

    private var event: NostrEvent { post.event }
    private var profile: ProfileData? { ProfileRepository.shared.get(event.pubkey) }
    private var isFailed: Bool { post.status == .failed }
    private var formattedTime: String {
        let date = Date(timeIntervalSince1970: TimeInterval(post.publishAt))
        let formatter = DateFormatter()
        if Calendar.current.isDateInToday(date) {
            formatter.dateFormat = "'Today,' h:mm a"
        } else if Calendar.current.component(.year, from: date) == Calendar.current.component(.year, from: Date()) {
            formatter.dateFormat = "MMM d, h:mm a"
        } else {
            formatter.dateFormat = "MMM d, yyyy, h:mm a"
        }
        return formatter.string(from: date)
    }

    var body: some View {
        let preview = ScheduledPostPreview(event: event)

        HStack(alignment: .top, spacing: 10) {
            CachedAvatarView(url: profile?.picture, size: 36)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(profile?.displayString ?? Nip19.shortNpub(hex: event.pubkey))
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if let kind = preview.kindLabel {
                        Text(kind.uppercased())
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.wispSurfaceVariant, in: Capsule())
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                statusLine

                if !preview.text.isEmpty {
                    // Without the imeta tags: the row draws its own small
                    // thumbnail, and a picture or video post's tags would
                    // otherwise put full-width media in the middle of a list.
                    RichContentView(
                        content: preview.text,
                        tags: event.tags.filter { $0.first != "imeta" },
                        profiles: ProfileRepository.shared.getAll(referencedPubkeys),
                        showLinkPreviews: false
                    )
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxHeight: Self.bodyHeightCap, alignment: .top)
                    .clipped()
                }

                if !preview.pollOptions.isEmpty {
                    pollOptions(preview.pollOptions)
                }

                if preview.imageUrl != nil || preview.hasVideo {
                    mediaRow(preview)
                }

                if isFailed {
                    failureNote
                }
            }

            if post.status == .pending {
                Button(action: onCancel) {
                    Group {
                        if isCancelling {
                            ProgressView().scaleEffect(0.7)
                        } else {
                            Image(systemName: "xmark")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 16, height: 16)
                    .padding(8)
                    .background(Color.wispSurfaceVariant.opacity(0.6), in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(isCancelling)
                .accessibilityLabel(isCancelling ? "Cancelling" : "Cancel scheduled post")
                .accessibilityIdentifier("scheduled-cancel")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("scheduled-row")
    }

    /// The status word and the publish time. Green while it is on its way,
    /// red once it has failed.
    private var statusLine: some View {
        let tint: Color = isFailed ? .red : .green
        return HStack(spacing: 4) {
            Image(systemName: isFailed ? "exclamationmark.triangle.fill" : "clock")
                .font(.system(size: 10, weight: .semibold))
            Text(ScheduledList.statusLabel(for: post, now: NostrClock.now()) + " \u{00B7} " + formattedTime)
                .font(.caption.weight(.medium))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(tint.opacity(0.15), in: Capsule())
        .foregroundStyle(tint)
    }

    private func pollOptions(_ options: [String]) -> some View {
        let visible = Array(options.prefix(4))
        return VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(visible.enumerated()), id: \.offset) { _, option in
                HStack(spacing: 6) {
                    Image(systemName: "circle")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Text(option)
                        .font(.subheadline)
                        .lineLimit(1)
                }
            }
            if options.count > visible.count {
                Text("+\(options.count - visible.count) more")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func mediaRow(_ preview: ScheduledPostPreview) -> some View {
        HStack(spacing: 8) {
            if let url = preview.imageUrl {
                RetryingAsyncImage(
                    url: URL(string: url),
                    content: { image in
                        image.resizable().aspectRatio(contentMode: .fill)
                    },
                    loading: {
                        Color.wispSurfaceVariant.opacity(0.6)
                            .overlay { ProgressView().scaleEffect(0.7) }
                    },
                    failure: {
                        Color.wispSurfaceVariant.opacity(0.6)
                            .overlay { Image(systemName: "photo").foregroundStyle(.secondary) }
                    }
                )
                .frame(width: 60, height: 60)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.wispSurfaceVariant.opacity(0.6))
                    .frame(width: 60, height: 60)
                    .overlay { Image(systemName: "video.fill").foregroundStyle(.secondary) }
            }
            let rest = preview.imageUrl == nil ? preview.moreMediaCount - 1 : preview.moreMediaCount
            if rest > 0 {
                Text("+\(rest) more")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// Plain words first; the server's own text under them, as detail.
    private var failureNote: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(ScheduledList.failedExplanation)
                .font(.caption)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            if let detail = post.lastError, !detail.isEmpty {
                Text("Detail: \(detail)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("scheduled-failure")
    }

    private var referencedPubkeys: [String] {
        event.tags.compactMap { tag in
            guard tag.count >= 2, tag[0] == "p" else { return nil }
            return tag[1]
        }
    }
}
