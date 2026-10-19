import SwiftUI

/// The compose toolbar under the text editor: media, GIF, poll, and the
/// "…" overflow into `ComposerMoreSheet`.
///
/// Lifted out of `ComposeView` so it renders on its own in tests. The
/// pickers stay with the sheet (they need its focus state and UIKit
/// presenters) and arrive as closures.
///
/// Composer redesign, Oct 2026 (parity with the Android composer's
/// secondary panel): only what a standard social client offers inline stays
/// on the row — attach media, GIF, poll — and everything else (paste, the
/// sensitive mark, Proof of Work, scheduling, private reply) moved into the
/// "…" sheet. Nothing here outweighs Publish.
///
/// Glyph choices, on purpose:
/// - The sheet's **sensitive** row is `eye.slash` / `eye.slash.fill`, not a
///   warning triangle. The triangle read as "something is wrong" rather
///   than "mark this sensitive"; an eye-slash reads as an action. The
///   feature (an empty `content-warning` tag) is unchanged — it is part of
///   the answer to Apple's Guideline 1.2 "method for filtering objectionable
///   content", so it stays.
/// - The sheet's **schedule** row is `calendar` / `calendar.badge.checkmark`,
///   not a clock: the app ships cooking timers, so a clock was ambiguous.
///   Android keeps its clock; the glyph parity break is deliberate.
/// - Proof of Work returns in the sheet as a per-compose switch (seeded
///   from the Settings default, which stays the difficulty's single home);
///   the old inline shield on the row stayed gone.
struct ComposeActionsRow: View {
    @Bindable var viewModel: ComposeViewModel
    var onPickPhotos: () -> Void
    var onPickGif: () -> Void
    var onMore: () -> Void

    static func sensitiveGlyph(marked: Bool) -> String {
        marked ? "eye.slash.fill" : "eye.slash"
    }

    static func scheduleGlyph(scheduled: Bool) -> String {
        scheduled ? "calendar.badge.checkmark" : "calendar"
    }

    static let sensitiveBannerText = "Marked sensitive. Readers see a warning first."

    /// The controls, in order, for a given composer state — what the row
    /// shows, as accessibility labels. Tests pin the set: core actions
    /// inline, everything else (paste included) behind "More options".
    static func controls(mode: ComposeMode, pollEnabled: Bool, galleryMode: Bool) -> [String] {
        var out: [String] = []
        if !galleryMode, !pollEnabled { out.append("Add photos") }
        if !pollEnabled { out.append("Add GIF") }
        if mode.allowsPollToggle { out.append("Create poll") }
        out.append("More options")
        return out
    }

    private static let glyphSize: CGFloat = 22

    var body: some View {
        HStack(spacing: 22) {
            if !viewModel.galleryMode, !viewModel.pollEnabled {
                Button(action: onPickPhotos) {
                    Image(systemName: "photo.on.rectangle")
                        .font(.system(size: Self.glyphSize))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .tint(Color(.secondaryLabel))
                .accessibilityLabel("Add photos")
            }

            if !viewModel.pollEnabled {
                Button(action: onPickGif) {
                    Text("GIF")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .overlay(
                            RoundedRectangle(cornerRadius: 5)
                                .stroke(Color.secondary, lineWidth: 1.5)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Add GIF")
            }

            if viewModel.mode.allowsPollToggle {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        viewModel.togglePoll()
                    }
                } label: {
                    Image(systemName: "chart.bar")
                        .font(.system(size: Self.glyphSize))
                        .foregroundStyle(viewModel.pollEnabled ? Color.wispPrimary : .secondary)
                }
                .accessibilityLabel(viewModel.pollEnabled ? "Disable poll" : "Create poll")
            }

            Spacer(minLength: 0)

            Button(action: onMore) {
                Image(systemName: "ellipsis")
                    .font(.system(size: Self.glyphSize, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 28, minHeight: 28)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("More options")
            .accessibilityIdentifier("compose-more")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("compose-actions")
    }
}

/// The composer's secondary panel behind "…": every option that is not core
/// to writing a note — paste, the sensitive mark (NIP-36 content warning),
/// Proof of Work, scheduling, and the private-reply toggle for replies — as
/// rows that fire the same view-model calls the old inline icons did.
/// Behavior is unchanged; only the exposure moved (parity with the Android
/// composer's secondary panel). Drafts save automatically, so unlike
/// Android there is no save-draft row.
@MainActor
struct ComposerMoreSheet: View {
    var onPaste: () -> Void
    var explicit: Bool
    var onToggleExplicit: () -> Void
    var powEnabled: Bool
    var onTogglePow: () -> Void
    var scheduleEnabled: Bool
    /// "Scheduled for Oct 20, 12:08 PM" once a date is set; nil clears the row's subtitle.
    var scheduleSummary: String?
    var scheduleUnavailable: Bool
    var onSchedule: () -> Void
    var privateReplyVisible: Bool
    var privateReplyEnabled: Bool
    var privateReplyLocked: Bool
    var onTogglePrivateReply: () -> Void

    @Environment(\.dismiss) private var dismiss

    /// The rows, in order, for a given composer state — what the sheet
    /// shows, as accessibility labels. Tests pin the set.
    static func rows(replyMode: Bool) -> [String] {
        var out = [
            "Paste image from clipboard",
            "Mark as sensitive",
            "Proof of work",
            "Schedule post",
        ]
        if replyMode { out.append("Send privately") }
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("More options")
                .font(.system(size: 17, weight: .semibold))
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 8)

            row(
                icon: "doc.on.clipboard",
                title: "Paste image from clipboard",
                subtitle: nil
            ) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .onTapGesture {
                dismiss()
                onPaste()
            }
            .accessibilityAction { onPaste() }

            Divider()

            row(
                icon: ComposeActionsRow.sensitiveGlyph(marked: explicit),
                title: explicit ? "Unmark as sensitive" : "Mark as sensitive",
                subtitle: explicit ? ComposeActionsRow.sensitiveBannerText : nil
            ) {
                Toggle("", isOn: Binding(
                    get: { explicit },
                    set: { _ in onToggleExplicit() }
                ))
                .labelsHidden()
                .tint(Color.wispPrimary)
            }

            Divider()

            row(
                icon: powEnabled ? "shield.fill" : "shield",
                title: "Proof of work",
                subtitle: "Default and difficulty live in Settings → Proof of Work."
            ) {
                Toggle("", isOn: Binding(
                    get: { powEnabled },
                    set: { _ in onTogglePow() }
                ))
                .labelsHidden()
                .tint(Color.wispPrimary)
            }

            Divider()

            row(
                icon: ComposeActionsRow.scheduleGlyph(scheduled: scheduleEnabled),
                title: scheduleEnabled ? "Change schedule" : "Schedule post",
                subtitle: scheduleSummary
            ) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .disabled(scheduleUnavailable)
            .onTapGesture { onSchedule() }
            .accessibilityAction { onSchedule() }

            if privateReplyVisible {
                Divider()

                row(
                    icon: privateReplyEnabled ? "lock.fill" : "lock",
                    title: privateReplyEnabled ? "Private reply on" : "Send privately",
                    subtitle: privateReplyEnabled ? "The reply arrives gift-wrapped." : nil
                ) {
                    Toggle("", isOn: Binding(
                        get: { privateReplyEnabled },
                        set: { _ in onTogglePrivateReply() }
                    ))
                    .labelsHidden()
                    .tint(Color.wispPrimary)
                    .disabled(privateReplyLocked)
                }
            }
        }
        .padding(.bottom, 16)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func row<Trailing: View>(
        icon: String, title: String, subtitle: String?,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundStyle(.secondary)
                .frame(width: 26)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 16))
                    .foregroundStyle(.primary)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }
}
