import SwiftUI

/// Cheffy — the member-gated kitchen-companion chat (Concern C-E, port of
/// Android `CheffyScreen`: chat + hungry). Whole-response (no streaming): a
/// pending bubble shows a status line (one picked per request) while the
/// long-timeout request runs, then resolves to a markdown reply.
///
/// Gates render as a **message only** — no purchase UI, no price, no
/// link-out (build spec §4.3): watch-only accounts get the members line plus
/// "sign in with a key"; a verified non-member gets the members line; an
/// in-chat bare 403 is an "unavailable" bubble with Try again. A structured
/// recipe reply gets **Save to my recipes**, which hands the markdown to the
/// existing `RecipeComposeView` (`.prefillMarkdown`, the Sous Chef seam) —
/// no second publish path.
///
/// Presented as a full-screen cover from the Recipes-tab sparkle menu.
struct CheffyView: View {
    let keypair: Keypair
    /// Called after a publish from the Save → compose hand-off. The host
    /// dismisses this cover and routes to the recipe.
    let onPublished: (_ author: String, _ dTag: String) -> Void
    let onDismiss: () -> Void

    @State private var viewModel = CheffyViewModel()
    @State private var draft = ""
    @State private var composeSession: RecipeComposeSession?
    @FocusState private var composerFocused: Bool

    var body: some View {
        NavigationStack {
            content
                .background(Color.wispBackground)
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        HStack(spacing: 8) {
                            CheffyIcon(size: 28, expression: .neutral)
                            Text("Cheffy")
                                .font(AppFont.titleMedium)
                                .foregroundStyle(Color.wispOnSurface)
                        }
                    }
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close", action: onDismiss)
                            .accessibilityIdentifier("cheffy-close")
                    }
                    ToolbarItem(placement: .primaryAction) {
                        if !viewModel.thread.isEmpty {
                            Button("Start over") { viewModel.startOver() }
                                .disabled(viewModel.loading)
                                .accessibilityIdentifier("cheffy-start-over")
                        }
                    }
                }
                .navigationBarTitleDisplayMode(.inline)
        }
        .task { await viewModel.checkGate(keypair: keypair) }
        .fullScreenCover(item: $composeSession) { session in
            // Save hand-off — the same stacked presentation Sous Chef's Edit
            // gets: dismissing compose returns to the chat; publishing
            // routes to the recipe.
            RecipeComposeView(
                keypair: keypair,
                session: session,
                onPublished: { author, dTag in
                    composeSession = nil
                    onPublished(author, dTag)
                },
                onDismiss: { composeSession = nil }
            )
        }
    }

    @ViewBuilder
    private var content: some View {
        if !viewModel.gateResolved {
            VStack(spacing: 12) {
                CheffyIcon(size: 72, expression: .thinking)
                ProgressView().controlSize(.small)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("cheffy-checking")
        } else {
            gatedOrChat
        }
    }

    @ViewBuilder
    private var gatedOrChat: some View {
        switch viewModel.gate {
        case .watchOnly:
            gatedState(secondLine: Cheffy.signInMessage)
        case .notMember:
            gatedState(secondLine: nil)
        case .open:
            VStack(spacing: 0) {
                if viewModel.thread.isEmpty {
                    emptyState
                } else {
                    messageList
                }
                Divider()
                composer
            }
        }
    }

    // MARK: - Gated (message only, §4.3)

    private func gatedState(secondLine: String?) -> some View {
        VStack(spacing: 12) {
            CheffyIcon(size: 72, expression: .neutral)
            Text(Cheffy.membersOnlyMessage)
                .font(AppFont.titleMedium)
                .foregroundStyle(Color.wispOnSurface)
                .multilineTextAlignment(.center)
            if let secondLine {
                Text(secondLine)
                    .font(AppFont.bodyMedium)
                    .foregroundStyle(Color.wispOnSurfaceVariant)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("cheffy-gated")
    }

    // MARK: - Empty

    private var emptyState: some View {
        ScrollView {
            VStack(spacing: 16) {
                CheffyIcon(size: 88, expression: .happy)
                Text("Your kitchen companion")
                    .font(AppFont.titleLarge)
                    .foregroundStyle(Color.wispOnSurface)
                Text("Ask what to cook, how to fix it, or what to do with what's in your fridge.")
                    .font(AppFont.bodyMedium)
                    .foregroundStyle(Color.wispOnSurfaceVariant)
                    .multilineTextAlignment(.center)
                FlowLayout(spacing: 8) {
                    ForEach(Cheffy.promptPlaceholders.prefix(4), id: \.self) { prompt in
                        chip(prompt) {
                            draft = prompt
                            composerFocused = true
                        }
                    }
                    chip(Cheffy.surpriseMeLabel) { surprise() }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity)
        }
        .accessibilityIdentifier("cheffy-empty")
    }

    private func chip(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(AppFont.bodySmall)
                .foregroundStyle(Color.wispOnSurface)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .overlay(Capsule().stroke(Color.wispOutline, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(viewModel.loading)
    }

    // MARK: - Thread

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(viewModel.thread) { message in
                        bubble(message).id(message.id)
                    }
                }
                .padding(16)
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: viewModel.thread.count) { _, _ in
                if let last = viewModel.thread.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    @ViewBuilder
    private func bubble(_ message: CheffyViewModel.Message) -> some View {
        let isUser = message.role == .user
        HStack {
            if isUser { Spacer(minLength: 40) }
            switch message.kind {
            case .pending:
                pendingBubble(message)
            case .error:
                errorBubble(message)
            case .text, .recipe, .gated:
                VStack(alignment: isUser ? .trailing : .leading, spacing: 6) {
                    Group {
                        if isUser || message.kind == .gated {
                            Text(message.content)
                                .font(AppFont.bodyLarge)
                                .foregroundStyle(isUser ? Color.white : Color.wispOnSurface)
                                .padding(12)
                        } else {
                            CheffyMarkdownText(text: message.content)
                                .padding(12)
                        }
                    }
                    .background(
                        isUser ? Color.wispPrimary : Color.wispSurfaceVariant,
                        in: RoundedRectangle(cornerRadius: 16)
                    )
                    // A structured Cheffy recipe → Save to my recipes: routes
                    // through the compose editor (add a photo + category
                    // there). Chat is gated to signing accounts, so no
                    // watch-only case here.
                    if message.kind == .recipe {
                        Button {
                            composeSession = .prefillMarkdown(message.content)
                        } label: {
                            Label("Save to my recipes", systemImage: "bookmark")
                                .font(AppFont.titleMedium)
                                .foregroundStyle(Color.wispOnSurface)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                .background(Color.wispSurfaceVariant.opacity(0.6), in: RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("cheffy-save-recipe")
                    }
                }
            }
            if !isUser { Spacer(minLength: 40) }
        }
    }

    private func pendingBubble(_ message: CheffyViewModel.Message) -> some View {
        HStack(spacing: 10) {
            CheffyIcon(size: 28, expression: message.expression)
            Text(message.statusLine ?? "Thinking…")
                .font(AppFont.bodyMedium)
                .foregroundStyle(Color.wispOnSurfaceVariant)
            ProgressView().controlSize(.small)
        }
        .padding(12)
        .background(Color.wispSurfaceVariant, in: RoundedRectangle(cornerRadius: 16))
        .accessibilityIdentifier("cheffy-pending")
    }

    private func errorBubble(_ message: CheffyViewModel.Message) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                CheffyIcon(size: 24, expression: message.expression)
                Text(message.content)
                    .font(AppFont.bodyMedium)
                    .foregroundStyle(Color.wispOnSurface)
            }
            if let detail = message.statusLine {
                Text(detail)
                    .font(AppFont.bodySmall)
                    .foregroundStyle(Color.wispOnSurfaceVariant)
            }
            Button("Try again") { viewModel.retry(keypair: keypair) }
                .font(AppFont.titleMedium)
                .foregroundStyle(Color.wispPrimary)
                .disabled(viewModel.loading)
                .accessibilityIdentifier("cheffy-retry")
        }
        .padding(12)
        .background(Color.wispSurfaceVariant, in: RoundedRectangle(cornerRadius: 16))
        .accessibilityIdentifier("cheffy-error")
    }

    // MARK: - Composer

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 4) {
            Button(action: surprise) {
                Image(systemName: "dice")
                    .font(.system(size: 20))
                    .foregroundStyle(Color.wispOnSurfaceVariant)
                    .padding(8)
            }
            .disabled(viewModel.loading)
            .accessibilityLabel("Surprise me")
            .accessibilityIdentifier("cheffy-surprise")

            TextField(Cheffy.promptPlaceholders[0], text: $draft, axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.roundedBorder)
                .focused($composerFocused)
                .onChange(of: draft) { _, value in
                    if value.count > Cheffy.maxPromptChars {
                        draft = String(value.prefix(Cheffy.maxPromptChars))
                    }
                }
                .disabled(viewModel.loading)
                .accessibilityIdentifier("cheffy-input")

            Button(action: sendDraft) {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 20))
                    .foregroundStyle(canSend ? Color.wispPrimary : Color.wispOnSurfaceVariant)
                    .padding(8)
            }
            .disabled(!canSend)
            .accessibilityLabel("Send")
            .accessibilityIdentifier("cheffy-send")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var canSend: Bool {
        !viewModel.loading && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func sendDraft() {
        let text = draft
        draft = ""
        viewModel.send(text, mode: .chat, keypair: keypair)
    }

    private func surprise() {
        viewModel.send("", mode: .hungry, keypair: keypair)
    }
}

/// Minimal markdown for chat bubbles — headings, bullets, numbered steps,
/// and inline bold/italic. Enough for Cheffy's conversational replies and
/// the structured-recipe format (Android `CheffyMarkdown` parity; full
/// article rendering isn't needed in a bubble).
struct CheffyMarkdownText: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                render(line)
            }
        }
    }

    private var lines: [String] {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: "\n")
            .map { $0.trimmingTrailingWhitespace() }
    }

    @ViewBuilder
    private func render(_ line: String) -> some View {
        if line.trimmingCharacters(in: .whitespaces).isEmpty {
            Spacer().frame(height: 2)
        } else if line.hasPrefix("### ") {
            Text(inline(String(line.dropFirst(4)))).font(AppFont.titleMedium).foregroundStyle(Color.wispOnSurface)
        } else if line.hasPrefix("## ") {
            Text(inline(String(line.dropFirst(3)))).font(AppFont.titleMedium).foregroundStyle(Color.wispOnSurface)
        } else if line.hasPrefix("# ") {
            Text(inline(String(line.dropFirst(2)))).font(AppFont.titleLarge).foregroundStyle(Color.wispOnSurface)
        } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
            Text(inline("•  " + line.dropFirst(2))).font(AppFont.bodyLarge).foregroundStyle(Color.wispOnSurface)
        } else {
            Text(inline(line)).font(AppFont.bodyLarge).foregroundStyle(Color.wispOnSurface)
        }
    }

    /// Inline `**bold**` / `*italic*` via Foundation's markdown parser;
    /// falls back to the literal text if it doesn't parse.
    private func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
    }
}

private extension String {
    func trimmingTrailingWhitespace() -> String {
        var s = Substring(self)
        while let last = s.last, last == " " || last == "\t" || last == "\r" { s.removeLast() }
        return String(s)
    }
}
