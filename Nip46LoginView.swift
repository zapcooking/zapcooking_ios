import SwiftUI

/// Remote-signer login screen. Reachable from the login sheets via
/// "Use a signer app", or directly when a `bunker://` string was pasted or
/// scanned into their key field. Two paths share one screen:
///   1. **Connect** — we generate a `nostrconnect://` URI; the user scans
///      the QR from their signer, or opens it in a signer app on this
///      device (Clave, Amber, Primal).
///   2. **Bunker link** — the user pastes the `bunker://` URI their signer
///      app exported (Amber, Primal).
struct Nip46LoginView: View {
    var onLogin: (Keypair) -> Void
    /// Recorded with the account this screen saves — the tap that opened it
    /// was the agreement (see `PendingAgreement`).
    let acceptance: TermsAcceptance
    /// Pre-fills the bunker tab when the caller already holds a
    /// `bunker://` string (pasted or scanned into a login field).
    var initialBunkerURI: String?

    @Environment(\.dismiss) private var dismiss
    @State private var vm: Nip46LoginViewModel
    @State private var copiedAcknowledgement = false
    /// Set when no installed app claims the `nostrconnect://` scheme.
    @State private var signerAppHint: String?

    init(onLogin: @escaping (Keypair) -> Void,
         acceptance: TermsAcceptance,
         initialBunkerURI: String? = nil) {
        self.onLogin = onLogin
        self.acceptance = acceptance
        self.initialBunkerURI = initialBunkerURI
        _vm = State(initialValue: Nip46LoginViewModel(
            acceptance: acceptance,
            initialBunkerURI: initialBunkerURI
        ))
    }

    var body: some View {
        // `@Observable` view models can't be bound via `$` from a child
        // computed property, so the few inputs in this view use explicit
        // `Binding(get:set:)` constructions instead.
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    Image(systemName: "link.badge.plus")
                        .font(.system(size: 44))
                        .foregroundStyle(Color.wispPrimary)
                        .padding(.top, 8)

                    Text("Remote Signer")
                        .font(.title2.bold())

                    Text("Sign in with a remote signer (Clave, Amber, Primal). Your private key never leaves the signer app.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)

                    Picker("Mode", selection: modeBinding) {
                        ForEach(Nip46LoginViewModel.Mode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(vm.isWorking)

                    Group {
                        switch vm.mode {
                        case .bunker: bunkerSection
                        case .nostrconnect: nostrConnectSection
                        }
                    }

                    if let err = vm.displayError {
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }

                    if case .connecting(let msg) = vm.status {
                        ProgressView(msg)
                    }
                }
                .padding()
            }
            .background(Color.wispBackground)
            .navigationTitle("Connect")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        vm.cancelPendingHandshake()
                        dismiss()
                    }
                    .foregroundStyle(.secondary)
                }
            }
            .onChange(of: vm.status) { _, status in
                if case .connected(let pubkey) = status {
                    onLogin(Keypair(privkey: "", pubkey: pubkey))
                }
            }
            .onChange(of: vm.mode) { _, _ in
                vm.cancelPendingHandshake()
                vm.status = .idle
            }
            .onDisappear {
                vm.cancelPendingHandshake()
            }
        }
        .presentationDetents([.large])
    }

    // MARK: - Bindings

    private var modeBinding: Binding<Nip46LoginViewModel.Mode> {
        Binding(get: { vm.mode }, set: { vm.mode = $0 })
    }

    private var bunkerInputBinding: Binding<String> {
        Binding(get: { vm.bunkerURIInput }, set: { vm.bunkerURIInput = $0 })
    }

    // MARK: - Bunker section

    @ViewBuilder
    private var bunkerSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Paste a bunker:// URI from your signer.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            TextEditor(text: bunkerInputBinding)
                .font(.system(.footnote, design: .monospaced))
                .frame(minHeight: 90)
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color(.secondarySystemBackground))
                )
                .overlay(alignment: .topLeading) {
                    if vm.bunkerURIInput.isEmpty {
                        Text("bunker://abc123...?relay=wss://...&secret=...")
                            .font(.system(.footnote, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .padding(14)
                            .allowsHitTesting(false)
                    }
                }
                .disabled(vm.isWorking)

            HStack {
                Button {
                    if let s = pasteboardString() { vm.bunkerURIInput = s }
                } label: {
                    Label("Paste", systemImage: "doc.on.clipboard")
                        .font(.footnote)
                }
                .buttonStyle(.bordered)
                .tint(.wispPrimary)
                .disabled(vm.isWorking)

                Spacer()

                Button {
                    Task { await vm.submitBunker() }
                } label: {
                    if vm.isWorking {
                        ProgressView()
                    } else {
                        Text("Connect").bold()
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.wispPrimary)
                .disabled(vm.isWorking || vm.bunkerURIInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            VStack(alignment: .leading, spacing: 4) {
                Label("Where do I find this?", systemImage: "info.circle")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Text("Open your signer app and look for **Export Bunker URL**, **Add Account**, or **Connect**. Clave and Primal expose this directly. The URI starts with `bunker://`.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 8)
        }
    }

    // MARK: - Nostrconnect section

    @ViewBuilder
    private var nostrConnectSection: some View {
        VStack(spacing: 14) {
            if let uri = vm.pendingURI {
                Text("Open your signer and add a new account by scanning this code, or paste the URI.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                QRCodeImage(payload: uri, sideLength: 240, correctionLevel: "M")
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 12).fill(.white)
                    )

                Button {
                    vm.copyURIToPasteboard()
                    copiedAcknowledgement = true
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(1.4))
                        copiedAcknowledgement = false
                    }
                } label: {
                    Label(copiedAcknowledgement ? "Copied" : "Copy URI",
                          systemImage: copiedAcknowledgement ? "checkmark" : "doc.on.doc")
                        .font(.footnote)
                }
                .buttonStyle(.bordered)
                .tint(.wispPrimary)

                Text(uri)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .padding(.horizontal)

                Button {
                    Task {
                        signerAppHint = nil
                        if await vm.openInSignerApp() { return }
                        signerAppHint = "No signer app on this device can open that link — scan the code with your signer instead."
                    }
                } label: {
                    Label("Open in signer app", systemImage: "arrow.up.forward.app")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.wispPrimary)

                if let signerAppHint {
                    Text(signerAppHint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                }

                ProgressView("Waiting for signer to approve…")
                    .padding(.top, 4)
            } else {
                Text("Show a code your signer app (Clave, Amber, Primal, …) can scan or open to connect.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                Button {
                    vm.startNostrConnect()
                } label: {
                    Text("Generate QR Code").bold().frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.wispPrimary)
                .controlSize(.large)
            }
        }
    }

    // MARK: - Helpers

    private func pasteboardString() -> String? {
        #if canImport(UIKit)
        return UIPasteboard.general.string
        #else
        return nil
        #endif
    }
}
