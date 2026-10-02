import Foundation

/// The app's own copies of the lists Lazarus recovers.
///
/// Three jobs, all spec-mandated:
///  - the relay list to scan and to confirm current on ("Scan" step 1: the
///    implementation's own copy of the newest kind 10002);
///  - this device's copy of the list for the re-read before signing
///    ("Recover": re-read from the local copy and the write relays);
///  - updating those copies after a restore, so the next edit in this app
///    builds on the restored version instead of the clobbered one.
///
/// This app keeps projections, not events: `FollowsCache` holds the followed
/// pubkeys, `MuteRepository` the muted pubkeys / words / threads,
/// `ProfileRepository` seven profile fields and the custom emoji, and
/// `RelaySettingsRepository` the parsed relay lists. A local copy is
/// therefore rebuilt as an unsigned stand-in event (`isLocalCopy`) that is
/// only ever compared and dated against, never published. Kinds 10003 and
/// 10044 have no copy in this app.
@MainActor
enum LazarusLocalCopies {

    /// The app's copy of the user's relay list, when it holds one.
    static func relayList(pubkey: String, standIns: [String]) -> LazarusUserRelays? {
        guard let snapshot = RelaySettingsRepository.shared.ownListSnapshot(
            kind: Nip51Lists.kindRelayList, pubkey: pubkey
        ) else { return nil }
        let stand = NostrEvent(
            id: "", pubkey: pubkey, kind: Nip51Lists.kindRelayList, createdAt: snapshot.createdAt,
            tags: snapshot.tags, content: "", sig: ""
        )
        let list = Lazarus.parseRelayList(stand)
        return Lazarus.userRelays(read: list.read, write: list.write, standIns: standIns)
    }

    /// This device's copy of a list as an unsigned stand-in event, or nil
    /// when the app holds none (or doesn't know which version it came from).
    static func snapshot(kind: Int, pubkey: String) -> NostrEvent? {
        let tags: [[String]]
        var content = ""
        let createdAt: Int
        switch kind {
        case 3:
            createdAt = FollowsCache.shared.storedCreatedAt(for: pubkey)
            tags = FollowsCache.shared.follows(for: pubkey).map { ["p", $0] }
        case Nip51Mute.kindMuteList:
            let mutes = MuteRepository.shared
            guard mutes.activePubkey == pubkey else { return nil }
            createdAt = mutes.lastUpdatedAt
            tags = mutes.blockedPubkeys.sorted().map { ["p", $0] }
                + mutes.mutedWords.sorted().map { ["word", $0] }
                + mutes.mutedThreads.sorted().map { ["e", $0] }
        case 0:
            let profiles = ProfileRepository.shared
            guard let profile = profiles.get(pubkey) else { return nil }
            createdAt = profiles.storedCreatedAt(pubkey)
            let fields: [String: String?] = [
                "name": profile.name, "display_name": profile.displayName, "about": profile.about,
                "picture": profile.picture, "banner": profile.banner, "nip05": profile.nip05,
                "lud16": profile.lud16,
            ]
            let object = fields.compactMapValues { $0 }
            if let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) {
                content = String(data: data, encoding: .utf8) ?? ""
            }
            tags = profile.emojiMap.keys.sorted().compactMap { code in
                profile.emojiMap[code].map { ["emoji", code, $0] }
            }
        case Nip51Lists.kindRelayList, Nip51Lists.kindDmRelays, Nip51Lists.kindBlockedRelays:
            guard let snapshot = RelaySettingsRepository.shared.ownListSnapshot(kind: kind, pubkey: pubkey) else {
                return nil
            }
            createdAt = snapshot.createdAt
            tags = snapshot.tags
        default:
            return nil
        }
        // A copy with no known version can't be newer than anything.
        guard createdAt > 0 else { return nil }
        return NostrEvent(
            id: localCopyPrefix + "\(kind)-\(createdAt)", pubkey: pubkey, kind: kind,
            createdAt: createdAt, tags: tags, content: content, sig: ""
        )
    }

    private static let localCopyPrefix = "local-"

    /// A stand-in built by `snapshot`, not a relay's signed event.
    static func isLocalCopy(_ event: NostrEvent) -> Bool {
        event.sig.isEmpty && event.id.hasPrefix(localCopyPrefix)
    }

    /// Update the app's own copy with a restored version. `privateTags` are
    /// the version's decrypted private items, which a mute list's local copy
    /// needs (it can't read NIP-04 content itself).
    static func adopt(_ signed: NostrEvent, privateTags: [[String]]?) async {
        switch signed.kind {
        case 3:
            let follows = signed.tags.compactMap { $0.count >= 2 && $0[0] == "p" ? $0[1] : nil }
            FollowsCache.shared.update(pubkey: signed.pubkey, follows: follows, createdAt: signed.createdAt)
        case Nip51Mute.kindMuteList:
            await MuteRepository.shared.adoptRecovered(event: signed, privateTags: privateTags)
        case 0:
            ProfileRepository.shared.updateFromEvent(signed)
            await EventStore.shared.persist([signed])
        case Nip51Lists.kindRelayList:
            RelaySettingsRepository.shared.ingestRecoveredList(signed)
            await EventStore.shared.persist([signed])
        case Nip51Lists.kindDmRelays, Nip51Lists.kindBlockedRelays:
            RelaySettingsRepository.shared.ingestRecoveredList(signed)
        default:
            // Bookmarks (10003) and encryption keys (10044): no local copy here.
            break
        }
    }
}
