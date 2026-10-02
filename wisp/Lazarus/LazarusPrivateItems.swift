import Foundation

/// NIP-51 private items: a list can carry items encrypted to its author's own
/// key in `content` (NIP-44, or NIP-04 in older events) next to its public
/// tags. A private-only mute list has no public tags at all, so counting tags
/// alone reads a full list and an emptied one as the same zero. These helpers
/// size private items from the encrypted payload without decrypting, and
/// count them exactly once decrypted (spec "Private items").
nonisolated enum LazarusPrivateItems {

    nonisolated enum Encryption: Sendable, Equatable {
        case nip04
        case nip44
    }

    // NIP-44 v2 payload: version (1) + nonce (32) + [u16 length (2) + padded plaintext] + mac (32)
    static let nip44OverheadBytes = 67
    // The smallest payload holds 32 bytes of padded plaintext: 99 bytes, 132 base64 characters
    static let nip44MinPayloadChars = 132

    /// A private item is a JSON-encoded tag, most often ["p", <64-hex pubkey>]:
    /// 72 characters, plus a comma between items. Estimates assume that shape,
    /// so lists heavy on short words or hashtags hold more items than estimated.
    static let bytesPerItem = 73

    /// How a list's content is encrypted, or nil when it isn't (kind 3 relay
    /// JSON, an empty body, plain text).
    static func encryption(of content: String) -> Encryption? {
        let value = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        let parts = value.components(separatedBy: "?iv=")
        if parts.count >= 2 {
            return parts.count == 2 && isBase64(parts[0]) && isBase64(parts[1]) ? .nip04 : nil
        }
        return value.utf8.count >= nip44MinPayloadChars && isBase64(value) ? .nip44 : nil
    }

    /// `^[A-Za-z0-9+/]+={0,2}$`
    private static func isBase64(_ s: String) -> Bool {
        let bytes = Array(s.utf8)
        var end = bytes.count
        var padding = 0
        while end > 0, bytes[end - 1] == UInt8(ascii: "="), padding < 2 {
            end -= 1
            padding += 1
        }
        guard end > 0 else { return false }
        for b in bytes[0..<end] {
            switch b {
            case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "+"), UInt8(ascii: "/"):
                continue
            default:
                return false
            }
        }
        return true
    }

    private static func base64ByteLength(_ value: String) -> Int? {
        let length = value.utf8.count
        guard length % 4 == 0 else { return nil }
        let padding = value.hasSuffix("==") ? 2 : (value.hasSuffix("=") ? 1 : 0)
        return (length / 4) * 3 - padding
    }

    /// The range of plaintext lengths (bytes) an encrypted payload can hold,
    /// from its size alone.
    static func plaintextLengthRange(_ content: String) -> LazarusCountRange? {
        let value = content.trimmingCharacters(in: .whitespacesAndNewlines)
        switch encryption(of: value) {
        case .nip04:
            let cipherText = value.components(separatedBy: "?iv=")[0]
            // AES-CBC with PKCS#7 always adds 1–16 bytes of padding
            guard let bytes = base64ByteLength(cipherText), bytes > 0, bytes % 16 == 0 else { return nil }
            return LazarusCountRange(min: bytes - 16, max: bytes - 1)
        case .nip44:
            guard let bytes = base64ByteLength(value) else { return nil }
            let padded = bytes - nip44OverheadBytes
            guard padded >= 32, padded <= 65536, Nip44.calcPaddedLen(padded) == padded else { return nil }
            // The smallest plaintext that pads to this length
            var low = 1
            var high = padded
            while low < high {
                let mid = (low + high) / 2
                if Nip44.calcPaddedLen(mid) >= padded { high = mid } else { low = mid + 1 }
            }
            return LazarusCountRange(min: low, max: padded)
        case nil:
            return nil
        }
    }

    /// How many private items an encrypted payload holds, estimated from its size.
    static func estimate(_ content: String) -> LazarusCountRange? {
        guard let range = plaintextLengthRange(content) else { return nil }
        // A JSON array of n such tags is 73n + 1 bytes
        let minItems = Int((Double(range.min - 1) / Double(bytesPerItem)).rounded(.down))
        let maxItems = Int((Double(range.max - 1) / Double(bytesPerItem)).rounded(.up))
        return LazarusCountRange(min: Swift.max(minItems, 0), max: Swift.max(maxItems, 0))
    }

    /// Decrypted private items, or nil when the plaintext isn't a JSON array
    /// of string arrays (a kind 3's relay JSON, a profile blob).
    static func parseTags(_ plainText: String) -> [[String]]? {
        guard let data = plainText.data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return nil }
        var tags: [[String]] = []
        tags.reserveCapacity(array.count)
        for element in array {
            guard let tag = element as? [Any] else { return nil }
            var strings: [String] = []
            strings.reserveCapacity(tag.count)
            for item in tag {
                guard let s = item as? String else { return nil }
                strings.append(s)
            }
            tags.append(strings)
        }
        return tags
    }

    static func countItemTags(_ tags: [[String]], types: Set<String>) -> Int {
        tags.reduce(0) { n, tag in
            guard let name = tag.first, types.contains(name) else { return n }
            return n + 1
        }
    }
}

/// Decrypts private items encrypted to the account's own key. Signing is
/// local-key only in this app, so this is plain compute: no signer prompt,
/// and no NIP-46 request cap. Self-encryption means one conversation key
/// (NIP-44) and one shared secret (NIP-04) serve every version.
nonisolated struct LazarusDecryptor: Sendable {
    private let nip44Key: Data
    private let nip04Secret: Data
    let pubkey: String

    /// Nil for an account that can't decrypt (view-only, or a malformed key).
    init?(keypair: Keypair) {
        guard let priv = Hex.decode(keypair.privkey), priv.count == 32,
              let pub = Hex.decode(keypair.pubkey), pub.count == 32,
              let key = try? Nip44.getConversationKey(privkey32: priv, peerXonlyPubkey32: pub),
              let secret = try? Nip04.sharedSecret(privkey32: priv, peerXonlyPubkey32: pub) else { return nil }
        nip44Key = key
        nip04Secret = secret
        pubkey = keypair.pubkey
    }

    /// The version's decrypted private items, or nil when its content isn't
    /// encrypted, isn't the account's own, or doesn't decrypt to a tag list.
    func privateTags(of event: NostrEvent) -> [[String]]? {
        guard event.pubkey == pubkey,
              let encryption = LazarusPrivateItems.encryption(of: event.content) else { return nil }
        let payload = event.content.trimmingCharacters(in: .whitespacesAndNewlines)
        let plainText: String?
        switch encryption {
        case .nip44: plainText = try? Nip44.decrypt(payload: payload, conversationKey: nip44Key)
        case .nip04: plainText = try? Nip04.decrypt(payload, sharedSecret: nip04Secret)
        }
        return plainText.flatMap(LazarusPrivateItems.parseTags)
    }
}
