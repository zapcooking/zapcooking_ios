import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import Observation
import AVFoundation

/// Cross-surface channel for the autosaved draft. `ComposeView` writes the
/// draft here from its autosave-on-dismiss path; `MainView` watches it and
/// raises the shared `SuccessToast` ("Draft saved", tap to reopen). Lives
/// outside the View so reply / quote composers presented from `PostCardView`
/// or `NotificationComposer` light up the same pill without each entry point
/// threading a callback up to the tab root.
@MainActor
@Observable
final class DraftSavedToastStore {
    static let shared = DraftSavedToastStore()
    var pendingDraft: Nip37.Draft? = nil
    private init() {}
}


struct ComposeView: View {
    @State var viewModel: ComposeViewModel
    @Environment(\.dismiss) private var dismiss

    @FocusState private var contentFocused: Bool
    @State private var showScheduleSheet = false
    @State private var showCancelConfirm = false
    @State private var showGifPicker = false
    @State private var showDraftsSheet = false
    @State private var photosPickerMaxCount: Int = 8
    @State private var showAccountPicker = false
    @State private var showFoodTagConfirm = false
    @State private var showTagPicker = false
    /// Live drag reorder, ported from #268's `AttachmentThumbStrip`: at
    /// lift, each slot's layout x is snapshotted; the dragged cell is
    /// offset by the finger's translation (it follows the hand, 1.06
    /// scaled, z-lifted) and crossing the midpoint between cell centers
    /// splices the slot there, rebasing the offset so the lifted cell
    /// never jumps. Positions are never re-read mid-drag.
    private struct ReorderState {
        var snapshot: [Int: CGFloat]
        var index: Int
        var offsetX: CGFloat
    }
    @State private var reorder: ReorderState?
    @State private var cellX: [Int: CGFloat] = [:]
    /// Liveness flag driven by the gesture itself. `@GestureState` resets
    /// to its initial value when the gesture ends *or is cancelled* —
    /// plain `.onEnded` never fires on cancellation (a splice can
    /// invalidate the gesture mid-drag), which left lifted cells stuck.
    @GestureState private var reorderGestureLive = false
    /// Attachment whose alt editor (#137's `AltTextEditorView`) is open.
    /// Targets by id, so a reorder while it's open can't redirect the text.
    @State private var altEditorTarget: AltTextEditorTarget?

    /// Draft to load on first appear. Nil for `.new` and `.reply`/`.quote` composers.
    /// Loaded from `.task` rather than `init` to defeat SwiftUI's State preservation
    /// (which ignores `State(initialValue:)` when state already exists for this view identity).
    private let initialDraft: Nip37.Draft?

    /// Media handed off from the Share Extension (see `PendingShareStore` /
    /// `wispApp.onOpenURL`), loaded the same way as a `PhotosPicker`
    /// selection once the view appears.
    private let pendingAttachmentProviders: [NSItemProvider]

    private let previewAnchorID = "composer-preview-card"

    init(keypair: Keypair, mode: ComposeMode = .new) {
        self.initialDraft = nil
        self.pendingAttachmentProviders = []
        _viewModel = State(initialValue: ComposeViewModel(keypair: keypair, mode: mode))
    }

    init(keypair: Keypair, draft: Nip37.Draft) {
        self.initialDraft = draft
        self.pendingAttachmentProviders = []
        _viewModel = State(initialValue: ComposeViewModel(keypair: keypair, mode: .new))
    }

    init(keypair: Keypair, initialText: String, suggestedHashtags: [String] = []) {
        self.initialDraft = nil
        self.pendingAttachmentProviders = []
        _viewModel = State(initialValue: ComposeViewModel(
            keypair: keypair, initialText: initialText, suggestedHashtags: suggestedHashtags
        ))
    }

    init(keypair: Keypair, pendingAttachmentProviders: [NSItemProvider]) {
        self.initialDraft = nil
        self.pendingAttachmentProviders = pendingAttachmentProviders
        _viewModel = State(initialValue: ComposeViewModel(keypair: keypair, mode: .new))
    }

    /// Test seam for the render tests: compose around an existing view
    /// model so a snapshot can carry real attachment bytes (the autosave
    /// format doesn't persist localBytes).
    init(keypair: Keypair, viewModel: ComposeViewModel) {
        self.initialDraft = nil
        self.pendingAttachmentProviders = []
        _viewModel = State(initialValue: viewModel)
    }

    var body: some View {
        autosaveHost
    }

    /// The `NavigationStack` + toolbar shell, split out of `body` — the
    /// single expression had grown past what the type-checker resolves in
    /// reasonable time.
    private var navigationRoot: some View {
        NavigationStack {
            ZStack {
                Color.wispBackground.ignoresSafeArea()

                VStack(spacing: 0) {
                    contextHeader

                    ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            editorSection
                            belowEditorSection

                            Color.clear.frame(height: 80)
                        }
                        .padding(.top, 12)
                    }
                    .onChange(of: viewModel.countdownSeconds) { oldValue, newValue in
                        // When the undo countdown starts, bring the post
                        // preview into view (top-aligned) so the user can
                        // spot-check what's about to publish before the
                        // window closes.
                        guard oldValue == nil, newValue != nil, shouldShowPreview else { return }
                        withAnimation(.easeInOut(duration: 0.3)) {
                            proxy.scrollTo(previewAnchorID, anchor: .top)
                        }
                    }
                    }

                    if viewModel.scheduleEnabled {
                        scheduleBanner
                    }

                    Divider().overlay(Color.wispSurfaceVariant.opacity(0.5))

                    bottomBar
                }
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        cancelTapped()
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.body.weight(.semibold))
                    }
                    .accessibilityLabel("Close")
                    .disabled(isPublishInFlight)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        contentFocused = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                            showDraftsSheet = true
                        }
                    } label: {
                        Image(systemName: "tray.full")
                    }
                    .accessibilityLabel("Drafts")
                    .disabled(isPublishInFlight)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if viewModel.mode.allowsGalleryToggle {
                        // No principal title — the pill itself identifies
                        // the current post type ("Switch to Gallery" means
                        // we're in Text, vice versa), and reply / quote
                        // modes use `contextHeader` to show the parent
                        // event. Dropping the title freed enough trailing
                        // space to fit the full label.
                        Button {
                            viewModel.toggleGallery()
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: viewModel.galleryMode ? "doc.plaintext" : "photo.on.rectangle")
                                    .font(.system(size: 13, weight: .semibold))
                                    .symbolEffectsRemoved()
                                    .transaction { $0.animation = nil }
                                Text(viewModel.galleryMode ? "Switch to Text" : "Switch to Gallery")
                                    .font(.subheadline.weight(.semibold))
                                    .transaction { $0.animation = nil }
                            }
                            .foregroundStyle(Color.wispPrimary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                Capsule()
                                    .strokeBorder(Color.wispPrimary.opacity(0.5), lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(isPublishInFlight)
                        .opacity(isPublishInFlight ? 0.4 : 1)
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    /// The composer's `.task` → `.onDisappear` modifier chain, split into
    /// concrete stages (`lifecycleHost` → `sheetHost` → `autosaveHost`)
    /// rather than one chain on `body` — that single expression had grown
    /// past what the type-checker resolves in reasonable time.
    private var lifecycleHost: some View {
        navigationRoot
        .task {
            if let draft = initialDraft, viewModel.currentDraftId != draft.dTag {
                viewModel.loadDraft(draft)
            }
            await viewModel.start()
            contentFocused = true
            // Drafts / reply prefills land before the view observes
            // `content`, so warm their links once on open too.
            viewModel.prefetchSocialPreviews()
            if !pendingAttachmentProviders.isEmpty {
                await viewModel.addMediaProviders(pendingAttachmentProviders)
            }
        }
        .interactiveDismissDisabled(
            viewModel.isPublishing
            || viewModel.countdownSeconds != nil
            // Block swipe-dismiss while an upload is in flight so the draft
            // autosave on disappear catches the finished URLs.
            || viewModel.uploadProgress != nil
        )
    }

    private var sheetHost: some View {
        lifecycleHost
        .sheet(isPresented: $showScheduleSheet) {
            ScheduleSheet(
                initialDate: viewModel.scheduleAt,
                onConfirm: { date in viewModel.setSchedule(date) },
                onCancel: { /* keep existing schedule */ }
            )
        }
        .sheet(isPresented: $showDraftsSheet) {
            DraftsScheduledView(keypair: viewModel.keypair)
        }
        .sheet(isPresented: $showTagPicker, onDismiss: { contentFocused = true }) {
            FoodTagPickerView(viewModel: viewModel)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showAccountPicker) {
            accountPickerSheet
        }
        .sheet(item: $altEditorTarget) { target in
            AltTextEditorView(
                target: target,
                keypair: viewModel.signingKeypair
            ) { savedText in
                viewModel.setAltText(savedText ?? "", for: target.attachmentID)
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        // GIF picker is presented as a true UIKit modal via a hidden
        // representable rather than a SwiftUI .sheet / .fullScreenCover.
        // Embedding `GiphyViewController` as a child view (which is what
        // SwiftUI's modal hosts do) breaks its internal layout — the
        // bottom search bar collides with the trending-suggestions
        // carousel because Giphy assumes it owns its modal context.
        .background(
            GifPickerPresenter(isPresented: $showGifPicker) { gifUrl in
                appendGifUrl(gifUrl)
            }
        )
    }

    private var autosaveHost: some View {
        sheetHost
        .onChange(of: viewModel.draftSaved) { _, saved in
            if saved { dismiss() }
        }
        .onChange(of: viewModel.content) { _, _ in
            viewModel.scheduleLocalAutosave()
            viewModel.prefetchSocialPreviews()
        }
        .onChange(of: viewModel.attachments.map { $0.url ?? "" }) { _, _ in
            viewModel.scheduleLocalAutosave()
        }
        .onChange(of: viewModel.explicit) { _, _ in
            viewModel.scheduleLocalAutosave()
        }
        .onChange(of: viewModel.powEnabled) { _, _ in
            viewModel.scheduleLocalAutosave()
        }
        .onChange(of: viewModel.scheduleAt) { _, _ in
            viewModel.scheduleLocalAutosave()
        }
        .onDisappear {
            // The local autosave is debounced off the keystroke, so the last
            // few characters may not be persisted yet. Flush them now — unless
            // an explicit discard / publish already cleared the bucket.
            if viewModel.explicitlyDiscarded {
                viewModel.clearLocalAutosave()
            } else if viewModel.publishedEventId != nil {
                // Every publish path clears the bucket itself. Don't clear it
                // again here: a handed-off post whose relays all rejected it may
                // already have restored the draft into that key by now. Just
                // drop the pending debounce so it can't resurrect the bucket.
                viewModel.cancelPendingAutosave()
            } else {
                viewModel.flushLocalAutosave()
            }
            // Auto-save on dismiss when the user navigated away without publishing
            // or explicitly discarding (e.g. swipe-to-dismiss the sheet). Fires
            // for reply / quote / new alike — `saveDraft` builds the appropriate
            // reply context tags via `buildBaseTags`, so re-opening the draft
            // restores the parent thread.
            guard viewModel.hasUnsavedContent,
                  viewModel.publishedEventId == nil,
                  !viewModel.explicitlyDiscarded,
                  !viewModel.draftSaved else { return }
            let vm = viewModel
            Task {
                if let draft = await vm.saveDraft() {
                    await MainActor.run {
                        withAnimation(.spring(response: 0.55, dampingFraction: 0.82)) {
                            DraftSavedToastStore.shared.pendingDraft = draft
                        }
                    }
                }
            }
        }
    }

    // MARK: - Sub-areas

    /// Gallery strip (if any), the editor with its account header, the
    /// quote context, the OnlyFood pills and the actions row. Split out of
    /// the old single scroll `VStack` — that expression had grown past
    /// what the type-checker resolves in reasonable time.
    @ViewBuilder
    private var editorSection: some View {
        if viewModel.galleryMode {
            galleryArea
        }

        // Avatar + "posting as" label rendered as a slim
        // header row above the editor so the editor
        // itself can take the full content width.
        // Hidden entirely for single-account users —
        // nothing to switch to, so the row would just
        // be visual noise. Tapping the row (when
        // multi-account) opens a sheet picker —
        // SwiftUI `Menu` items can't render arbitrary
        // images, so a custom picker is the only way
        // to show real avatars next to names.
        if viewModel.availableSigningAccounts.count > 1 {
            VStack(alignment: .leading, spacing: 2) {
                signingAccountHeader
                    .padding(.horizontal, 12)
                textEditor
            }
        } else {
            textEditor
        }

        quoteContextHeader

        if !viewModel.suggestedHashtags.isEmpty {
            HashtagSuggestionRow(viewModel: viewModel) {
                // Same hop as the GIF picker: let the
                // keyboard collapse before the sheet
                // presents, or the presentation races it.
                contentFocused = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    showTagPicker = true
                }
            }
        }

        // Android order (ComposeScreen): paste-attach offers, then the
        // attachment strip + drawer, all between the editor and the
        // actions row.
        if !viewModel.galleryMode {
            ForEach(Array(viewModel.attachOffers.enumerated()), id: \.offset) { _, url in
                attachOfferRow(url)
            }

            if !viewModel.attachments.isEmpty {
                attachmentsRow
                // Attachments that no longer appear in the
                // editor text need somewhere to be accounted
                // for. Read-only — reordering belongs to the
                // thumbnails, not to a second view of the
                // same array.
                AttachmentSummaryDrawer(media: viewModel.attachments)
            }
        }

        actionsRow
    }

    /// Everything under the actions row: poll editor, hashtag chips, NSFW
    /// banner, suggestion popups, the live preview card and the error line.
    /// (The paste-attach offers and the attachment strip live ABOVE the
    /// actions row, matching Android's composer order.)
    @ViewBuilder
    private var belowEditorSection: some View {
        if viewModel.pollEnabled {
            PollOptionsEditor(viewModel: viewModel)
                .padding(.horizontal, 12)
                .transition(.opacity.combined(with: .move(edge: .top)))
        }

        if !viewModel.hashtags.isEmpty {
            HashtagChipsView(hashtags: viewModel.hashtags)
        }

        if viewModel.explicit {
            nsfwBanner
        }

        if !viewModel.mentionCandidates.isEmpty || viewModel.isMentionSearchingRemote {
            mentionPopup
        }

        if !viewModel.emojiCandidates.isEmpty {
            emojiPopup
        }

        if shouldShowPreview {
            ComposerPreviewCard(
                content: viewModel.previewContent,
                tags: previewTags,
                pollOptions: viewModel.pollEnabled
                    ? viewModel.pollOptions.filter { !$0.isEmpty }
                    : nil,
                userProfile: ProfileRepository.shared.get(viewModel.signingKeypair.pubkey)
            )
            .id(previewAnchorID)
        }

        if let error = viewModel.lastError {
            Text(error)
                .font(.caption)
                .foregroundStyle(.red)
                .padding(.horizontal, 12)
        }
    }

    private var isPublishInFlight: Bool {
        viewModel.isPublishing
            || viewModel.countdownSeconds != nil
            || viewModel.uploadProgress != nil
    }

    /// Discard-confirmation pivot used by both the leading chevron and any
    /// programmatic dismiss. Confirms before dropping unsaved content.
    /// Open the system photo picker via the imperative service rather
    /// than a SwiftUI `.background(PhotosPickerPresenter)` host. The
    /// service walks to the topmost presented VC and presents the
    /// picker directly, bypassing the unreliable representable/host
    /// plumbing that was tearing down the picker after ~1s on
    /// iPhone 13 Pro Max.
    private func presentPhotoPicker(max: Int) {
        contentFocused = false
        PhotoPickerService.present(maxCount: max) { providers in
            // Synchronous progress flip so the dismiss-disabled guard
            // catches before the addMedia task hops onto a runloop.
            viewModel.uploadProgress = providers.count > 1
                ? "Loading \(providers.count) items…"
                : "Loading…"
            Task { await viewModel.addMediaProviders(providers) }
        }
    }

    private func cancelTapped() {
        if viewModel.hasUnsavedContent {
            showCancelConfirm = true
        } else {
            viewModel.cancelPublish()
            viewModel.explicitlyDiscarded = true
            dismiss()
        }
    }

    @ViewBuilder
    private var contextHeader: some View {
        switch viewModel.mode {
        case .reply(let parent, _):
            replyContextRow(parent: parent)
                .padding(.horizontal, 12)
                .padding(.top, 8)
        case .quote, .new:
            EmptyView()
        }
    }

    @ViewBuilder
    private var quoteContextHeader: some View {
        if case .quote(let q) = viewModel.mode {
            quoteContextRow(quoted: q)
                .padding(.horizontal, 12)
        }
    }

    private func replyContextRow(parent: NostrEvent) -> some View {
        let profile = ProfileRepository.shared.get(parent.pubkey)
        let recipientName = profile?.displayString ?? Nip19.shortNpub(hex: parent.pubkey)
        return HStack(alignment: .top, spacing: 8) {
            CachedAvatarView(url: profile?.picture, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    if viewModel.isPrivate {
                        Image(systemName: "lock.fill")
                            .font(.caption2)
                            .foregroundStyle(Color.wispPrimary)
                    }
                    Text(viewModel.isPrivate
                         ? "Replying privately to \(recipientName)"
                         : "Replying to \(recipientName)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Text(previewContent(parent.content, max: 140))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.wispSurfaceVariant.opacity(0.4),
                    in: RoundedRectangle(cornerRadius: 10))
    }

    private func quoteContextRow(quoted: NostrEvent) -> some View {
        let profile = ProfileRepository.shared.get(quoted.pubkey)
        return HStack(alignment: .top, spacing: 8) {
            CachedAvatarView(url: profile?.picture, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text("Quoting \(profile?.displayString ?? Nip19.shortNpub(hex: quoted.pubkey))")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(previewContent(quoted.content, max: 200))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.wispSurfaceVariant.opacity(0.4),
                    in: RoundedRectangle(cornerRadius: 10))
    }

    /// Render-friendly preview of an event's `.content`. When the content is
    /// itself a serialized Nostr event (some clients embed events inside the
    /// `content` string of a kind-1), surface the inner `content` field
    /// instead of dumping the raw JSON envelope into the reply / quote
    /// context card. Mentions are resolved before truncation so a long
    /// `nostr:nprofile1…` token that straddles the cutoff still collapses
    /// to its `@displayName` instead of leaking a half bech32 string.
    private func previewContent(_ raw: String, max: Int) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let source: String
        if trimmed.hasPrefix("{"),
           let data = trimmed.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           obj["id"] is String, obj["pubkey"] is String {
            let inner = (obj["content"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if inner.isEmpty { return "[shared event]" }
            source = inner
        } else {
            source = raw
        }
        let collapsed = collapseMediaUrls(source)
        let resolved = Self.resolveNostrMentions(collapsed)
        return String(resolved.prefix(max))
    }

    private static let previewImageExts: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "avif", "svg"]
    private static let previewVideoExts: Set<String> = ["mp4", "mov", "webm", "m3u8"]

    private func collapseMediaUrls(_ content: String) -> String {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return content }
        let ns = content as NSString
        let matches = detector.matches(in: content, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return content }
        var out = ""
        var lastEnd = 0
        for match in matches {
            out += ns.substring(with: NSRange(location: lastEnd, length: match.range.location - lastEnd))
            let urlStr = ns.substring(with: match.range)
            let ext = (urlStr as NSString).pathExtension.lowercased()
            if Self.previewImageExts.contains(ext) { out += "[image]" }
            else if Self.previewVideoExts.contains(ext) { out += "[video]" }
            else { out += urlStr }
            lastEnd = match.range.upperBound
        }
        out += ns.substring(from: lastEnd)
        return out
    }

    /// Internal (not private) so `ComposeMentionTests` can exercise the URL
    /// guard directly — rendering the preview needs a full editor instance.
    static func resolveNostrMentions(_ content: String) -> String {
        // The bare-npub alternative carries the same `.[a-zA-Z]` exclusion as
        // ContentParser's npub pattern: an npub followed by a dot + letters is
        // a subdomain (e.g. a Blossom server `npub1….blossom.band`), never a
        // mention. NSDataDetector can't back us up here — it doesn't detect
        // scheme-less domains as links, so the URL guard below is blind to
        // exactly the bare-URL shapes that need it.
        let pattern = #"nostr:(?:npub1|nprofile1)[a-z0-9]+|(?<!\w)(?:npub1|nprofile1)[a-z0-9]{50,}(?!\w|\.[a-zA-Z])"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return content }
        let ns = content as NSString
        let fullRange = NSRange(location: 0, length: ns.length)
        let matches = regex.matches(in: content, range: fullRange)
        guard !matches.isEmpty else { return content }
        var urlRanges: [NSRange] = []
        if let linkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            urlRanges = linkDetector.matches(in: content, range: fullRange).map(\.range)
        }
        var out = ""
        var lastEnd = 0
        for match in matches {
            out += ns.substring(with: NSRange(location: lastEnd, length: match.range.location - lastEnd))
            let token = ns.substring(with: match.range)
            let insideURL = urlRanges.contains { NSIntersectionRange($0, match.range).length > 0 }
            if insideURL {
                out += token
            } else {
                let uri = token.lowercased().hasPrefix("nostr:") ? token : "nostr:\(token)"
                if case .profileRef(let pk, _)? = Nip19.decodeNostrUri(uri) {
                    let name = ProfileRepository.shared.get(pk)?.displayString ?? Nip19.shortNpub(hex: pk)
                    out += "@\(name)"
                } else {
                    out += token
                }
            }
            lastEnd = match.range.upperBound
        }
        out += ns.substring(from: lastEnd)
        return out
    }

    // MARK: - Signing account header

    /// Slim "posting as" header row rendered above the text editor. The
    /// avatar + display-name combo identifies the active signing
    /// keypair; tapping (when multiple accounts are signable) opens
    /// `accountPickerSheet`. Single-account users see a non-tappable
    /// row, still useful as a visual reinforcement of "this is your
    /// post". The `.id(pubkey)` on the avatar guards against a
    /// SwiftUI quirk where a reused `CachedAvatarView` keeps the
    /// previous account's image when the URL changes — forces a
    /// fresh view instance on switch as a belt-and-braces on top of
    /// the in-view URL-change reset.
    @ViewBuilder
    private var signingAccountHeader: some View {
        let pubkey = viewModel.signingKeypair.pubkey
        let profile = ProfileRepository.shared.get(pubkey)
        let multiAccount = viewModel.availableSigningAccounts.count > 1
        let name = profile?.displayString ?? Nip19.shortNpub(hex: pubkey)

        Button {
            guard multiAccount else { return }
            showAccountPicker = true
        } label: {
            HStack(spacing: 8) {
                CachedAvatarView(url: profile?.picture, size: 28)
                    .id(pubkey)
                Text(name)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.wispOnSurface)
                    .lineLimit(1)
                if multiAccount {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!multiAccount)
    }

    /// Bottom-sheet picker for the signing account. Replaces a SwiftUI
    /// `Menu` because Menu items can only show SF Symbols — not real
    /// avatar images — and the picker is significantly more legible
    /// with profile pictures next to names.
    private var accountPickerSheet: some View {
        NavigationStack {
            ZStack {
                Color.wispBackground.ignoresSafeArea()
                List {
                    ForEach(viewModel.availableSigningAccounts, id: \.pubkey) { keypair in
                        let kProfile = ProfileRepository.shared.get(keypair.pubkey)
                        let active = keypair.pubkey == viewModel.signingKeypair.pubkey
                        let kName = kProfile?.displayString ?? Nip19.shortNpub(hex: keypair.pubkey)
                        Button {
                            viewModel.switchSigningAccount(keypair)
                            showAccountPicker = false
                        } label: {
                            HStack(spacing: 12) {
                                CachedAvatarView(url: kProfile?.picture, size: 40)
                                    .id(keypair.pubkey)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(kName)
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(Color.wispOnSurface)
                                        .lineLimit(1)
                                    Text(Nip19.shortNpub(hex: keypair.pubkey))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if active {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundStyle(Color.wispPrimary)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Color.wispSurfaceVariant.opacity(0.4))
                    }
                }
                .scrollContentBackground(.hidden)
            }
            .navigationTitle("Post as")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { showAccountPicker = false }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private var textEditor: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack(alignment: .topLeading) {
                if viewModel.content.isEmpty {
                    Text(placeholderText)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                }
                MentionComposerTextView(viewModel: viewModel)
                    .frame(minHeight: viewModel.galleryMode ? 80 : 160, alignment: .topLeading)
                    .padding(.horizontal, 12)
            }
            if let progress = viewModel.uploadProgress {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(progress).font(.caption).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
            }
        }
    }

    private var galleryArea: some View {
        VStack(spacing: 8) {
            if viewModel.attachments.isEmpty {
                Button {
                    presentPhotoPicker(max: 8)
                } label: {
                    VStack(spacing: 6) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 28))
                            .foregroundStyle(.secondary)
                        Text("Add photos or video")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 180)
                    .background(Color.wispSurfaceVariant.opacity(0.4),
                                in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .tint(Color(.secondaryLabel))
                .padding(.horizontal, 12)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(viewModel.attachments) { attachment in
                            attachmentThumb(attachment, index: 0, size: 140)
                        }
                        Button {
                            presentPhotoPicker(max: 8)
                        } label: {
                            VStack(spacing: 4) {
                                Image(systemName: "plus")
                                    .font(.system(size: 22, weight: .semibold))
                                Text("Add").font(.caption2)
                            }
                            .frame(width: 140, height: 140)
                            .background(Color.wispSurfaceVariant.opacity(0.4),
                                        in: RoundedRectangle(cornerRadius: 12))
                            .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .tint(Color(.secondaryLabel))
                    }
                    .padding(.horizontal, 12)
                }
            }
        }
    }

    /// A single horizontally scrolling row of 64pt cells between the
    /// editor and the actions row. One axis on purpose: drag reordering
    /// reads along the row, and the visible capacity (~5 cells) gently
    /// caps how much media one post carries.
    ///
    /// Keyed by attachment id — required for the live drag-shuffle: the
    /// dragged cell's view must survive the reorder or iOS cancels the
    /// drag session. Reorder snaps (no inherited animation); the shuffle
    /// feedback is the cells snapping into new slots under the finger.
    private var attachmentsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(viewModel.attachments.enumerated()), id: \.element.id) { index, attachment in
                    attachmentThumb(attachment, index: index, size: 84)
                        .onGeometryChange(for: CGFloat.self) { proxy in
                            proxy.frame(in: .global).minX
                        } action: { minX in
                            cellX[index] = minX
                        }
                        .offset(x: reorder?.index == index ? reorder?.offsetX ?? 0 : 0)
                        .scaleEffect(reorder?.index == index ? 1.06 : 1)
                        .zIndex(reorder?.index == index ? 1 : 0)
                        .gesture(reorderDragGesture(attachment: attachment, index: index))
                }
            }
            .padding(.horizontal, 12)
        }
        .transaction { $0.animation = nil }
        // The @GestureState flag resets on end AND cancellation; a reset
        // with a still-lifted slot means the gesture died without
        // .onEnded — put the lifted cell back.
        .onChange(of: reorderGestureLive) { _, live in
            if !live { reorder = nil }
        }
    }

    /// One paste-attach offer, matching Android's row: a full-width
    /// accent-tinted container between editor and actions — paperclip,
    /// "Attach this media" (accept consumes the pasted occurrence and adds
    /// a slot) plus the quiet ✕ refusal ("Keep it as text"), which expires
    /// when the URL's line does.
    private func attachOfferRow(_ url: String) -> some View {
        HStack(spacing: 8) {
            Button {
                viewModel.attachUrl(url)
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "paperclip")
                        .font(.system(size: 14, weight: .medium))
                    Text("Attach this media")
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(Color.wispPrimary)
                .padding(.horizontal, 12)
                .padding(.vertical, 11)
                .background(Color.wispPrimary.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Attach this media")

            Button {
                viewModel.dismissAttachOffer(url)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 30, height: 30)
                    .background(Color.wispSurfaceVariant.opacity(0.5), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Keep it as text")
        }
        .padding(.horizontal, 12)
    }

    /// One thumbnail cell, matching Android's `AttachmentThumbStrip`: the
    /// per-image alt chip pinned to the thumbnail's top-leading corner and
    /// the remove ✕ top-trailing. Reordering is drag-only (long-press and
    /// drag, live-shuffling the cells); VoiceOver reaches the same moves
    /// through named accessibility actions.
    private func attachmentThumb(_ attachment: ComposeAttachment, index: Int, size: CGFloat) -> some View {
        return ZStack {
                // The media layer is hard-framed and clipped BEFORE the
                // ZStack sees it: `scaledToFill` lets a non-square image
                // grow the ZStack's layout union (a 16:9 source in an
                // 80pt cell lays out ~142pt wide), and the centering
                // that follows pushed the alt chip half out of the
                // clip — "off screen". Clipped here, the union stays
                // exactly size×size for every child.
                thumbImage(attachment, size: size)
                    .frame(width: size, height: size)
                    .clipped()

                if attachment.isVideo {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(.white.opacity(0.9))
                        .shadow(radius: 4)
                }

                if attachment.url == nil {
                    Color.black.opacity(0.4)
                    ProgressView().tint(.white)
                }

                // "+ ALT" until a description is saved, "✓ ALT" on the accent once
                // one is. Known-image only — unknown mime (a pasted link mid-fetch)
                // shows neither chip nor video badge, just the thumbnail. Pinned to
                // the cell's top-leading corner: the Spacers stretch the container
                // so the chip escapes the ZStack's center alignment.
                if !attachment.isVideo {
                    VStack(spacing: 0) {
                        HStack(spacing: 0) {
                            altChip(attachment)
                            Spacer(minLength: 0)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(4)
                }
            }
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(alignment: .topTrailing) {
                removeButton(attachment)
            }
            // Drag-only reorder (the gesture lives on the cell in
            // `attachmentsRow`); VoiceOver keeps reachable moves.
            .accessibilityAction(named: "Move earlier") {
                viewModel.moveMedia(id: attachment.id, earlier: true)
            }
            .accessibilityAction(named: "Move later") {
                viewModel.moveMedia(id: attachment.id, earlier: false)
            }
    }

    /// The image render ladder shared by the strip and the alt editor's
    /// preview: local bytes first (animated-aware), then the Blossom URL
    /// with 404-retry, then placeholder.
    @ViewBuilder
    private func thumbImage(_ attachment: ComposeAttachment, size: CGFloat) -> some View {
        if let bytes = attachment.localBytes,
           AnimatedImageHint.isLikelyAnimated(url: "", mime: attachment.mime),
           let payload = AnimatedImageDecoder.decode(data: bytes, maxPixelSize: size * UIScreen.main.scale) {
            // Animated GIF / animated WebP / APNG — render with the
            // per-frame decoder so the thumbnail plays before publish.
            // The simple `UIImage(data:)` path freezes on frame 0.
            AnimatedImageRenderer(payload: payload, contentMode: .scaleAspectFill)
        } else if let bytes = attachment.localBytes, let img = UIImage(data: bytes) {
            Image(uiImage: img)
                .resizable()
                .scaledToFill()
        } else if let url = attachment.url,
                  AnimatedImageHint.isLikelyAnimated(url: url, mime: attachment.mime) {
            // Post-upload: bytes have been cleared but the attachment
            // is animated. Fetch + animate from the Blossom URL.
            AnimatedImageView(
                url: URL(string: url),
                aspect: nil,
                contentMode: .fill,
                placeholder: { Color.wispSurfaceVariant },
                failure: { Color.wispSurfaceVariant }
            )
        } else if attachment.isVideo, let url = attachment.url, let imageURL = URL(string: url) {
            // Videos: the thumbnail is the video's own frame (sidecar #368) —
            // a downloaded .mp4 can't be decoded by UIImage, so the generic
            // image path must not catch these.
            VideoPosterFrame(url: imageURL, maxPixel: size * UIScreen.main.scale)
        } else if let url = attachment.url, let imageURL = URL(string: url) {
            RetryingMediaThumbnail(url: imageURL)
        } else {
            Color.wispSurfaceVariant
        }
    }

    /// "+ ALT" / "✓ ALT" — black translucent until described, accent once
    /// saved (Android `AltChip`). Sized for the 64pt cells.
    private func altChip(_ attachment: ComposeAttachment) -> some View {
        let saved = attachment.trimmedAltText != nil
        return Button {
            altEditorTarget = AltTextEditorTarget(
                        attachmentID: attachment.id,
                        previewURL: attachment.url,
                        localBytes: attachment.localBytes,
                        initialText: attachment.trimmedAltText
                    )
        } label: {
            Text(saved ? "✓ ALT" : "+ ALT")
                .font(.system(size: 9, weight: .semibold).monospaced())
                .foregroundStyle(saved ? Color.wispOnSurface : .white)
                .padding(.horizontal, 5)
                .padding(.vertical, 3)
                .background(
                    saved ? AnyShapeStyle(Color.wispPrimary) : AnyShapeStyle(.black.opacity(0.6)),
                    in: RoundedRectangle(cornerRadius: 5)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(saved ? "Edit alt text" : "Add alt text")
    }

    /// Remove = splice(i, 1), no text to clean up.
    private func removeButton(_ attachment: ComposeAttachment) -> some View {
        Button {
            viewModel.removeMedia(id: attachment.id)
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(.black.opacity(0.6), in: Circle())
        }
        .buttonStyle(.plain)
        .padding(4)
        .accessibilityLabel("Remove attachment")
    }

    /// The reorder gesture (#268): hold ~0.4s (Compose's long-press
    /// timeout), then the cell follows the finger. Only horizontal
    /// translation is honored — vertical movement belongs to the
    /// composer's scroll — and a plain swipe (no hold) still scrolls the
    /// row because the touch only becomes a reorder once the hold
    /// completes. All swap math runs against the lift-time snapshot:
    /// re-reading live positions mid-drag races the splice by a frame.
    private func reorderDragGesture(attachment: ComposeAttachment, index: Int) -> some Gesture {
        LongPressGesture(minimumDuration: 0.4)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .global))
            .updating($reorderGestureLive) { _, live, _ in
                live = true
            }
            .onChanged { value in
                switch value {
                case .first:
                    guard reorder == nil, cellX[index] != nil else { return }
                    reorder = ReorderState(snapshot: cellX, index: index, offsetX: 0)
                    Haptics.shared.pulse()
                case .second(true, let drag?):
                    guard var state = reorder else { return }
                    state.offsetX = drag.translation.width
                    let half: CGFloat = 42
                    let (newIndex, newOffsetX) = AttachmentModel.reorderStep(
                        snapshot: state.snapshot, from: state.index,
                        offsetX: state.offsetX, half: half
                    )
                    if newIndex != state.index {
                        viewModel.moveMedia(from: state.index, to: newIndex)
                        state.index = newIndex
                    }
                    state.offsetX = newOffsetX
                    reorder = state
                default:
                    break
                }
            }
            .onEnded { _ in reorder = nil }
    }

    private var scheduleBanner: some View {
        let date = viewModel.scheduleAt ?? Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy 'at' h:mm a"
        let formatted = formatter.string(from: date)
        return HStack(spacing: 8) {
            Image(systemName: "clock.fill")
                .foregroundStyle(Color.wispPrimary)
            Text("Scheduled for \(formatted)")
                .font(.caption.weight(.medium))
            Spacer()
            Button {
                viewModel.setSchedule(nil)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.wispPrimary.opacity(0.1))
    }

    private var nsfwBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: ComposeActionsRow.sensitiveGlyph(marked: true))
            Text(ComposeActionsRow.sensitiveBannerText)
                .font(.caption.weight(.medium))
            Spacer()
        }
        .foregroundStyle(.orange)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 12)
    }

    private var mentionPopup: some View {
        // Display-name collision detection. Search relays surface
        // impersonators using the same display name as a real account
        // (different pubkeys, identical bio). We can't safely dedupe
        // by content, so we surface a short npub beneath the colliding
        // names so the user can tell them apart.
        let nameCounts: [String: Int] = viewModel.mentionCandidates.reduce(into: [:]) { acc, c in
            acc[c.name.lowercased(), default: 0] += 1
        }
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(viewModel.mentionCandidates) { candidate in
                Button {
                    viewModel.selectMention(candidate)
                } label: {
                    let isCollision = (nameCounts[candidate.name.lowercased()] ?? 0) > 1
                    MentionCandidateRow(
                        candidate: candidate,
                        disambiguationNpub: isCollision ? Nip19.shortNpub(hex: candidate.pubkey) : nil
                    )
                }
                .buttonStyle(.plain)
                Divider().overlay(Color.wispSurfaceVariant.opacity(0.4))
            }
            if viewModel.isMentionSearchingRemote {
                // Pinned at the bottom so any local matches stay clickable
                // at the top while we wait on the relay. The spinner is the
                // signal that "more results may yet arrive" — without it
                // the popup looks like it's already final.
                HStack(spacing: 8) {
                    ProgressView().scaleEffect(0.7)
                    Text("Searching…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
        }
        .background(Color.wispSurfaceVariant.opacity(0.3),
                    in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 12)
    }

    private var emojiPopup: some View {
        EmojiSuggestionBar(candidates: viewModel.emojiCandidates) { emoji in
            viewModel.selectEmoji(emoji)
        }
    }

    // MARK: - Actions row (under text editor)

    /// The toolbar itself is `ComposeActionsRow` (under `wisp/`, so it can be
    /// rendered on its own in tests); this view keeps the pickers, which
    /// need its focus state and UIKit presenters.
    private var actionsRow: some View {
        ComposeActionsRow(
            viewModel: viewModel,
            onPickPhotos: { presentPhotoPicker(max: 4) },
            onPasteImage: { pasteImageFromClipboard() },
            onPickGif: {
                // Resign the compose text field before presenting so the
                // keyboard animation finishes ahead of the modal. Without
                // the hop, the keyboard collapse mid-present can cancel
                // the in-flight UIKit modal and SwiftUI flips
                // `showGifPicker` back to false — same shape as the
                // drafts-sheet keyboard race.
                contentFocused = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    showGifPicker = true
                }
            },
            onSchedule: { showScheduleSheet = true }
        )
    }

    // MARK: - Bottom publish bar

    private var bottomBar: some View {
        HStack(spacing: 12) {
            if viewModel.countdownSeconds != nil {
                Button(role: .destructive) {
                    viewModel.cancelPublish()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(Color.red, in: Circle())
                }
                .buttonStyle(.plain)

                Button {
                    viewModel.publishNow()
                } label: {
                    countdownProgressLabel
                }
                .buttonStyle(.plain)
            } else {
                // Grey the button out when the composer can't publish yet
                // and put the reason on the button ("Write something or add
                // a photo.", "Wait for uploads to finish."), the way the
                // recipe form does — a greyed-out button with no
                // explanation reads as broken.
                let inFlight = viewModel.isPublishing || viewModel.isMining
                let blocker = viewModel.publishBlocker
                let isInactive = blocker != nil
                Button {
                    if viewModel.needsFoodTagConfirm {
                        showFoodTagConfirm = true
                    } else {
                        viewModel.publish()
                    }
                } label: {
                    Group {
                        // Only flag mining once the miner has reported real
                        // attempts. Low-difficulty PoW returns nearly
                        // instantly, leaving `miningAttempts` at 0 — the
                        // label would otherwise flash "Mining 0" before
                        // settling on "Publishing", which reads as a stray
                        // countdown number.
                        if viewModel.isMining && viewModel.miningAttempts > 0 {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small).tint(.white)
                                Text("Mining \(viewModel.miningAttempts)")
                                    .font(.subheadline.weight(.semibold))
                            }
                        } else if inFlight {
                            HStack(spacing: 6) {
                                ProgressView().controlSize(.small).tint(.white)
                                Text(viewModel.scheduleEnabled ? "Scheduling" : "Publishing")
                                    .font(.subheadline.weight(.semibold))
                            }
                        } else if let blocker {
                            Text(blocker)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        } else {
                            Text(viewModel.scheduleEnabled ? "Schedule Post" : "Publish")
                                .font(.subheadline.weight(.semibold))
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                }
                .background(
                    isInactive ? Color.wispSurfaceVariant : Color.wispPrimary,
                    in: Capsule()
                )
                .foregroundStyle(isInactive ? Color.secondary : Color.white)
                .disabled(inFlight || isInactive)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .onChange(of: viewModel.publishedEventId) { _, newId in
            guard let newId else { return }
            // Normal posts hand off to `PostPublisher` which drives a bottom
            // pill ("Mining…" → "Broadcasting n/N" → "Posted to N relays").
            // The pill is the single source of confirmation — suppress the
            // top toast in that case. DMs and scheduled posts still finish
            // in-sheet and surface through the toast as before.
            if newId != "handed-off" {
                SuccessToast.shared.show(publishToastMessage)
            }
            dismiss()
        }
        // The two composer alerts attach here rather than to the outer
        // body chain: after the attachment-strip additions that chain grew
        // past what the type-checker resolves in reasonable time. Alerts
        // can hang off any view in the hierarchy.
        // `.alert` rather than `.confirmationDialog` so the cancel-role
        // "Keep Editing" button renders as an explicit choice. iOS 26
        // hides the cancel button on confirmation dialogs presented over
        // sheets, leaving only Save Draft / Discard visible.
        .alert(
            "No food tag yet",
            isPresented: $showFoodTagConfirm
        ) {
            // At the cap the tag can't be added (the toggle is a no-op), so
            // the one-tap fix is not offered; the user has to free a slot.
            if !viewModel.suggestedTagsAtCap {
                Button("Add #\(OnlyFoodCompose.defaultTag)") {
                    if viewModel.toggleSuggestedHashtag(OnlyFoodCompose.defaultTag) {
                        viewModel.publish()
                    }
                }
            }
            Button("Post anyway") { viewModel.publish() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(OnlyFoodCompose.noFoodTagMessage(count: viewModel.suggestedTagCount))
        }
        .alert(
            "Discard this post?",
            isPresented: $showCancelConfirm
        ) {
            Button("Save Draft") {
                Task {
                    await viewModel.saveDraft()
                    viewModel.cancelPublish()
                    dismiss()
                }
            }
            Button("Discard", role: .destructive) {
                viewModel.cancelPublish()
                viewModel.explicitlyDiscarded = true
                viewModel.clearLocalAutosave()
                dismiss()
            }
            Button("Keep Editing", role: .cancel) {}
        } message: {
            Text("You have unsaved content.")
        }
    }

    private var publishToastMessage: String {
        switch viewModel.mode {
        case .reply: return "Reply sent"
        case .quote: return "Quote posted"
        case .new: return viewModel.pollEnabled ? "Poll posted" : "Posted"
        }
    }

    // MARK: - Helpers

    private var navTitle: String {
        switch viewModel.mode {
        case .new:
            if viewModel.pollEnabled { return "New Poll" }
            return viewModel.galleryMode ? "Gallery Post" : "New Post"
        case .reply: return "Reply"
        case .quote: return "Quote"
        }
    }

    private var placeholderText: String {
        if viewModel.pollEnabled { return "Ask a question…" }
        switch viewModel.mode {
        case .new:
            if viewModel.galleryMode { return "Add a caption…" }
            return viewModel.suggestedHashtags.isEmpty ? "What's on your mind?" : OnlyFoodCompose.placeholder
        case .reply: return "Write your reply…"
        case .quote: return "Add a comment…"
        }
    }

    private var countdownProgressLabel: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let started = viewModel.countdownStartedAt ?? context.date
            let total = max(Double(viewModel.countdownTotalSeconds), 1)
            let elapsed = context.date.timeIntervalSince(started)
            let progress = max(0, min(1, elapsed / total))
            let remaining = max(0, Int(ceil(total - elapsed)))

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Color.wispPrimary.opacity(0.25)
                    Color.wispPrimary
                        .frame(width: geo.size.width * progress)
                    Text("Post Now (\(remaining)s)")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                .clipShape(Capsule())
            }
            .frame(height: 44)
        }
    }

    private var shouldShowPreview: Bool {
        if viewModel.galleryMode { return false }
        let hasText = !viewModel.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasAttachments = !viewModel.attachments.isEmpty
        return hasText || hasAttachments
    }

    /// Hand off a Giphy CDN URL to the view model, which re-hosts the bytes on
    /// the user's Blossom servers (so the published note doesn't depend on
    /// Giphy's rate-limited anonymous CDN) and appends the resulting URL to
    /// the post body.
    private func appendGifUrl(_ url: String) {
        Task { await viewModel.attachGifFromGiphy(url) }
    }

    /// Hand the system pasteboard's image item providers to the view model,
    /// which uploads each one to Blossom and appends as an attachment.
    /// `.onPasteCommand` is unavailable on iOS, so this routes through a
    /// visible button that reads `UIPasteboard.general` on tap.
    ///
    /// Detection has to handle a few quirks:
    /// - `canLoadObject(ofClass: UIImage.self)` misses Photos.app's custom UTI
    ///   pasteboard items. `hasItemConformingToTypeIdentifier("public.image")`
    ///   is the authoritative check — it includes every UTI that conforms to
    ///   `public.image` (PNG, JPEG, GIF, HEIC, WebP, TIFF, RAW, …).
    /// - When the clipboard has zero matching providers but `UIPasteboard`'s
    ///   high-level `image` accessor returns something (some sources only
    ///   write through the legacy API), fall back to that and re-wrap it as
    ///   a provider so the existing upload pipeline runs unchanged.
    /// - On nothing-to-paste, surface a toast so the user knows the tap
    ///   registered. Otherwise a silent button feels broken.
    private func pasteImageFromClipboard() {
        let pasteboard = UIPasteboard.general
        let providers = pasteboard.itemProviders.filter {
            $0.hasItemConformingToTypeIdentifier(UTType.image.identifier)
        }
        if !providers.isEmpty {
            Task { await viewModel.addPastedImages(providers) }
            return
        }
        if let image = pasteboard.image, let png = image.pngData() {
            let provider = NSItemProvider(item: png as NSData, typeIdentifier: UTType.png.identifier)
            Task { await viewModel.addPastedImages([provider]) }
            return
        }
        QuickFollowToast.shared.show("No image on clipboard")
    }

    private var previewTags: [[String]] {
        // Best-effort tag preview: real tags are built at publish time.
        var tags: [[String]] = []
        for tag in viewModel.hashtags { tags.append(["t", tag]) }
        return tags
    }

}

/// The video slot's thumbnail is the video's own frame (sidecar #368).
/// `preload=metadata`-style laziness stops at the header and paints
/// nothing, so we seek a tenth of a second's fraction into the clip —
/// clamped to half the duration so a very short clip still lands, and
/// never frame zero, which is usually black — and draw exactly that
/// frame. Every failure keeps the full placeholder, which still reads
/// as a working thumbnail; the play badge rides on top regardless.
private struct VideoPosterFrame: View {
    let url: URL
    let maxPixel: CGFloat
    @State private var poster: UIImage?
    @State private var attempted = false

    var body: some View {
        ZStack {
            Color.wispSurfaceVariant
            if let poster {
                Image(uiImage: poster)
                    .resizable()
                    .scaledToFill()
            }
        }
        .task(id: url) {
            guard poster == nil, !attempted else { return }
            attempted = true
            poster = await Self.generate(url: url, maxPixel: maxPixel)
        }
        // Position-keyed strip: a reorder reuses this view for a different
        // URL — drop the cached frame and try again for the new one.
        .onChange(of: url) { _, _ in
            poster = nil
            attempted = false
        }
    }

    static func generate(url: URL, maxPixel: CGFloat) async -> UIImage? {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration),
              duration.seconds.isFinite, duration.seconds > 0 else { return nil }
        let mid = min(duration.seconds * 0.1, duration.seconds / 2)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixel, height: maxPixel)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
        guard let result = try? await generator.image(
            at: CMTime(seconds: mid, preferredTimescale: 600)
        ) else { return nil }
        return UIImage(cgImage: result.image)
    }
}

/// A just-uploaded URL can 404 for a second or two while the Blossom host
/// finishes writing it; `AsyncImage` tries exactly once, so the thumbnail
/// would be blank forever. Retry a couple of times with a cache-busting
/// query, then fall back to a quiet "Tap to retry" placeholder — the URL
/// is in the draft either way and will be appended at publish, so the
/// failure stays legible without reading as a broken note.
private struct RetryingMediaThumbnail: View {
    let url: URL
    @State private var attempt = 0
    @State private var image: UIImage?
    @State private var failed = false

    private static let maxAttempts = 3

    var body: some View {
        ZStack {
            Color.wispSurfaceVariant
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else if failed {
                Button {
                    attempt = 0
                    failed = false
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: "photo")
                            .font(.system(size: 15, weight: .medium))
                        Text("Tap to retry")
                            .font(.system(size: 9, weight: .semibold))
                    }
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .task(id: "\(url.absoluteString)#\(attempt)") {
            guard image == nil, !failed else { return }
            var request = URLRequest(url: bustedURL)
            request.timeoutInterval = 10
            if let (data, response) = try? await URLSession.shared.data(for: request),
               let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
               let decoded = UIImage(data: data) {
                image = decoded
            } else if attempt + 1 < Self.maxAttempts {
                attempt += 1
            } else {
                failed = true
            }
        }
        // The strip keys cells by grid position (Android semantics), so a
        // reorder reuses this view for a different URL — the cached frame
        // belongs to the old one and must go.
        .onChange(of: url) { _, _ in
            image = nil
            attempt = 0
            failed = false
        }
    }

    /// First attempt hits the URL as-is (cached is fine); retries bust the
    /// cache with a throwaway query parameter so the host can't serve us
    /// the same miss twice.
    private var bustedURL: URL {
        guard attempt > 0,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }
        var items = components.queryItems ?? []
        items.append(URLQueryItem(name: "zc-retry", value: String(attempt)))
        components.queryItems = items
        return components.url ?? url
    }
}
