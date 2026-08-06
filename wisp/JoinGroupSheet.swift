import SwiftUI

struct JoinGroupSheet: View {
    @Bindable var viewModel: GroupListViewModel
    let onClose: () -> Void

    @State private var link: String = ""
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Invite link") {
                    TextField("wss://pantry.zap.cooking'groupid?code=…", text: $link, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .lineLimit(2...4)
                    Text("Format: `wss://relay.host'groupid` or with code: `wss://relay.host'groupid?code=invite`.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                if let error {
                    Section { Text(error).font(.caption).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Join room")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { onClose() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Join") { Task { await join() } }
                        .disabled(link.trimmingCharacters(in: .whitespaces).isEmpty || viewModel.isJoining)
                }
            }
        }
    }

    private func join() async {
        error = nil
        let res = await viewModel.joinGroup(inviteLink: link)
        switch res {
        case .success: onClose()
        case .failure(let e): error = "Join failed: \(e)"
        }
    }
}
