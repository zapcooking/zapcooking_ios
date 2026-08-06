import SwiftUI

struct CreateGroupSheet: View {
    @Bindable var viewModel: GroupListViewModel
    let onClose: () -> Void

    @State private var name: String = ""
    @State private var about: String = ""
    @State private var picture: String = ""
    @State private var relay: String = Nip29.defaultGroupRelay
    @State private var isPrivate = false
    @State private var isClosed = false
    @State private var isRestricted = false
    @State private var isHidden = false
    @State private var isSubmitting = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Group") {
                    TextField("Name", text: $name)
                    TextField("About", text: $about)
                    TextField("Picture URL", text: $picture)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                }
                Section("Relay") {
                    TextField("wss://pantry.zap.cooking", text: $relay)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                }
                Section("Privacy") {
                    Toggle("Private (members only read)", isOn: $isPrivate)
                    Toggle("Closed (no open joins)", isOn: $isClosed)
                    Toggle("Restricted (members only post)", isOn: $isRestricted)
                    Toggle("Hidden (not in discovery)", isOn: $isHidden)
                }
                if let error {
                    Section { Text(error).font(.caption).foregroundStyle(.red) }
                }
            }
            .navigationTitle("New room")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { onClose() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Create") { Task { await create() } }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || isSubmitting)
                }
            }
        }
    }

    private func create() async {
        isSubmitting = true
        error = nil
        defer { isSubmitting = false }
        let res = await viewModel.createGroup(relayUrl: relay, name: name,
                                              isPrivate: isPrivate, isClosed: isClosed,
                                              isRestricted: isRestricted, isHidden: isHidden)
        switch res {
        case .success: onClose()
        case .failure(let e): error = "Create failed: \(e)"
        }
    }
}
