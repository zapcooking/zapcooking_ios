import SwiftUI

struct LoginView: View {
    var onLogin: (Keypair) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var nsecInput = ""
    /// Only used when the key field holds an `ncryptsec1…` (NIP-49) backup —
    /// decryption needs the encryption password.
    @State private var ncryptsecPassword = ""
    @State private var error: String?
    @State private var isSecure = true
    @State private var isLoading = false
    /// The QR scanner and Create a new account, each presented on the
    /// agreement its tap gave (Log In takes its own at the tap). This screen
    /// is the account switcher's entry point, so it gates like the splash
    /// does: the notice sits beneath the actions and tapping one is agreeing.
    /// `PendingAgreement`, not a Bool beside an optional — see its doc.
    @State private var qrScan: PendingAgreement?
    @State private var signUp: PendingAgreement?

    private var isNcryptsec: Bool {
        nsecInput.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .hasPrefix("ncryptsec1")
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                // Bounded top spacer — keeps content anchored to a stable
                // top offset. A flexible Spacer() here would redistribute
                // every time the home indicator's safe-area inset changes
                // during sheet presentation, jumping every form element.
                Spacer().frame(maxHeight: 60)

                Image("ZcLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 72, height: 72)

                Text("Log In")
                    .font(.title.bold())
                    .foregroundStyle(Color.wispOnSurface)

                Text(isNcryptsec ? "Enter the password for your ncryptsec key" : "Enter your nsec key")
                    .foregroundStyle(.secondary)

                HStack(spacing: 12) {
                    Group {
                        if isSecure {
                            SecureField("nsec1… / ncryptsec1…", text: $nsecInput)
                        } else {
                            TextField("nsec1… / ncryptsec1…", text: $nsecInput)
                        }
                    }
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)

                    Button {
                        isSecure.toggle()
                    } label: {
                        Image(systemName: isSecure ? "eye.slash" : "eye")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)

                    Button {
                        qrScan = PendingAgreement(.now())
                    } label: {
                        Image(systemName: "qrcode.viewfinder")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .onChange(of: nsecInput) { _, _ in
                    error = nil
                    if !isNcryptsec { ncryptsecPassword = "" }
                }

                if isNcryptsec {
                    SecureField("Password", text: $ncryptsecPassword)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .onChange(of: ncryptsecPassword) { _, _ in error = nil }
                }

                NsecIdentityPreview(nsecInput: nsecInput)

                if let error {
                    Text(error)
                        .foregroundStyle(.red)
                        .font(.caption)
                }

                Button {
                    login()
                } label: {
                    if isLoading {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    } else {
                        Text("Log In")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(.wispPrimary)
                .controlSize(.large)
                .disabled(nsecInput.isEmpty || isLoading || (isNcryptsec && ncryptsecPassword.isEmpty))

                HStack(spacing: 8) {
                    Rectangle().fill(.tertiary).frame(height: 1)
                    Text("OR").font(.caption.bold()).foregroundStyle(.tertiary)
                    Rectangle().fill(.tertiary).frame(height: 1)
                }
                .padding(.vertical, 4)

                Button {
                    signUp = PendingAgreement(.now())
                } label: {
                    Label("Create a new account", systemImage: "person.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.wispPrimary)
                .controlSize(.large)

                TermsAgreementNotice()
                    .padding(.top, 4)

                Spacer()
            }
            .padding(.horizontal, 32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.wispBackground)
            .ignoresSafeArea(.keyboard, edges: .bottom)
            // Pinned to the top-leading corner so it stays clear of the
            // Log In button and of the keyboard. At .bottom with a fixed
            // 120pt inset it overlapped the action buttons, and
            // white-on-15%-white read as scenery rather than a button.
            .overlay(alignment: .topLeading) {
                Button(action: { dismiss() }) {
                    Text("Cancel")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                        .background(.white.opacity(0.92), in: Capsule())
                }
                .padding(.leading, 16)
                .padding(.top, 16)
            }
            .fullScreenCover(item: $qrScan) { pending in
                QRCodeScannerView(
                    onScanned: { value in handleScanned(value, acceptance: pending.acceptance) },
                    onCancel: { qrScan = nil }
                )
                .ignoresSafeArea()
            }
            .fullScreenCover(item: $signUp) { pending in
                SignUpFlowView(acceptance: pending.acceptance) { kp in
                    signUp = nil
                    onLogin(kp)
                }
            }
        }
        .presentationDetents([.large])
        // Paint the sheet's container background so the wisp color is in
        // place from frame one — without this the sheet renders the system
        // default behind the still-laying-out VStack and the buttons appear
        // to jump as the background settles in around them.
        .presentationBackground(Color.wispBackground)
        .onAppear { nsecPasteAllowed = true }
        .onDisappear { nsecPasteAllowed = false }
    }

    private func handleScanned(_ value: String, acceptance: TermsAcceptance) {
        qrScan = nil
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)

        // nsec1… or 64-char hex private key — reuse existing parse + save path.
        if let keypair = NostrKey.parseNsec(trimmed) {
            NostrKey.save(keypair, acceptance: acceptance)
            onLogin(keypair)
            return
        }

        // npub1, nprofile1 — watch-only account (browse without signing).
        // decodeNostrUri lowercases internally so case in the QR payload doesn't matter.
        // Onboarding still runs (in its watch-only variant) so the user's kind-10002
        // gets ingested and the relay scoreboard is built — otherwise the feed is empty.
        if let uriData = Nip19.decodeNostrUri(trimmed),
           case .profileRef(let pubkeyHex, _) = uriData {
            NostrKey.saveWatchOnly(pubkey: pubkeyHex, acceptance: acceptance)
            onLogin(Keypair(privkey: "", pubkey: pubkeyHex))
            return
        }

        error = "Unrecognized format. Scan an nsec, npub, nprofile, or hex private key."
    }

    private func login() {
        error = nil
        let acceptance = TermsAcceptance.now()
        isLoading = true
        // Trim before parsing: an nsec pasted from a password manager can
        // carry a trailing newline, which fails parseNsec on add-account
        // while the QR path and first-run login both trim and succeed.
        let input = nsecInput.trimmingCharacters(in: .whitespacesAndNewlines)

        if isNcryptsec {
            let password = ncryptsecPassword
            Task {
                do {
                    // scrypt at log_n ≥ 16 burns 64 MB+ and a few hundred ms
                    // of CPU — keep it off the main actor so the spinner spins.
                    let privkey = try await Task.detached(priority: .userInitiated) {
                        try Nip49.decrypt(input, password: password)
                    }.value
                    guard let pub = Secp256k1.publicKey(from: Data(privkey)) else {
                        error = "That ncryptsec decrypted to an invalid private key."
                        isLoading = false
                        return
                    }
                    let keypair = Keypair(privkey: Hex.encode(Data(privkey)), pubkey: Hex.encode(pub))
                    NostrKey.save(keypair, acceptance: acceptance)
                    isLoading = false
                    onLogin(keypair)
                } catch Nip49.CryptoError.wrongPassword {
                    error = "Wrong password for that ncryptsec key."
                    isLoading = false
                } catch {
                    self.error = "Couldn't read that ncryptsec key. Check the password and try again."
                    isLoading = false
                }
            }
            return
        }

        Task {
            let result = NostrKey.parseNsec(input)
            isLoading = false
            guard let keypair = result else {
                error = "Couldn't read that key. Paste an nsec (\"nsec1…\"), an ncryptsec (\"ncryptsec1…\"), or a 64-character hex private key."
                return
            }
            NostrKey.save(keypair, acceptance: acceptance)
            onLogin(keypair)
        }
    }
}
