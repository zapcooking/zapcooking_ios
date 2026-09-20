import SwiftUI
import Observation

/// What a moderation dialog is currently about. One instance per view that
/// hosts the dialogs — `GroupRoomView` and the `GroupDetailView` it pushes
/// are both on screen at once, and a single shared value would ask both to
/// present. The actions themselves live on `GroupRoomViewModel`.
@Observable
@MainActor
final class GroupModerationPrompts {
    var blockCandidate: GroupRoomViewModel.ModerationCandidate?
    var removeCandidate: GroupRoomViewModel.ModerationCandidate?
    /// Why the last admin action failed, for an alert. Nil once shown.
    var notice: String?

    func askToBlock(_ pubkey: String, in viewModel: GroupRoomViewModel) {
        blockCandidate = viewModel.candidate(for: pubkey)
    }

    func askToRemove(_ pubkey: String, in viewModel: GroupRoomViewModel) {
        removeCandidate = viewModel.candidate(for: pubkey)
    }
}

/// The confirmation dialogs behind the room's moderation menus — shared by
/// the chat bubbles (`GroupRoomView`) and the member list (`GroupDetailView`).
/// Copy matches the feed's block dialog and Android's remove & ban
/// confirmation.
struct GroupModerationDialogs: ViewModifier {
    @Bindable var prompts: GroupModerationPrompts
    let viewModel: GroupRoomViewModel

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                prompts.blockCandidate.map { "Block \($0.displayName)?" } ?? "Block this user?",
                isPresented: presented(\.blockCandidate),
                titleVisibility: .visible
            ) {
                Button("Block", role: .destructive) {
                    if let candidate = prompts.blockCandidate {
                        viewModel.blockAuthor(candidate.pubkey)
                    }
                    prompts.blockCandidate = nil
                }
                .accessibilityIdentifier("confirm-block-group-member")
                Button("Cancel", role: .cancel) { prompts.blockCandidate = nil }
            } message: {
                Text("Their messages and posts will be hidden.")
            }
            .confirmationDialog(
                prompts.removeCandidate.map { "Remove & ban \($0.displayName)?" } ?? "Remove & ban this member?",
                isPresented: presented(\.removeCandidate),
                titleVisibility: .visible
            ) {
                Button("Remove & ban", role: .destructive) {
                    if let candidate = prompts.removeCandidate {
                        Task { prompts.notice = await viewModel.removeFromRoom(candidate.pubkey) }
                    }
                    prompts.removeCandidate = nil
                }
                .accessibilityIdentifier("confirm-remove-group-member")
                Button("Cancel", role: .cancel) { prompts.removeCandidate = nil }
            } message: {
                Text("They won't be able to rejoin this room, even with an invite.")
            }
            .alert(
                "Couldn't remove that member",
                isPresented: Binding(
                    get: { prompts.notice != nil },
                    set: { if !$0 { prompts.notice = nil } }
                )
            ) {
                Button("OK") { prompts.notice = nil }
            } message: {
                Text(prompts.notice ?? "")
            }
    }

    private func presented(
        _ keyPath: ReferenceWritableKeyPath<GroupModerationPrompts, GroupRoomViewModel.ModerationCandidate?>
    ) -> Binding<Bool> {
        Binding(
            get: { prompts[keyPath: keyPath] != nil },
            set: { if !$0 { prompts[keyPath: keyPath] = nil } }
        )
    }
}

extension View {
    func groupModerationDialogs(_ prompts: GroupModerationPrompts, viewModel: GroupRoomViewModel) -> some View {
        modifier(GroupModerationDialogs(prompts: prompts, viewModel: viewModel))
    }
}
