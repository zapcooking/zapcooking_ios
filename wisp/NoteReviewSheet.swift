import SwiftUI

/// Cheffy Note Photo Review sheet — the SwiftUI counterpart of the web
/// `CheffyNoteReview.svelte` (copy verbatim at frontend `eb99f009`) and
/// Android's `NoteReviewSheet`. Renders the draft flow only: choose a mode,
/// wait, edit the draft, post it as the member's own reply. A verified
/// non-member sees the Cheffy chat gate copy and nothing else — no price,
/// no purchase, no link-out (build spec §4.3).
///
/// Dumb by design: state comes in from `NoteReviewViewModel`, intents go
/// out. The view model is owned here so a fresh sheet is a fresh session.
struct NoteReviewSheet: View {
    let parent: NostrEvent
    let imageUrls: [String]
    let keypair: Keypair
    /// Open the thread for the published reply (after the sheet dismisses).
    var onViewReply: ((NostrEvent) -> Void)? = nil

    @State private var viewModel = NoteReviewViewModel()
    @Environment(\.dismiss) private var dismiss

    private var prefs: NoteReviewPreferences { NoteReviewPreferences(pubkey: keypair.pubkey) }
    private let publisher = RelayNoteReviewReplyPublisher()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            content
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.wispBackground)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        // While a publish is in flight the reply may already be signed and
        // broadcast; a swipe-dismiss would drop the outcome before the
        // signed event (the same-id retry) or the posted event is recorded.
        // The posting layout offers no Close either, so the sheet stays up
        // until the publisher answers.
        .interactiveDismissDisabled(viewModel.phase == .posting)
        .onAppear { viewModel.open(parent: parent, imageUrls: imageUrls) }
        .onDisappear { viewModel.onSheetClosed() }
        .accessibilityIdentifier("note-review-sheet")
    }

    private var busy: Bool { viewModel.phase == .signing || viewModel.phase == .loading }

    private var header: some View {
        HStack(spacing: 10) {
            CheffyIcon(size: 28, expression: busy ? .cooking : .happy)
            Text(NoteReview.sheetTitle)
                .font(AppFont.titleMedium)
                .foregroundStyle(Color.wispOnSurface)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.phase {
        case .draft, .posting:
            // Web renders draft and posting as one layout with the controls
            // disabled while the publish is in flight.
            draftContent
        default:
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    switch viewModel.phase {
                    case .choose:
                        chooseContent
                    case .signing:
                        waitContent(expression: .thinking, line: NoteReview.signingLine, sub: NoteReview.signingSubline)
                    case .loading:
                        waitContent(expression: .cooking, line: viewModel.loadingLine)
                    case .postTimeout:
                        waitContent(expression: .thinking, line: viewModel.message)
                        actionRow {
                            Button("Give it another push") { viewModel.retryPost(publisher: publisher) }
                                .buttonStyle(.borderedProminent)
                            Button("Close") { dismiss() }
                                .buttonStyle(.plain)
                        }
                    case .posted:
                        waitContent(expression: .excited, line: NoteReview.postedLine)
                        actionRow {
                            Button("View your reply") {
                                let posted = viewModel.postedEvent
                                dismiss()
                                if let posted { onViewReply?(posted) }
                            }
                            .buttonStyle(.borderedProminent)
                            Button("Done") { dismiss() }
                                .buttonStyle(.plain)
                        }
                    case .deadEnd:
                        waitContent(expression: .concerned, line: viewModel.message)
                        actionRow {
                            Button("Back") { viewModel.startOver() }
                                .buttonStyle(.plain)
                        }
                    case .membersOnly:
                        membersOnlyContent
                    case .error:
                        waitContent(
                            expression: .concerned,
                            line: viewModel.errorLine,
                            sub: viewModel.message.isEmpty ? nil : viewModel.message
                        )
                        actionRow {
                            Button("Try again") { viewModel.regenerate(keypair: keypair) }
                                .buttonStyle(.bordered)
                            Button("Back") { viewModel.startOver() }
                                .buttonStyle(.plain)
                        }
                    case .draft, .posting:
                        EmptyView()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - Choose

    @ViewBuilder
    private var chooseContent: some View {
        if let url = URL(string: viewModel.imageUrl), !viewModel.imageUrl.isEmpty {
            RetryingAsyncImage(url: url, maxPixelSize: 900) { image in
                image.resizable().scaledToFill()
            } loading: {
                Color.wispSurfaceVariant
            } failure: {
                Color.wispSurfaceVariant
            }
            .frame(maxWidth: .infinity)
            .frame(height: 220)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .accessibilityLabel("Photo from the note")
        }
        imagePickerStrip(enabled: true)
        Text(NoteReview.chooseHint)
            .font(AppFont.bodyMedium)
            .foregroundStyle(Color.wispOnSurfaceVariant)
        modeCard(title: NoteReview.commentCardTitle, subtitle: NoteReview.commentCardSubtitle) {
            viewModel.choose(.comment, keypair: keypair, prefs: prefs)
        }
        .accessibilityIdentifier("note-review-comment")
        modeCard(title: NoteReview.recipeCardTitle, subtitle: NoteReview.recipeCardSubtitle) {
            viewModel.choose(.recipe, keypair: keypair, prefs: prefs)
        }
        .accessibilityIdentifier("note-review-recipe")
    }

    private func modeCard(title: String, subtitle: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(AppFont.bodyLarge)
                    .foregroundStyle(Color.wispOnSurface)
                Text(subtitle)
                    .font(AppFont.bodySmall)
                    .foregroundStyle(Color.wispOnSurfaceVariant)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color.wispSurfaceVariant, in: RoundedRectangle(cornerRadius: 12))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Wait / message states

    private func waitContent(expression: Cheffy.Expression, line: String, sub: String? = nil) -> some View {
        VStack(spacing: 10) {
            CheffyIcon(size: 64, expression: expression)
            Text(line)
                .font(AppFont.bodyLarge)
                .foregroundStyle(Color.wispOnSurface)
                .multilineTextAlignment(.center)
            if let sub {
                Text(sub)
                    .font(AppFont.bodySmall)
                    .foregroundStyle(Color.wispOnSurfaceVariant)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }

    /// Message only (§4.3): the Cheffy chat gate copy, and a way out.
    private var membersOnlyContent: some View {
        VStack(spacing: 12) {
            CheffyIcon(size: 64, expression: .neutral)
            Text(Cheffy.membersOnlyMessage)
                .font(AppFont.titleMedium)
                .foregroundStyle(Color.wispOnSurface)
                .multilineTextAlignment(.center)
            Button("Close") { dismiss() }
                .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .accessibilityIdentifier("note-review-gated")
    }

    private func actionRow<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 8) { content() }
            .frame(maxWidth: .infinity)
    }

    // MARK: - Draft

    /// The field is the only thing that flexes; the toggle, footer preview,
    /// error and action rows are ordinary siblings pinned below it so
    /// "Post reply" stays reachable regardless of draft length or keyboard.
    private var draftContent: some View {
        let posting = viewModel.phase == .posting
        return VStack(alignment: .leading, spacing: 12) {
            Text(NoteReview.draftHint)
                .font(AppFont.bodyMedium)
                .foregroundStyle(Color.wispOnSurfaceVariant)
            // Picking a photo here only ARMS the next Regenerate (web parity).
            imagePickerStrip(enabled: !posting)
            TextEditor(text: Binding(
                get: { viewModel.draft },
                set: { viewModel.updateDraft($0) }
            ))
            .font(AppFont.bodyMedium)
            .scrollContentBackground(.hidden)
            .padding(8)
            .frame(minHeight: viewModel.mode == .recipe ? 240 : 120)
            .frame(maxHeight: .infinity)
            .background(Color.wispSurfaceVariant, in: RoundedRectangle(cornerRadius: 12))
            .disabled(posting)
            .accessibilityLabel("Cheffy's draft")
            Text("\(viewModel.draft.count) characters")
                .font(AppFont.labelSmall)
                .foregroundStyle(Color.wispOnSurfaceVariant)
            Toggle(isOn: Binding(
                get: { viewModel.disclosureOn },
                set: { _ in viewModel.toggleDisclosure(prefs: prefs) }
            )) {
                Text(NoteReview.disclosureToggleLabel)
                    .font(AppFont.bodyMedium)
                    .foregroundStyle(Color.wispOnSurface)
            }
            .disabled(posting)
            if viewModel.disclosureOn {
                // Publish-time footer preview — deliberately NOT part of the
                // editor above, so nobody edits their draft trying to remove it.
                VStack(alignment: .leading, spacing: 2) {
                    Text(NoteReview.footerPreviewLabel)
                        .font(AppFont.labelSmall)
                        .foregroundStyle(Color.wispOnSurfaceVariant)
                    Text(NoteReview.disclosureFooter)
                        .font(AppFont.bodySmall)
                        .foregroundStyle(Color.wispOnSurface)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.wispSurfaceVariant, in: RoundedRectangle(cornerRadius: 8))
            }
            if !viewModel.postError.isEmpty {
                Text(viewModel.postError)
                    .font(AppFont.bodySmall)
                    .foregroundStyle(Color.red)
            }
            HStack(spacing: 8) {
                Button("Regenerate") { viewModel.regenerate(keypair: keypair) }
                    .buttonStyle(.bordered)
                    .disabled(posting)
                Button("Start over") { viewModel.startOver() }
                    .buttonStyle(.plain)
                    .disabled(posting)
                Spacer(minLength: 0)
                Button(posting ? "Posting…" : "Post reply") {
                    viewModel.post(publisher: publisher, keypair: keypair)
                }
                .buttonStyle(.borderedProminent)
                .disabled(posting || viewModel.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("note-review-post")
            }
        }
    }

    /// Multi-image thumbnail strip — rendered only when the note carries
    /// more than one detected image. Selection is client-side only: it
    /// picks which photo the NEXT request sends.
    @ViewBuilder
    private func imagePickerStrip(enabled: Bool) -> some View {
        if viewModel.imageUrls.count > 1 {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(viewModel.imageUrls.enumerated()), id: \.offset) { index, url in
                        let selected = index == viewModel.selectedImageIndex
                        Button {
                            viewModel.selectImage(index)
                        } label: {
                            RetryingAsyncImage(url: URL(string: url), maxPixelSize: 200) { image in
                                image.resizable().scaledToFill()
                            } loading: {
                                Color.wispSurfaceVariant
                            } failure: {
                                Color.wispSurfaceVariant
                            }
                            .frame(width: 56, height: 56)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(selected ? Color.wispPrimary : Color.wispOutline, lineWidth: selected ? 2 : 1)
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(!enabled)
                        .accessibilityLabel("Photo \(index + 1) of \(viewModel.imageUrls.count)")
                    }
                }
            }
        }
    }
}
