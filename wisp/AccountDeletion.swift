import Foundation
import Security

// MARK: - Seams

/// The iCloud-Keychain backup store as the deletion flow sees it. The
/// production store is `KeychainBackupService`, unchanged; the protocol exists
/// so tests can stand in for a keychain that needs a signed-in iCloud account.
protocol ICloudBackupStore {
    func listBackups() async throws -> [KeychainBackupService.BackupFile]
    func deleteBackup(backupID: String) async throws
}

extension KeychainBackupService: ICloudBackupStore {}

/// The full device wipe the single-account path ends with. Production is
/// `AppDataWipe.wipeEverything()`; tests substitute a recorder so a unit run
/// does not empty the test host's ObjectBox and UserDefaults.
protocol DeviceWipe {
    func wipeEverything() async
}

struct AppDataDeviceWipe: DeviceWipe {
    func wipeEverything() async { await AppDataWipe.wipeEverything() }
}

// MARK: - Account deletion

/// Settings → About → Delete Account (Guideline 5.1.1(v)).
///
/// Deliberately separate from the drawer's Logout, which removes an account
/// from this device and leaves its iCloud-Keychain backup in place so
/// Continue with Apple can bring it back. Deletion removes that backup too:
/// with no local key and no backup the identity is gone for good unless the
/// user exported the nsec first.
///
/// Order is load-bearing. Backups go first — if iCloud refuses, nothing
/// local has been touched and the user can retry. The local wipe then
/// always clears the `active` keychain item: keychain items survive deleting
/// the app, and `ContentView` logs in from `NostrKey.load()` on launch, so a
/// leftover `active` would log a reinstalling user straight back in with no
/// iCloud involved at all.
enum AccountDeletion {

    /// What the PIN step learned about the backups in this iCloud account.
    enum BackupMatch: Equatable {
        /// These backups decrypt to the account being deleted.
        case matched([String])
        /// The PIN decrypts backups here, but none of them is this account
        /// (an nsec-imported account on an Apple ID that backs up others).
        case noneForThisAccount
        /// Nothing decrypted — a wrong PIN, or backups from another Apple ID.
        case wrongPin
    }

    /// Decrypts each backup with `key32` and keeps the ones whose key derives
    /// `pubkeyHex`. Same decrypt-and-derive the restore flow uses, so a
    /// backup this finds is exactly a backup restore would offer.
    nonisolated static func match(
        files: [KeychainBackupService.BackupFile],
        key32: Data,
        pubkeyHex: String
    ) -> BackupMatch {
        var decryptedAny = false
        var ids: [String] = []
        for file in files {
            guard let nsec = try? BackupCrypto.decryptNsec(payload: file.payload, key32: key32),
                  let pubkey = try? Schnorr.xonlyPubkey(privkey32: nsec) else { continue }
            decryptedAny = true
            if Hex.encode(pubkey).lowercased() == pubkeyHex.lowercased() {
                ids.append(file.backupID)
            }
        }
        if !ids.isEmpty { return .matched(ids) }
        return decryptedAny ? .noneForThisAccount : .wrongPin
    }

    /// Deletes the account `pubkey`: the given iCloud backups, then this
    /// device's copy. With `handOffTo` set (another saved account exists),
    /// only this account's state is removed and the app switches to that
    /// account, whose keypair is returned. Without it, the whole device is
    /// wiped (`AppDataWipe`) and nil is returned — the caller logs out.
    ///
    /// Throws before any local change if a backup delete fails.
    @discardableResult
    static func delete(
        pubkey: String,
        backupIDs: [String],
        handOffTo next: String?,
        backups: ICloudBackupStore,
        deviceWipe: DeviceWipe
    ) async throws -> Keypair? {
        for id in backupIDs {
            try await backups.deleteBackup(backupID: id)
        }

        if let next, let nextKeypair = NostrKey.switchAccount(pubkey: next) {
            await clearAccount(pubkey: pubkey)
            return nextKeypair
        }

        clearKeychain(pubkey: pubkey)
        NostrKey.delete()
        await deviceWipe.wipeEverything()
        return nil
    }

    // MARK: - Local pieces

    /// Every `com.wisp.nostr` item that belongs to `pubkey`. `NostrKey
    /// .deleteAccount` stays as the switcher uses it; the wallet secrets it
    /// does not know about are removed here. `active` is not touched — the
    /// caller decides whether it points at this account.
    static func clearKeychain(pubkey: String) {
        NostrKey.deleteAccount(pubkey: pubkey)
        WalletKeychain.deleteSparkMnemonic(for: pubkey)
        WalletKeychain.deleteNwcUri(for: pubkey)
    }

    /// This account's state on a device that keeps other accounts.
    static func clearAccount(pubkey: String) async {
        clearKeychain(pubkey: pubkey)
        sweepDefaults(pubkey: pubkey)
        removeSocialGraphFiles(pubkey: pubkey)
        await DmStore.shared.deleteAllForOwner(pubkey)
        await GroupStore.shared.wipe(ownerPubkey: pubkey)
        await EventStore.shared.removeByAuthor(pubkey)
        FollowsCache.shared.invalidate(pubkey: pubkey)
    }

    /// Removes every UserDefaults key ending in `_<pubkey>`. A suffix sweep
    /// instead of a list: the codebase has ~75 per-account keys and a list
    /// is stale the day someone adds one.
    static func sweepDefaults(pubkey: String, defaults: UserDefaults = .standard) {
        let suffix = "_\(pubkey)"
        for key in defaults.dictionaryRepresentation().keys where key.hasSuffix(suffix) {
            defaults.removeObject(forKey: key)
        }
    }

    /// `Application Support/wisp/social_graph_<pubkey>.db` and its WAL/SHM
    /// siblings.
    static func removeSocialGraphFiles(pubkey: String) {
        let fm = FileManager.default
        guard let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let dir = support.appendingPathComponent("wisp", isDirectory: true)
        let base = "social_graph_\(pubkey).db"
        for name in [base, base + "-wal", base + "-shm"] {
            try? fm.removeItem(at: dir.appendingPathComponent(name))
        }
    }
}

// MARK: - Cook+ billing

/// Where a member cancels Cook+, decided before anything is wiped (the web
/// needs a request signed by this key, which is about to be gone).
enum CookPlusCancellation: Equatable {
    /// Not a member, or membership could not be read — no block is shown.
    case none
    /// Card member: the Stripe billing portal is where cancellation happens.
    case card
    /// Lightning member: one paid term, nothing renews.
    case lightning
    /// Active member whose payment method this app doesn't recognise.
    case other

    init(status: MembershipStatus) {
        guard status.owner, status.isActive else { self = .none; return }
        let method = status.member?.paymentMethod?.lowercased() ?? ""
        if method == "stripe" {
            self = .card
        } else if method.hasPrefix("lightning") || method == "bitcoin" {
            self = .lightning
        } else {
            self = .other
        }
    }
}

extension ZapCookingApi {
    /// `POST /api/stripe/create-portal-session` — NIP-98 signed by the member.
    /// Returns the Stripe-hosted billing portal URL (cancel, invoices, card).
    /// The portal shows no pricing, which is why iOS may open it while
    /// `FeatureFlags.membershipLinkoutEnabled` stays false. 404 means there
    /// is no Stripe customer for this key.
    static func createBillingPortalSession(signer: Nip98Signing) async throws -> URL {
        let body = encodeJSON(PortalSessionRequest(pubkey: signer.pubkeyHex, returnUrl: "\(baseURL.absoluteString)/"))
        let (status, data) = try await authedPost(
            signer: signer,
            path: "api/stripe/create-portal-session",
            body: body,
            client: HttpClientFactory.generalClient,
            isUnauthorized: { response, _ in response.statusCode == 403 }
        )
        try throwErrorIfNeeded(status: status.statusCode, body: data)
        let response = try decode(data, as: PortalSessionResponse.self)
        guard let url = URL(string: response.url), url.scheme == "https" else {
            throw ZapCookingApiError.decoding("portal url")
        }
        return url
    }
}

private struct PortalSessionRequest: Encodable {
    let pubkey: String
    let returnUrl: String
}

private struct PortalSessionResponse: Decodable {
    let url: String
}
