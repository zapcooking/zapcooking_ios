import Foundation
import Security

/// This device's record of which iCloud-Keychain backups hold which account.
///
/// Backups are named `wisp_bk_<uuid>` so iCloud can't tie one to an npub, and
/// matching one to an account otherwise takes Apple sign-in plus the PIN to
/// decrypt it. But the app knows the pairing at the two moments a backup
/// meets an account — Continue with Apple creating one, and restoring one —
/// so it writes it down here, and Delete Account removes a recorded backup
/// without asking for Apple or the PIN.
///
/// Kept in its own keychain service, device-only and never synced: the record
/// lives as long as the backup does on this device. A logout's
/// `AppDataWipe` clears only `com.wisp.nostr` and UserDefaults, and the
/// backup survives a logout (Continue with Apple can bring the account back),
/// so the record has to survive it too — and reinstalls, like the backup.
/// No record does not mean no backup: an account restored on another device,
/// pasted as an nsec, or backed up before this record existed has none.
enum ICloudBackupIndex {
    private static let service = "com.wisp.apple-backup-index"

    /// The backup IDs recorded for `pubkey`, oldest first.
    static func backupIDs(for pubkey: String) -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: pubkey.lowercased(),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let text = String(data: data, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map(String.init)
    }

    /// Adds `ids` to `pubkey`'s record, keeping any already there.
    static func record(_ ids: [String], for pubkey: String) {
        var all = backupIDs(for: pubkey)
        for id in ids where !all.contains(id) { all.append(id) }
        guard !all.isEmpty, let data = all.joined(separator: "\n").data(using: .utf8) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: pubkey.lowercased(),
        ]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    /// After a restore: records every backup in `files` that decrypts to
    /// `pubkeyHex` under `key32`, not only the one chosen — the choose
    /// screen shows one row per npub, so duplicates hide behind it.
    static func recordRestored(
        files: [KeychainBackupService.BackupFile],
        key32: Data,
        pubkeyHex: String
    ) {
        if case .matched(let ids) = AccountDeletion.match(files: files, key32: key32, pubkeyHex: pubkeyHex) {
            record(ids, for: pubkeyHex)
        }
    }

    static func forget(pubkey: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: pubkey.lowercased(),
        ]
        SecItemDelete(query as CFDictionary)
    }
}
