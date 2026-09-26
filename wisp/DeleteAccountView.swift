import SwiftUI
import UIKit

/// Drives Settings → About → Delete Account. The steps, in order:
///   1. Explain what is deleted, what is public and not ours to remove, and
///      that Cook+ is separate; offer the nsec (and wallet phrase) exports.
///   2. Find this account's iCloud-Keychain backup: listing needs no
///      sign-in, but backups are opaque until decrypted, so when any exist
///      the user signs in with Apple and enters the recovery PIN — the same
///      decrypt restore does, and the hard confirmation for backed-up
///      accounts. A forgotten PIN can only remove every backup here.
///   3. Everything else confirms by typing DELETE.
///   4. The deletion request to Zap Cooking (NIP-98, signed by this key, so
///      before the wipe). A failure never traps the user: retry, or delete
///      from this device anyway with honest copy about what isn't queued.
///   5. `AccountDeletion.delete` — backups, then the local wipe.
@Observable
@MainActor
final class DeleteAccountViewModel {
    enum Step: Equatable {
        case explain
        case checkingICloud
        case iCloudUnavailable
        case needsApple(count: Int)
        case signingIn
        case enterPin(attemptFailed: Bool)
        case matching
        case forgotPin(count: Int)
        /// Apple + PIN found this account's backups; one tap left.
        case confirmMatched(count: Int)
        /// No backup to find (or the user chose to remove all of them) —
        /// typed confirmation.
        case confirmTyped
        case requesting
        /// The server didn't take the deletion request.
        case requestFailed
        case deleting
        case failed(String)
        /// Deleted; the result screen waits for Done before the app moves on.
        case done
    }

    static let confirmationWord = "DELETE"

    let keypair: Keypair
    private(set) var step: Step = .explain
    private(set) var cookPlus: CookPlusCancellation = .none
    /// The server's receipt, once the deletion request is accepted.
    private(set) var receipt: DeletionRequestReceipt?
    /// The user chose to delete from this device without a request.
    private(set) var requestSkipped = false
    /// After `.done`: the account the app switches to, nil for logout.
    private(set) var handedOffTo: Keypair?

    /// What the typed confirmation will delete from iCloud, and why — shown
    /// on the confirmation screen so the user sees what they are agreeing to.
    private(set) var pendingBackupIDs: [String] = []
    private(set) var backupNote: BackupNote = .none

    enum BackupNote: Equatable {
        case none
        /// No Zap Cooking backup exists in this iCloud account.
        case noBackups
        /// Backups exist, none is this account.
        case noneForThisAccount
        /// Forgotten PIN: every backup here goes.
        case removingAll(count: Int)
        /// iCloud unreachable; any backup stays.
        case iCloudSkipped
    }

    private let backups: ICloudBackupStore
    private let requester: DeletionRequestSender
    private let deviceWipe: DeviceWipe
    private let signInManager = AppleSignInManager()
    private var files: [KeychainBackupService.BackupFile] = []
    private var appleUserID: String?

    init(
        keypair: Keypair,
        backups: ICloudBackupStore? = nil,
        requester: DeletionRequestSender? = nil,
        deviceWipe: DeviceWipe? = nil
    ) {
        self.keypair = keypair
        self.backups = backups ?? KeychainBackupService()
        self.requester = requester ?? ZapCookingDeletionRequest()
        self.deviceWipe = deviceWipe ?? AppDataDeviceWipe()
    }

    // MARK: Cook+

    func loadMembership() async {
        guard !keypair.isWatchOnly else { return }
        guard let status = try? await ZapCookingApi.checkMembershipStatus(
            signer: LocalNip98Signer(keypair: keypair)
        ) else { return }
        cookPlus = CookPlusCancellation(status: status)
    }

    // MARK: Backups

    func beginBackupCheck() {
        Task { @MainActor in await checkBackups() }
    }

    func checkBackups() async {
        step = .checkingICloud
        do {
            files = try await backups.listBackups()
            if files.isEmpty {
                confirmTyped(ids: [], note: .noBackups)
            } else {
                step = .needsApple(count: files.count)
            }
        } catch let e as KeychainBackupError {
            if case .iCloudUnavailable = e.kind {
                step = .iCloudUnavailable
            } else {
                step = .failed("iCloud Keychain couldn\u{2019}t be read. Try again.")
            }
        } catch {
            step = .failed(error.localizedDescription)
        }
    }

    func skipICloud() {
        confirmTyped(ids: [], note: .iCloudSkipped)
    }

    func signInWithApple() {
        guard let presenter = authFlowTopMostViewController() else { return }
        step = .signingIn
        Task { @MainActor in
            do {
                appleUserID = try await signInManager.signIn(presenting: presenter).userID
                step = .enterPin(attemptFailed: false)
            } catch let e as AppleSignInManager.SignInError {
                if case .cancelled = e {
                    step = .needsApple(count: files.count)
                } else {
                    step = .failed(e.errorDescription ?? "Apple sign-in failed.")
                }
            } catch {
                step = .failed(error.localizedDescription)
            }
        }
    }

    func submitPin(_ pin: String) {
        guard BackupCrypto.isValidPin(pin), let userID = appleUserID else { return }
        let files = self.files
        let pubkey = keypair.pubkey
        step = .matching
        Task { @MainActor in
            let result: AccountDeletion.BackupMatch? = await Task.detached(priority: .userInitiated) {
                guard let key = try? BackupCrypto.deriveBackupKey(appleUserID: userID, pin: pin) else { return nil }
                return AccountDeletion.match(files: files, key32: key, pubkeyHex: pubkey)
            }.value
            switch result {
            case .matched(let ids):
                pendingBackupIDs = ids
                backupNote = .none
                step = .confirmMatched(count: ids.count)
            case .noneForThisAccount:
                confirmTyped(ids: [], note: .noneForThisAccount)
            case .wrongPin, nil:
                step = .enterPin(attemptFailed: true)
            }
        }
    }

    func forgotPin() {
        step = .forgotPin(count: files.count)
    }

    func removeAllBackups() {
        confirmTyped(ids: files.map(\.backupID), note: .removingAll(count: files.count))
    }

    func backToApple() {
        step = .needsApple(count: files.count)
    }

    private func confirmTyped(ids: [String], note: BackupNote) {
        pendingBackupIDs = ids
        backupNote = note
        step = .confirmTyped
    }

    // MARK: Delete

    /// Confirmed: send the deletion request (while the key exists), then
    /// delete. A request that fails stops at `.requestFailed`.
    func confirm() async {
        if !keypair.isWatchOnly && receipt == nil && !requestSkipped {
            step = .requesting
            do {
                receipt = try await requester.send(keypair: keypair)
            } catch {
                step = .requestFailed
                return
            }
        }
        await finishDeletion()
    }

    /// From `.requestFailed`: delete from this device without the request.
    func deleteWithoutRequest() async {
        requestSkipped = true
        await finishDeletion()
    }

    private func finishDeletion() async {
        step = .deleting
        let pubkey = keypair.pubkey
        // Only an account that can actually be loaded: a stale list entry
        // would otherwise make `delete` refuse the hand-off.
        let next = NostrKey.accounts().first {
            $0 != pubkey && NostrKey.loadAccount(pubkey: $0) != nil
        }
        do {
            handedOffTo = try await AccountDeletion.delete(
                pubkey: pubkey,
                backupIDs: pendingBackupIDs,
                handOffTo: next,
                backups: backups,
                deviceWipe: deviceWipe
            )
            step = .done
        } catch is AccountDeletion.HandOffUnavailable {
            step = .failed("Another account on this device couldn\u{2019}t be opened, so nothing was deleted. Try again.")
        } catch {
            step = .failed("The iCloud backup couldn\u{2019}t be removed, so nothing on this device was deleted. Check that iCloud is signed in and try again.")
        }
    }
}

struct DeleteAccountView: View {
    let keypair: Keypair
    let walletStore: WalletStore?
    let onDeleted: (Keypair?) -> Void

    @Environment(\.theme) private var theme
    @State private var model: DeleteAccountViewModel
    @State private var showKeys = false
    @State private var showRecoveryPhrase = false
    @State private var typed = ""
    @State private var pin = ""

    init(keypair: Keypair, walletStore: WalletStore?, onDeleted: @escaping (Keypair?) -> Void) {
        self.keypair = keypair
        self.walletStore = walletStore
        self.onDeleted = onDeleted
        _model = State(initialValue: DeleteAccountViewModel(keypair: keypair))
    }

    /// Mid-request, mid-wipe, or wiped: no way back out but the buttons.
    private var isLocked: Bool {
        switch model.step {
        case .requesting, .deleting, .done: return true
        default: return false
        }
    }

    private var npub: String {
        Hex.decode(keypair.pubkey).flatMap { Nip19.npubEncode(pubkey: Array($0)) } ?? keypair.pubkey
    }

    /// The Spark seed is real money; offered only when this account has one.
    private var hasSparkWallet: Bool {
        WalletKeychain.loadSparkMnemonic(for: keypair.pubkey) != nil
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                content
            }
            .padding(20)
        }
        .background(theme.palette.background.ignoresSafeArea())
        .navigationTitle("Delete Account")
        .navigationBarTitleDisplayMode(.inline)
        .interactiveDismissDisabled(isLocked)
        .navigationBarBackButtonHidden(isLocked)
        .task { await model.loadMembership() }
        .sheet(isPresented: $showKeys) {
            NavigationStack { KeysSettingsView(keypair: keypair) }
        }
        .sheet(isPresented: $showRecoveryPhrase) {
            if let walletStore {
                NavigationStack { RecoveryPhraseView(store: walletStore) }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.step {
        case .explain:
            explainStep
        case .checkingICloud:
            progress("Checking iCloud for a backup of this account\u{2026}")
        case .iCloudUnavailable:
            iCloudUnavailableStep
        case .needsApple(let count):
            needsAppleStep(count: count)
        case .signingIn:
            progress("Signing in with Apple\u{2026}")
        case .enterPin(let failed):
            pinStep(attemptFailed: failed)
        case .matching:
            progress("Finding this account\u{2019}s backup\u{2026}")
        case .forgotPin(let count):
            forgotPinStep(count: count)
        case .confirmMatched(let count):
            confirmMatchedStep(count: count)
        case .confirmTyped:
            confirmTypedStep
        case .requesting:
            progress("Sending your deletion request\u{2026}")
        case .requestFailed:
            requestFailedStep
        case .deleting:
            progress("Deleting\u{2026}")
        case .failed(let message):
            failedStep(message)
        case .done:
            doneStep
        }
    }

    // MARK: - Step 1: what this does

    @ViewBuilder
    private var explainStep: some View {
        section(title: "What gets deleted") {
            bullet("Your private key on this device.")
            bullet("This account\u{2019}s iCloud Keychain backup, so Continue with Apple can no longer restore it.")
            bullet("This account\u{2019}s settings, cached posts and messages, and wallet keys on this device.")
            if !keypair.isWatchOnly {
                bullet("Records Zap Cooking holds for this account \u{2014} Cook+ membership, AI credits, scheduled posts, and content on Pantry, our relay. We send a deletion request: scheduled posts go right away, the rest within 30 days. Payment records we\u{2019}re required by law to keep are kept.")
            }
            Text("After this, no one \u{2014} including Zap Cooking \u{2014} can recover this account. The only way back is a copy of your private key (nsec) that you save before you delete.")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(theme.palette.onSurface)
        }

        section(title: "What we can\u{2019}t delete") {
            Text("Everything you\u{2019}ve already published \u{2014} recipes, posts, comments, reactions, zaps \u{2014} went to public Nostr relays that Zap Cooking doesn\u{2019}t run. Like a published blog post, it stays public. Deleting your account here doesn\u{2019}t remove it.")
                .font(.system(size: 14))
                .foregroundStyle(theme.palette.onSurface)
        }

        cookPlusSection

        exportSection

        Button {
            model.beginBackupCheck()
        } label: {
            Text("Continue").frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .tint(.red)
        .controlSize(.large)
        .accessibilityIdentifier("delete-account-continue")
    }

    @ViewBuilder
    private var cookPlusSection: some View {
        switch model.cookPlus {
        case .none:
            EmptyView()
        case .card:
            section(title: "Cook+ is separate") {
                Text("Your Cook+ membership is billed separately. Deleting asks Zap Cooking to stop its renewal \u{2014} you keep access until the current period ends. The last screen tells you whether the renewal was stopped.")
                    .font(.system(size: 14))
                    .foregroundStyle(theme.palette.onSurface)
            }
        case .lightning:
            section(title: "Cook+ is separate") {
                Text("Your Cook+ membership was paid with Lightning for one term. It doesn\u{2019}t renew, so there\u{2019}s nothing to cancel.")
                    .font(.system(size: 14))
                    .foregroundStyle(theme.palette.onSurface)
            }
        case .other:
            section(title: "Cook+ is separate") {
                Text("Your Cook+ membership is managed separately. Your deletion request covers the membership record, but if it renews, manage it at zap.cooking/membership before you delete \u{2014} once your key is gone you can\u{2019}t sign in there.")
                    .font(.system(size: 14))
                    .foregroundStyle(theme.palette.onSurface)
            }
        }
    }

    /// Offered on the first screen and again on every confirmation screen:
    /// saving the key is the easy way out of this flow, never a buried one.
    @ViewBuilder
    private var exportSection: some View {
        if !keypair.isWatchOnly {
            section(title: "Save first") {
                Text(hasSparkWallet
                     ? "Your private key is the only way to use this identity again, anywhere. Your recovery phrase is the only way to reach your wallet\u{2019}s funds."
                     : "Your private key is the only way to use this identity again, anywhere.")
                    .font(.system(size: 14))
                    .foregroundStyle(theme.palette.onSurface)
                exportButton("Export private key (nsec)", icon: "key", id: "delete-account-export-nsec") {
                    showKeys = true
                }
                if hasSparkWallet, walletStore != nil {
                    exportButton("Export wallet recovery phrase", icon: "list.number", id: "delete-account-export-phrase") {
                        showRecoveryPhrase = true
                    }
                }
            }
        }
    }

    // MARK: - Step 2: iCloud backup

    @ViewBuilder
    private var iCloudUnavailableStep: some View {
        section(title: "iCloud isn\u{2019}t available") {
            Text("Zap Cooking can\u{2019}t reach iCloud on this device, so it can\u{2019}t remove an iCloud backup of this account. If you created this account with Continue with Apple, sign in to iCloud in Settings and try again \u{2014} otherwise that backup stays and can restore this account.")
                .font(.system(size: 14))
                .foregroundStyle(theme.palette.onSurface)
        }
        primaryButton("Try again") { model.beginBackupCheck() }
        Button("Continue without removing an iCloud backup") { model.skipICloud() }
            .font(.system(size: 14))
            .foregroundStyle(.red)
            .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func needsAppleStep(count: Int) -> some View {
        section(title: "Find this account\u{2019}s backup") {
            Text(count == 1
                 ? "There\u{2019}s 1 Zap Cooking backup in this iCloud account. To check whether it\u{2019}s this account\u{2019}s, sign in with Apple and enter your recovery PIN."
                 : "There are \(count) Zap Cooking backups in this iCloud account. To find the one for this account, sign in with Apple and enter your recovery PIN.")
                .font(.system(size: 14))
                .foregroundStyle(theme.palette.onSurface)
        }
        primaryButton("Continue with Apple") { model.signInWithApple() }
            .accessibilityIdentifier("delete-account-apple")
    }

    @ViewBuilder
    private func pinStep(attemptFailed: Bool) -> some View {
        section(title: "Enter your recovery PIN") {
            Text("The PIN you set when you first used Continue with Apple.")
                .font(.system(size: 14))
                .foregroundStyle(theme.palette.onSurfaceVariant)
            AuthFlowPinField(
                pin: $pin,
                errorText: attemptFailed ? "Incorrect PIN. Try again." : nil,
                onSubmit: { submitPin() }
            )
        }
        primaryButton("Find backup") { submitPin() }
            .disabled(!BackupCrypto.isValidPin(pin))
        Button("Forgot PIN?") { model.forgotPin() }
            .font(.system(size: 14))
            .foregroundStyle(theme.palette.onSurfaceVariant)
            .frame(maxWidth: .infinity)
    }

    private func submitPin() {
        let entered = pin
        pin = ""
        model.submitPin(entered)
    }

    @ViewBuilder
    private func forgotPinStep(count: Int) -> some View {
        section(title: "Without your PIN") {
            Text("Without your PIN, Zap Cooking can\u{2019}t tell which backup is this account\u{2019}s. The only way to remove it is to remove all of them.")
                .font(.system(size: 14))
                .foregroundStyle(theme.palette.onSurface)
            Text(count == 1
                 ? "This removes the 1 Zap Cooking backup in this iCloud account, including any other identity it holds."
                 : "This removes all \(count) Zap Cooking backups in this iCloud account, including any other identities.")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.red)
        }
        Button {
            model.removeAllBackups()
        } label: {
            Text(count == 1 ? "Remove the backup" : "Remove all \(count) backups").frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .tint(.red)
        .controlSize(.large)
        Button("Back") { model.backToApple() }
            .font(.system(size: 14))
            .foregroundStyle(theme.palette.onSurfaceVariant)
            .frame(maxWidth: .infinity)
    }

    // MARK: - Step 3: confirm

    @ViewBuilder
    private func confirmMatchedStep(count: Int) -> some View {
        section(title: "Ready to delete") {
            Text(count == 1
                 ? "Found this account\u{2019}s iCloud backup. Deleting removes it, your key on this device, and this account\u{2019}s data here. This can\u{2019}t be undone."
                 : "Found \(count) iCloud backups of this account. Deleting removes them, your key on this device, and this account\u{2019}s data here. This can\u{2019}t be undone.")
                .font(.system(size: 14))
                .foregroundStyle(theme.palette.onSurface)
        }
        exportSection
        deleteButton(enabled: true)
    }

    @ViewBuilder
    private var confirmTypedStep: some View {
        section(title: "Confirm") {
            Text(backupNoteText)
                .font(.system(size: 14))
                .foregroundStyle(theme.palette.onSurface)
            Text("This can\u{2019}t be undone. Type \(DeleteAccountViewModel.confirmationWord) to confirm.")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(theme.palette.onSurface)
            TextField(DeleteAccountViewModel.confirmationWord, text: $typed)
                .textInputAutocapitalization(.characters)
                .autocorrectionDisabled()
                .padding(12)
                .background(theme.palette.surfaceVariant.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
                .accessibilityIdentifier("delete-account-typed")
        }
        exportSection
        deleteButton(enabled: typed.trimmingCharacters(in: .whitespaces) == DeleteAccountViewModel.confirmationWord)
    }

    private var backupNoteText: String {
        switch model.backupNote {
        case .none, .noBackups:
            return "There\u{2019}s no Zap Cooking backup in this iCloud account. Deleting removes your key on this device and this account\u{2019}s data here."
        case .noneForThisAccount:
            return "None of the backups in this iCloud account is this account, so none will be removed. Deleting removes your key on this device and this account\u{2019}s data here."
        case .removingAll(let count):
            return count == 1
                ? "Deleting removes the 1 Zap Cooking backup in this iCloud account, including any other identity it holds, plus your key on this device and this account\u{2019}s data here."
                : "Deleting removes all \(count) Zap Cooking backups in this iCloud account, including any other identities, plus your key on this device and this account\u{2019}s data here."
        case .iCloudSkipped:
            return "Any iCloud backup of this account stays in iCloud and can still restore it. Deleting removes your key on this device and this account\u{2019}s data here."
        }
    }

    private func deleteButton(enabled: Bool) -> some View {
        Button {
            Task { await model.confirm() }
        } label: {
            Text("Delete account permanently").frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(.red)
        .controlSize(.large)
        .disabled(!enabled)
        .accessibilityIdentifier("delete-account-confirm")
    }

    @ViewBuilder
    private var requestFailedStep: some View {
        section(title: "Request not sent") {
            Text("Zap Cooking didn\u{2019}t receive your deletion request. Nothing has been deleted yet.")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(theme.palette.onSurface)
            Text("You can try again, or delete from this device anyway. If you do, records Zap Cooking holds for this account (Cook+ membership, AI credits, content on Pantry) aren\u{2019}t queued for removal \u{2014} to ask later, email support@zap.cooking with this account\u{2019}s npub:")
                .font(.system(size: 14))
                .foregroundStyle(theme.palette.onSurface)
            Text(npub)
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .foregroundStyle(theme.palette.onSurfaceVariant)
        }
        primaryButton("Try again") { Task { await model.confirm() } }
        Button("Delete from this device anyway") { Task { await model.deleteWithoutRequest() } }
            .font(.system(size: 14))
            .foregroundStyle(.red)
            .frame(maxWidth: .infinity)
            .accessibilityIdentifier("delete-account-without-request")
        exportSection
    }

    @ViewBuilder
    private var doneStep: some View {
        section(title: "Account deleted") {
            Text(model.pendingBackupIDs.isEmpty
                 ? "Your key and this account\u{2019}s data are gone from this device."
                 : "Your key, its iCloud backup, and this account\u{2019}s data are gone from this device.")
                .font(.system(size: 14))
                .foregroundStyle(theme.palette.onSurface)
            if let receipt = model.receipt {
                Text("Zap Cooking has your deletion request. Records we hold for this account are removed within 30 days.")
                    .font(.system(size: 14))
                    .foregroundStyle(theme.palette.onSurface)
                if let line = billingLine(receipt.billing) {
                    Text(line)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(theme.palette.onSurface)
                }
            } else if model.requestSkipped {
                Text("Zap Cooking didn\u{2019}t receive a deletion request, so records we hold for this account aren\u{2019}t queued for removal. To ask, email support@zap.cooking with this npub:")
                    .font(.system(size: 14))
                    .foregroundStyle(theme.palette.onSurface)
                Text(npub)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .foregroundStyle(theme.palette.onSurfaceVariant)
            }
            Text("Anything already published to public relays stays there.")
                .font(.system(size: 14))
                .foregroundStyle(theme.palette.onSurfaceVariant)
        }
        primaryButton("Done") { onDeleted(model.handedOffTo) }
            .accessibilityIdentifier("delete-account-done")
    }

    /// The Cook+ result line. Silent for non-members unless the server
    /// actually stopped a renewal.
    private func billingLine(_ billing: DeletionRequestReceipt.Billing) -> String? {
        if billing == .cancelled {
            return "Your Cook+ renewal is stopped. You keep access until the current period ends."
        }
        guard model.cookPlus == .card else { return nil }
        return "Your Cook+ renewal couldn\u{2019}t be stopped automatically. It\u{2019}s part of your deletion request for Zap Cooking staff to handle \u{2014} if you\u{2019}re charged again, contact support@zap.cooking."
    }

    @ViewBuilder
    private func failedStep(_ message: String) -> some View {
        section(title: "Not deleted") {
            Text(message)
                .font(.system(size: 14))
                .foregroundStyle(theme.palette.onSurface)
        }
        primaryButton("Start over") { model.beginBackupCheck() }
    }

    // MARK: - Pieces

    private func progress(_ label: String) -> some View {
        HStack(spacing: 10) {
            ProgressView()
            Text(label)
                .font(.system(size: 14))
                .foregroundStyle(theme.palette.onSurfaceVariant)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\u{2022}")
            Text(text)
        }
        .font(.system(size: 14))
        .foregroundStyle(theme.palette.onSurface)
    }

    private func primaryButton(_ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(.wispPrimary)
        .controlSize(.large)
    }

    private func exportButton(_ label: String, icon: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Label(label, systemImage: icon)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
            }
            .font(.system(size: 15, weight: .medium))
            .padding(.vertical, 12)
            .padding(.horizontal, 14)
            .background(Color.wispPrimary.opacity(0.14), in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(theme.palette.onSurface)
        .accessibilityIdentifier(id)
    }

    @ViewBuilder
    private func section<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.palette.onSurfaceVariant)
                .textCase(.uppercase)
            VStack(alignment: .leading, spacing: 12) {
                content()
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.palette.surface)
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }
}
