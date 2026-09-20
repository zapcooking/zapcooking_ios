import SwiftUI

struct GroupListView: View {
    @Bindable var viewModel: GroupListViewModel
    let onTap: (GroupRoom) -> Void

    @State private var showCreate = false
    @State private var showJoin = false
    @State private var showDiscover = false
    @State private var showActionSheet = false

    var body: some View {
        ZStack {
            if viewModel.repository.joinedGroups.isEmpty {
                empty
            } else {
                list
            }

            VStack {
                Spacer()
                HStack {
                    Spacer()
                    addButton.padding(20)
                }
            }
        }
        .confirmationDialog("New chat room", isPresented: $showActionSheet, titleVisibility: .visible) {
            Button("Create new room") { showCreate = true }
            Button("Join via link") { showJoin = true }
            Button("Discover") { showDiscover = true }
            Button("Cancel", role: .cancel) {}
        }
        .sheet(isPresented: $showCreate) {
            CreateGroupSheet(viewModel: viewModel) { showCreate = false }
        }
        .sheet(isPresented: $showJoin) {
            JoinGroupSheet(viewModel: viewModel) { showJoin = false }
        }
        .sheet(isPresented: $showDiscover) {
            DiscoverGroupsView(viewModel: viewModel) { showDiscover = false }
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(viewModel.repository.joinedGroups) { room in
                    Button { onTap(room) } label: {
                        GroupListRow(room: room,
                                     unread: viewModel.repository.unreadGroupKeys.contains(room.id))
                    }
                    .buttonStyle(.plain)
                    Divider().overlay(Color.wispSurfaceVariant.opacity(0.3))
                }
            }
        }
    }

    private var empty: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.3.sequence")
                .font(.system(size: 44))
                .foregroundStyle(.tertiary)
            Text("No chat rooms yet")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Tap + to create a room or join one with an invite link.")
                .font(.subheadline)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var addButton: some View {
        Button { showActionSheet = true } label: {
            Image(systemName: "plus")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white)
                .padding(16)
                .background(Color.wispPrimary, in: Circle())
                .shadow(radius: 6)
        }
        .buttonStyle(.plain)
    }
}

private struct GroupListRow: View {
    let room: GroupRoom
    let unread: Bool

    var body: some View {
        HStack(spacing: 12) {
            CachedAvatarView(url: room.metadata?.picture, size: 48)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(room.metadata?.name ?? room.groupId)
                        .font(.subheadline.weight(unread ? .bold : .semibold))
                        .lineLimit(1)
                    if room.members.count > 0 {
                        Text("(\(room.members.count))")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    if room.lastMessageAt > 0 {
                        Text(relativeTime(room.lastMessageAt))
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    if unread {
                        Circle().fill(Color.wispPrimary).frame(width: 8, height: 8)
                    }
                }
                Text(preview)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    private var preview: String {
        if let last = room.visibleMessages.last { return last.content }
        return room.metadata?.about ?? "(no messages)"
    }

    private func relativeTime(_ ts: Int) -> String {
        let interval = Date().timeIntervalSince1970 - Double(ts)
        switch interval {
        case ..<60: return "now"
        case ..<3600: return "\(Int(interval / 60))m"
        case ..<86400: return "\(Int(interval / 3600))h"
        default: return "\(Int(interval / 86400))d"
        }
    }
}

