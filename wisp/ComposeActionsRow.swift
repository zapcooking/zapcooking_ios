import SwiftUI

/// The compose toolbar under the text editor: photos, paste, GIF, sensitive
/// (NIP-36 content warning), poll, private reply, schedule.
///
/// Lifted out of `ComposeView` so it renders on its own in tests. The
/// pickers stay with the sheet (they need its focus state and UIKit
/// presenters) and arrive as closures.
///
/// Glyph choices, on purpose:
/// - **Sensitive** is `eye.slash` / `eye.slash.fill`, not a warning
///   triangle. The triangle read as "something is wrong" rather than "mark
///   this sensitive"; an eye-slash reads as an action. The feature (an
///   empty `content-warning` tag) is unchanged — it is part of the answer
///   to Apple's Guideline 1.2 "method for filtering objectionable content",
///   so it stays.
/// - **Schedule** is `calendar` / `calendar.badge.checkmark`, not a clock:
///   the app ships cooking timers, so a clock was ambiguous. Android keeps
///   its clock; the glyph parity break is deliberate.
/// - The Proof of Work shield is gone. It was inherited Wisp chrome that
///   nobody could name; Settings → Proof of Work is the single control and
///   note PoW defaults off (`PowPreferences`).
///
/// Active states use the primary tint at 100%, matching the FAB and the
/// selected bottom-bar glyph; nothing here outweighs Publish.
struct ComposeActionsRow: View {
    @Bindable var viewModel: ComposeViewModel
    var onPickPhotos: () -> Void
    var onPasteImage: () -> Void
    var onPickGif: () -> Void
    var onSchedule: () -> Void

    static func sensitiveGlyph(marked: Bool) -> String {
        marked ? "eye.slash.fill" : "eye.slash"
    }

    static func scheduleGlyph(scheduled: Bool) -> String {
        scheduled ? "calendar.badge.checkmark" : "calendar"
    }

    static let sensitiveBannerText = "Marked sensitive. Readers see a warning first."

    /// The controls, in order, for a given composer state — what the row
    /// shows, as accessibility labels. Tests pin the set (no shield, no
    /// clock).
    static func controls(mode: ComposeMode, pollEnabled: Bool, galleryMode: Bool) -> [String] {
        var out: [String] = []
        if !galleryMode, !pollEnabled { out.append("Add photos") }
        if !pollEnabled { out.append("Paste image from clipboard") }
        if !pollEnabled { out.append("Add GIF") }
        out.append("Mark as sensitive")
        if mode.allowsPollToggle { out.append("Create poll") }
        if case .reply = mode { out.append("Send privately") }
        out.append("Schedule post")
        return out
    }

    private static let glyphSize: CGFloat = 22

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
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
                    Button(action: onPasteImage) {
                        Image(systemName: "doc.on.clipboard")
                            .font(.system(size: Self.glyphSize))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Paste image from clipboard")
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

                Button {
                    viewModel.toggleNsfw()
                } label: {
                    Image(systemName: Self.sensitiveGlyph(marked: viewModel.explicit))
                        .font(.system(size: Self.glyphSize))
                        .foregroundStyle(viewModel.explicit ? Color.wispPrimary : .secondary)
                }
                .accessibilityLabel(viewModel.explicit ? "Unmark as sensitive" : "Mark as sensitive")
                .accessibilityIdentifier("compose-sensitive")

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

                // Private-reply toggle — only meaningful for `.reply` mode. Locked
                // (no-op) when the parent is itself a private rumor; the icon stays
                // filled to signal the chain stays encrypted.
                if case .reply = viewModel.mode {
                    Button {
                        viewModel.togglePrivate()
                    } label: {
                        Image(systemName: viewModel.isPrivate ? "lock.fill" : "lock")
                            .font(.system(size: Self.glyphSize))
                            .foregroundStyle(viewModel.isPrivate ? Color.wispPrimary : .secondary)
                    }
                    .disabled(viewModel.isPrivateLocked)
                    .accessibilityLabel(viewModel.isPrivate ? "Disable private reply" : "Send privately")
                }

                Button(action: onSchedule) {
                    Image(systemName: Self.scheduleGlyph(scheduled: viewModel.scheduleEnabled))
                        .font(.system(size: Self.glyphSize))
                        .foregroundStyle(viewModel.scheduleEnabled ? Color.wispPrimary : .secondary)
                }
                .disabled(viewModel.isPrivate)
                .accessibilityLabel(viewModel.scheduleEnabled ? "Change schedule" : "Schedule post")
                .accessibilityIdentifier("compose-schedule")
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("compose-actions")
    }
}
