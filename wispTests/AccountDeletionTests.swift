import Foundation
import Security
import Testing
@testable import wisp

/// Settings → About → Delete Account. The property under test is the one a
/// reviewer checks by hand: after deletion nothing can bring the identity
/// back — no `com.wisp.nostr` item for it (including `active`, which
/// `ContentView` logs in from on launch and which survives deleting the app),
/// and no `com.wisp.apple-backup` item that decrypts to it.
@MainActor
@Suite(.serialized)
struct AccountDeletionTests {

    // MARK: - Fakes

    /// Shared call log, to check the order of the three steps.
    final class Log { var entries: [String] = [] }

    /// In-memory stand-in for the iCloud-Keychain backup store (the real
    /// one refuses without a signed-in iCloud account).
    final class FakeBackups: ICloudBackupStore {
        var files: [KeychainBackupService.BackupFile]
        var deleted: [String] = []
        var failDeletes = false
        var log: Log?

        init(_ files: [KeychainBackupService.BackupFile], log: Log? = nil) {
            self.files = files
            self.log = log
        }

        func listBackups() async throws -> [KeychainBackupService.BackupFile] { files }

        func deleteBackup(backupID: String) async throws {
            if failDeletes { throw KeychainBackupError(kind: .underlying(errSecIO), op: "delete") }
            log?.entries.append("backup")
            deleted.append(backupID)
            files.removeAll { $0.backupID == backupID }
        }
    }

    final class RecordingWipe: DeviceWipe {
        var calls = 0
        var log: Log?
        init(log: Log? = nil) { self.log = log }
        func wipeEverything() async {
            log?.entries.append("wipe")
            calls += 1
        }
    }

    final class FakeRequester: DeletionRequestSender {
        var fail: Bool
        var calls = 0
        var log: Log?
        init(fail: Bool = false, log: Log? = nil) {
            self.fail = fail
            self.log = log
        }
        func send(keypair: Keypair) async throws -> DeletionRequestReceipt {
            calls += 1
            // The request must be signed while the key still exists.
            #expect(NostrKey.loadAccount(pubkey: keypair.pubkey) != nil)
            log?.entries.append("request")
            if fail { throw ZapCookingApiError.requestFailed(status: 500, body: nil) }
            return DeletionRequestReceipt(status: "pending", billing: .cancelled, scheduledPostsRemoved: 0)
        }
    }

    // MARK: - Helpers

    private static let appleUserID = "001234.deletion.5678"
    private static let pin = "2468"

    private func newKeypair() throws -> Keypair {
        let priv = Schnorr.randomPrivkey()
        let pub = try Schnorr.xonlyPubkey(privkey32: priv)
        return Keypair(privkey: Hex.encode(priv), pubkey: Hex.encode(pub))
    }

    private func backup(of keypair: Keypair, key: Data) throws -> KeychainBackupService.BackupFile {
        let payload = try BackupCrypto.encryptNsec(nsec32: Hex.decode(keypair.privkey)!, key32: key)
        return .init(backupID: "wisp_bk_\(UUID().uuidString.lowercased())", payload: payload)
    }

    /// Every account name under `com.wisp.nostr` in this keychain.
    private func nostrKeychainAccounts() -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.wisp.nostr",
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let items = result as? [[String: Any]] else { return [] }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }
    }

    /// Seeds everything a real account leaves under `com.wisp.nostr` and in
    /// UserDefaults.
    private func seed(_ kp: Keypair) {
        NostrKey.save(kp)
        WalletKeychain.saveSparkMnemonic("abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about", for: kp.pubkey)
        WalletKeychain.saveNwcUri("nostr+walletconnect://x?relay=wss://r&secret=00", for: kp.pubkey)
        for key in ["onboarding_done_", "profile_", "wallet_mode_", "relay_settings_general_", "wisp_settings_quick_zap_enabled_"] {
            UserDefaults.standard.set(true, forKey: key + kp.pubkey)
        }
    }

    /// Leave the test host as found.
    private func restore(accounts: [String], active: Keypair?) {
        UserDefaults.standard.set(accounts, forKey: "wisp_accounts")
        if let active { _ = NostrKey.switchAccount(pubkey: active.pubkey) }
    }

    // MARK: - Matching

    @Test func match_findsOnlyThisAccountsBackups() throws {
        let key = try BackupCrypto.deriveBackupKey(appleUserID: Self.appleUserID, pin: Self.pin)
        let mine = try newKeypair(), other = try newKeypair()
        let a = try backup(of: mine, key: key), b = try backup(of: other, key: key), c = try backup(of: mine, key: key)

        #expect(AccountDeletion.match(files: [a, b, c], key32: key, pubkeyHex: mine.pubkey) == .matched([a.backupID, c.backupID]))
        #expect(AccountDeletion.match(files: [b], key32: key, pubkeyHex: mine.pubkey) == .noneForThisAccount)

        let wrong = try BackupCrypto.deriveBackupKey(appleUserID: Self.appleUserID, pin: "1357")
        #expect(AccountDeletion.match(files: [a, b], key32: wrong, pubkeyHex: mine.pubkey) == .wrongPin)
    }

    // MARK: - Single account: full wipe

    @Test func singleAccount_clearsBothKeychainServicesIncludingActive() async throws {
        let priorAccounts = NostrKey.accounts()
        let priorActive = NostrKey.load()
        defer { restore(accounts: priorAccounts, active: priorActive) }

        let key = try BackupCrypto.deriveBackupKey(appleUserID: Self.appleUserID, pin: Self.pin)
        let kp = try newKeypair(), someoneElse = try newKeypair()
        seed(kp)
        UserDefaults.standard.set([kp.pubkey], forKey: "wisp_accounts")
        let mine = try backup(of: kp, key: key), theirs = try backup(of: someoneElse, key: key)
        let store = FakeBackups([mine, theirs])
        let wipe = RecordingWipe()

        #expect(nostrKeychainAccounts().contains("active"))
        guard case .matched(let ids) = AccountDeletion.match(files: store.files, key32: key, pubkeyHex: kp.pubkey) else {
            Issue.record("backup not matched"); return
        }

        let next = try await AccountDeletion.delete(
            pubkey: kp.pubkey, backupIDs: ids, handOffTo: nil, backups: store, deviceWipe: wipe
        )

        #expect(next == nil)
        #expect(wipe.calls == 1)
        // com.wisp.apple-backup: nothing left that decrypts to this pubkey,
        // and another identity's backup is untouched.
        #expect(store.deleted == [mine.backupID])
        #expect(AccountDeletion.match(files: store.files, key32: key, pubkeyHex: kp.pubkey) == .noneForThisAccount)
        #expect(store.files == [theirs])
        // com.wisp.nostr: no `active`, nothing named for this pubkey — even
        // with the full wipe stubbed out.
        let left = nostrKeychainAccounts()
        #expect(!left.contains("active"))
        #expect(left.allSatisfy { !$0.contains(kp.pubkey) })
        #expect(NostrKey.load() == nil)

        AccountDeletion.sweepDefaults(pubkey: kp.pubkey)   // the stubbed wipe's job
    }

    @Test func failedBackupDelete_leavesTheDeviceUntouched() async throws {
        let priorAccounts = NostrKey.accounts()
        let priorActive = NostrKey.load()
        defer { restore(accounts: priorAccounts, active: priorActive) }

        let key = try BackupCrypto.deriveBackupKey(appleUserID: Self.appleUserID, pin: Self.pin)
        let kp = try newKeypair()
        seed(kp)
        let store = FakeBackups([try backup(of: kp, key: key)])
        store.failDeletes = true
        let wipe = RecordingWipe()

        await #expect(throws: KeychainBackupError.self) {
            try await AccountDeletion.delete(
                pubkey: kp.pubkey, backupIDs: store.files.map(\.backupID), handOffTo: nil,
                backups: store, deviceWipe: wipe
            )
        }
        #expect(wipe.calls == 0)
        #expect(NostrKey.loadAccount(pubkey: kp.pubkey) != nil)
        #expect(nostrKeychainAccounts().contains("active"))

        AccountDeletion.clearKeychain(pubkey: kp.pubkey)
        NostrKey.delete()
        AccountDeletion.sweepDefaults(pubkey: kp.pubkey)
    }

    // MARK: - Several accounts: targeted wipe + hand-off

    @Test func multiAccount_removesOnlyThisAccount_andHandsOff() async throws {
        let priorAccounts = NostrKey.accounts()
        let priorActive = NostrKey.load()
        let doomed = try newKeypair(), keeper = try newKeypair()
        defer {
            AccountDeletion.clearKeychain(pubkey: keeper.pubkey)
            AccountDeletion.sweepDefaults(pubkey: keeper.pubkey)
            NostrKey.delete()
            restore(accounts: priorAccounts, active: priorActive)
        }

        seed(keeper)
        seed(doomed)                       // active = doomed
        let key = try BackupCrypto.deriveBackupKey(appleUserID: Self.appleUserID, pin: Self.pin)
        let store = FakeBackups([try backup(of: doomed, key: key), try backup(of: keeper, key: key)])
        let wipe = RecordingWipe()

        // A social-graph db for the doomed account.
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("wisp", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let db = dir.appendingPathComponent("social_graph_\(doomed.pubkey).db")
        FileManager.default.createFile(atPath: db.path, contents: Data())

        guard case .matched(let ids) = AccountDeletion.match(files: store.files, key32: key, pubkeyHex: doomed.pubkey) else {
            Issue.record("backup not matched"); return
        }
        let next = try await AccountDeletion.delete(
            pubkey: doomed.pubkey, backupIDs: ids, handOffTo: keeper.pubkey, backups: store, deviceWipe: wipe
        )

        #expect(next?.pubkey == keeper.pubkey)
        #expect(wipe.calls == 0)
        #expect(NostrKey.load()?.pubkey == keeper.pubkey)
        #expect(!NostrKey.accounts().contains(doomed.pubkey))
        #expect(NostrKey.accounts().contains(keeper.pubkey))

        let left = nostrKeychainAccounts()
        #expect(left.allSatisfy { !$0.contains(doomed.pubkey) })
        #expect(left.contains("account_\(keeper.pubkey)"))
        #expect(left.contains("spark_seed_\(keeper.pubkey)"))
        #expect(NostrKey.loadAccount(pubkey: keeper.pubkey) != nil)

        let defaults = UserDefaults.standard.dictionaryRepresentation().keys
        #expect(defaults.allSatisfy { !$0.hasSuffix("_\(doomed.pubkey)") })
        #expect(defaults.contains("wallet_mode_\(keeper.pubkey)"))

        #expect(!FileManager.default.fileExists(atPath: db.path))
        #expect(AccountDeletion.match(files: store.files, key32: key, pubkeyHex: doomed.pubkey) == .noneForThisAccount)
        #expect(AccountDeletion.match(files: store.files, key32: key, pubkeyHex: keeper.pubkey) != .noneForThisAccount)
    }

    @Test func staleHandOff_deletesNothing_andNeverWipesTheDevice() async throws {
        let priorAccounts = NostrKey.accounts()
        let priorActive = NostrKey.load()
        let doomed = try newKeypair(), ghost = try newKeypair()
        defer {
            AccountDeletion.clearKeychain(pubkey: doomed.pubkey)
            AccountDeletion.sweepDefaults(pubkey: doomed.pubkey)
            NostrKey.delete()
            restore(accounts: priorAccounts, active: priorActive)
        }

        seed(doomed)
        // Listed in `wisp_accounts` but with no keychain item behind it.
        NostrKey.registerInAccountList(ghost.pubkey)
        let key = try BackupCrypto.deriveBackupKey(appleUserID: Self.appleUserID, pin: Self.pin)
        let store = FakeBackups([try backup(of: doomed, key: key)])
        let wipe = RecordingWipe()

        await #expect(throws: AccountDeletion.HandOffUnavailable(pubkey: ghost.pubkey)) {
            try await AccountDeletion.delete(
                pubkey: doomed.pubkey, backupIDs: store.files.map(\.backupID), handOffTo: ghost.pubkey,
                backups: store, deviceWipe: wipe
            )
        }
        #expect(wipe.calls == 0)
        #expect(store.deleted.isEmpty)
        #expect(NostrKey.loadAccount(pubkey: doomed.pubkey) != nil)
        #expect(NostrKey.load()?.pubkey == doomed.pubkey)
    }

    // MARK: - Deletion request (view model)

    @Test func request_goesFirst_thenBackups_thenWipe() async throws {
        let priorAccounts = NostrKey.accounts()
        let priorActive = NostrKey.load()
        defer { restore(accounts: priorAccounts, active: priorActive) }

        let key = try BackupCrypto.deriveBackupKey(appleUserID: Self.appleUserID, pin: Self.pin)
        let kp = try newKeypair()
        seed(kp)
        UserDefaults.standard.set([kp.pubkey], forKey: "wisp_accounts")
        let log = Log()
        let store = FakeBackups([try backup(of: kp, key: key)], log: log)
        let requester = FakeRequester(log: log)
        let wipe = RecordingWipe(log: log)
        let model = DeleteAccountViewModel(keypair: kp, backups: store, requester: requester, deviceWipe: wipe)

        await model.checkBackups()
        #expect(model.step == .needsApple(count: 1))
        model.forgotPin()
        model.removeAllBackups()
        #expect(model.step == .confirmTyped)
        await model.confirm()

        #expect(log.entries == ["request", "backup", "wipe"])
        #expect(model.step == .done)
        #expect(model.receipt?.billing == .cancelled)
        #expect(model.handedOffTo == nil)
        #expect(!nostrKeychainAccounts().contains("active"))
        AccountDeletion.sweepDefaults(pubkey: kp.pubkey)
    }

    @Test func failedRequest_deletesNothing_untilTheUserChooses() async throws {
        let priorAccounts = NostrKey.accounts()
        let priorActive = NostrKey.load()
        defer { restore(accounts: priorAccounts, active: priorActive) }

        let kp = try newKeypair()
        seed(kp)
        UserDefaults.standard.set([kp.pubkey], forKey: "wisp_accounts")
        let requester = FakeRequester(fail: true)
        let wipe = RecordingWipe()
        let model = DeleteAccountViewModel(keypair: kp, backups: FakeBackups([]), requester: requester, deviceWipe: wipe)

        await model.checkBackups()
        #expect(model.step == .confirmTyped)
        await model.confirm()
        #expect(model.step == .requestFailed)
        #expect(wipe.calls == 0)
        #expect(NostrKey.loadAccount(pubkey: kp.pubkey) != nil)

        await model.confirm()                 // Try again — still failing
        #expect(requester.calls == 2)
        #expect(model.step == .requestFailed)

        await model.deleteWithoutRequest()
        #expect(model.step == .done)
        #expect(model.requestSkipped)
        #expect(model.receipt == nil)
        #expect(wipe.calls == 1)
        #expect(nostrKeychainAccounts().allSatisfy { $0 != "active" && !$0.contains(kp.pubkey) })
        AccountDeletion.sweepDefaults(pubkey: kp.pubkey)
    }

    @Test func receipt_decodesTheServerShape() throws {
        let json = #"{"status":"pending","requested_at":1790000000,"billing":"none","scheduled_posts_removed":2}"#
        let r = try JSONDecoder().decode(DeletionRequestReceipt.self, from: Data(json.utf8))
        #expect(r == DeletionRequestReceipt(status: "pending", billing: .none, scheduledPostsRemoved: 2))
        let odd = #"{"status":"pending","billing":"something-new"}"#
        #expect(try JSONDecoder().decode(DeletionRequestReceipt.self, from: Data(odd.utf8)).billing == .error)
    }

    // MARK: - Cook+

    @Test func cookPlus_cardOnlyForActiveStripeOwner() {
        func status(_ owner: Bool, _ active: Bool, _ method: String?) -> MembershipStatus {
            MembershipStatus(found: true, isActive: active, owner: owner,
                             member: .init(paymentMethod: method))
        }
        #expect(CookPlusCancellation(status: status(true, true, "stripe")) == .card)
        #expect(CookPlusCancellation(status: status(true, true, "lightning_strike")) == .lightning)
        #expect(CookPlusCancellation(status: status(true, true, "lightning")) == .lightning)
        #expect(CookPlusCancellation(status: status(true, true, nil)) == .other)
        #expect(CookPlusCancellation(status: status(true, false, "stripe")) == .none)
        #expect(CookPlusCancellation(status: status(false, true, "stripe")) == .none)
    }
}
