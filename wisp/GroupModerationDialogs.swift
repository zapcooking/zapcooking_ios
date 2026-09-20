import SwiftUI

/// The confirmation dialogs behind the room's moderation menus — shared by
/// the chat bubbles (`GroupRoomView`) and the member list (`GroupDetailView`),
/// which drive the same `GroupRoomViewModel` state. Copy matches the feed's
/// block dialog and Android's remove & ban confirmation.
struct GroupModerationDialogs: ViewModifier {
    @Bindable var viewModel: GroupRoomViewModel

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                viewModel.blockCandidate.map { "Block \($0.displayName)?" } ?? "Block this user?",
                isPresented: presented(\.blockCandidate),
                titleVisibility: .visible
            ) {
                Button("Block", role: .destructive) {
                    if let candidate = viewModel.blockCandidate {
                        viewModel.blockAuthor(candidate.pubkey)
                    }
                    viewModel.blockCandidate = nil
                }
                .accessibilityIdentifier("confirm-block-group-member")
                Button("Cancel", role: .cancel) { viewModel.blockCandidate = nil }
            } message: {
                Text("Their messages and posts will be hidden.")
            }
            .confirmationDialog(
                viewModel.removeCandidate.map { "Remove & ban \($0.displayName)?" } ?? "Remove & ban this member?",
                isPresented: presented(\.removeCandidate),
                titleVisibility: .visible
            ) {
                Button("Remove & ban", role: .destructive) {
                    if let candidate = viewModel.removeCandidate {
                        Task { await viewModel.removeFromRoom(candidate.pubkey) }
                    }
                    viewModel.removeCandidate = nil
                }
                .accessibilityIdentifier("confirm-remove-group-member")
                Button("Cancel", role: .cancel) { viewModel.removeCandidate = nil }
            } message: {
                Text("They won't be able to rejoin this room, even with an invite.")
            }
            .alert(
                "Couldn't remove that member",
                isPresented: Binding(
                    get: { viewModel.moderationNotice != nil },
                    set: { if !$0 { viewModel.moderationNotice = nil } }
                )
            ) {
                Button("OK") { viewModel.moderationNotice = nil }
            } message: {
                Text(viewModel.moderationNotice ?? "")
            }
    }

    private func presented(
        _ keyPath: ReferenceWritableKeyPath<GroupRoomViewModel, GroupRoomViewModel.ModerationCandidate?>
    ) -> Binding<Bool> {
        Binding(
            get: { viewModel[keyPath: keyPath] != nil },
            set: { if !$0 { viewModel[keyPath: keyPath] = nil } }
        )
    }
}

extension View {
    func groupModerationDialogs(_ viewModel: GroupRoomViewModel) -> some View {
        modifier(GroupModerationDialogs(viewModel: viewModel))
    }
}
