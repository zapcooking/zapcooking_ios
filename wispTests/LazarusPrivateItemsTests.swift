import Foundation
import Testing
@testable import wisp

/// Lazarus private items (NIP-51): encryption detection, the size-based
/// estimate, exact counts once decrypted, and private items in the delta.
/// Sizing is pinned against real NIP-44 and NIP-04 ciphertexts produced by
/// this app's own `Nip44` / `Nip04`, the vectors of the spec's reference
/// suite (`private-items.spec.ts`) and the zap.cooking web suite.
struct LazarusPrivateItemsTests {

    private struct SelfKeys {
        let keypair: Keypair
        let nip44Key: Data
        let nip04Secret: Data

        init() throws {
            keypair = try LazarusFixture.keypair()
            let priv = Hex.decode(keypair.privkey)!
            let pub = Hex.decode(keypair.pubkey)!
            nip44Key = try Nip44.getConversationKey(privkey32: priv, peerXonlyPubkey32: pub)
            nip04Secret = try Nip04.sharedSecret(privkey32: priv, peerXonlyPubkey32: pub)
        }

        func nip44(_ tags: [[String]]) throws -> String {
            try Nip44.encrypt(plaintext: LazarusPrivateItemsTests.json(tags), conversationKey: nip44Key)
        }

        func nip04(_ tags: [[String]]) throws -> String {
            try Nip04.encrypt(LazarusPrivateItemsTests.json(tags), sharedSecret: nip04Secret)
        }

        /// A mute list whose items are all private: no tags, content encrypted to self.
        func privateMuteList(_ tags: [[String]], createdAt: Int) throws -> NostrEvent {
            LazarusFixture.event(kind: 10000, createdAt: createdAt, content: try nip44(tags), pubkey: keypair.pubkey)
        }
    }

    static func json(_ tags: [[String]]) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: tags), encoding: .utf8)!
    }

    /// `n` private follows of real 64-hex pubkeys, the shape the estimate assumes.
    static func privateTags(_ n: Int) -> [[String]] {
        (0..<n).map { _ in ["p", Hex.encode(Schnorr.randomPrivkey())] }
    }

    private let muteProfile = LazarusRegistry.profile(for: 10000)!

    // MARK: - Detection

    @Test func recognizesNip44AndNip04Payloads() throws {
        let keys = try SelfKeys()
        #expect(LazarusPrivateItems.encryption(of: try keys.nip44(Self.privateTags(3))) == .nip44)
        #expect(LazarusPrivateItems.encryption(of: try keys.nip04(Self.privateTags(3))) == .nip04)
    }

    @Test func doesNotTreatPlainContentAsEncrypted() {
        #expect(LazarusPrivateItems.encryption(of: "") == nil)
        #expect(LazarusPrivateItems.encryption(of: "{\"wss://relay.example\":{\"read\":true,\"write\":true}}") == nil)
        #expect(LazarusPrivateItems.encryption(of: "encrypted-private-items") == nil)
        #expect(LazarusPrivateItems.encryption(of: "abc?iv=not base64!") == nil)
        #expect(LazarusPrivateItems.encryption(of: "abc?iv=def?iv=ghi") == nil)
    }

    // MARK: - Estimate

    @Test func bracketsTheRealCountOfANip44ListAcrossSizes() throws {
        let keys = try SelfKeys()
        for n in [0, 1, 3, 150, 593] {
            let tags = Self.privateTags(n)
            let content = try keys.nip44(tags)
            let lengths = try #require(LazarusPrivateItems.plaintextLengthRange(content))
            #expect(lengths.min <= Self.json(tags).utf8.count)
            #expect(lengths.max >= Self.json(tags).utf8.count)
            let estimate = try #require(LazarusPrivateItems.estimate(content))
            #expect(estimate.min <= n, "n=\(n)")
            #expect(estimate.max >= n, "n=\(n)")
        }
    }

    /// The point of the estimate: public counts alone read both as zero.
    @Test func tellsAnEmptiedListApartFromAFullOne() throws {
        let keys = try SelfKeys()
        let emptied = try #require(LazarusPrivateItems.estimate(try keys.nip44(Self.privateTags(2))))
        let full = try #require(LazarusPrivateItems.estimate(try keys.nip44(Self.privateTags(593))))
        #expect(full.min > emptied.max)
    }

    @Test func bracketsTheRealCountOfANip04List() throws {
        let keys = try SelfKeys()
        let tags = Self.privateTags(40)
        let content = try keys.nip04(tags)
        let lengths = try #require(LazarusPrivateItems.plaintextLengthRange(content))
        #expect(lengths.min <= Self.json(tags).utf8.count)
        #expect(lengths.max >= Self.json(tags).utf8.count)
        let estimate = try #require(LazarusPrivateItems.estimate(content))
        #expect(estimate.min <= 40)
        #expect(estimate.max >= 40)
    }

    @Test func returnsNothingForPayloadsThatAreNotAValidSize() {
        #expect(LazarusPrivateItems.estimate(String(repeating: "A", count: 133)) == nil)
        #expect(LazarusPrivateItems.estimate("plain text") == nil)
    }

    // MARK: - Parsing and counting

    @Test func parsesADecryptedTagListAndRejectsAnythingElse() {
        let tags = [["p", "a"], ["word", "spam"]]
        #expect(LazarusPrivateItems.parseTags(Self.json(tags)) == tags)
        #expect(LazarusPrivateItems.parseTags("{\"not\":\"tags\"}") == nil)
        #expect(LazarusPrivateItems.parseTags("not json") == nil)
        #expect(LazarusPrivateItems.parseTags("[[\"p\",1]]") == nil)
    }

    @Test func countsOnlyTheItemTagTypesAskedFor() {
        let tags = [["p", "a"], ["word", "spam"], ["t", "nsfw"], ["e", "x"], ["alt", "ignored"], []]
        #expect(LazarusPrivateItems.countItemTags(tags, types: ["p", "word", "t", "e"]) == 4)
    }

    // MARK: - Decryption

    @Test func decryptsSelfEncryptedNip44AndNip04PrivateItems() throws {
        let keys = try SelfKeys()
        let decryptor = try #require(LazarusDecryptor(keypair: keys.keypair))
        let tags = Self.privateTags(5)
        let nip44 = LazarusFixture.event(kind: 10000, createdAt: 1, content: try keys.nip44(tags), pubkey: keys.keypair.pubkey)
        let nip04 = LazarusFixture.event(kind: 10000, createdAt: 2, content: try keys.nip04(tags), pubkey: keys.keypair.pubkey)
        #expect(decryptor.privateTags(of: nip44) == tags)
        #expect(decryptor.privateTags(of: nip04) == tags)
    }

    @Test func decryptsNothingThatIsNotTheAccountsOwnEncryptedList() throws {
        let keys = try SelfKeys()
        let decryptor = try #require(LazarusDecryptor(keypair: keys.keypair))
        let othersList = LazarusFixture.event(kind: 10000, createdAt: 1, content: try keys.nip44(Self.privateTags(2)))
        #expect(decryptor.privateTags(of: othersList) == nil)
        let plain = LazarusFixture.event(kind: 3, createdAt: 1, content: "{\"wss://r\":{}}", pubkey: keys.keypair.pubkey)
        #expect(decryptor.privateTags(of: plain) == nil)
    }

    @Test func aViewOnlyAccountCannotDecrypt() throws {
        let keys = try SelfKeys()
        #expect(LazarusDecryptor(keypair: Keypair(privkey: "", pubkey: keys.keypair.pubkey)) == nil)
    }

    // MARK: - Ranking with private items

    @Test func sizesPrivateOnlyMuteListsInsteadOfReadingThemAsEmpty() throws {
        let keys = try SelfKeys()
        let full = try keys.privateMuteList(Self.privateTags(593), createdAt: 1000)
        let range = Lazarus.rank(muteProfile, LazarusFixture.tagged([full])).candidates[0].itemCount.range
        #expect(range.min <= 593)
        #expect(range.max >= 593)
        #expect(range.min > 0)
    }

    @Test func recommendsTheFullVersionWhenAClientEmptiedThePrivateList() throws {
        let keys = try SelfKeys()
        let full = try keys.privateMuteList(Self.privateTags(593), createdAt: 1000)
        let emptied = try keys.privateMuteList(Self.privateTags(1), createdAt: 2000)
        let result = Lazarus.rank(muteProfile, LazarusFixture.tagged([emptied, full]))
        #expect(result.current?.id == emptied.id)
        #expect(result.candidates[0].id == full.id)
        #expect(result.recommended?.id == full.id)
    }

    @Test func recommendsNothingWhenTheCurrentPrivateListIsAlreadyTheFullOne() throws {
        let keys = try SelfKeys()
        let emptied = try keys.privateMuteList(Self.privateTags(1), createdAt: 1000)
        let full = try keys.privateMuteList(Self.privateTags(593), createdAt: 2000)
        let result = Lazarus.rank(muteProfile, LazarusFixture.tagged([emptied, full]))
        #expect(result.current?.id == full.id)
        #expect(result.recommended == nil)
    }

    /// Looks like NIP-44 but isn't a valid payload size, so it can't be sized.
    @Test func recommendsNothingWhileTheCurrentSizeIsUnknown() throws {
        let keys = try SelfKeys()
        let unsizable = LazarusFixture.event(kind: 10000, createdAt: 2000, content: String(repeating: "A", count: 133))
        let full = try keys.privateMuteList(Self.privateTags(593), createdAt: 1000)
        let result = Lazarus.rank(muteProfile, LazarusFixture.tagged([unsizable, full]))
        #expect(!result.current!.itemCount.isSizeKnown)
        #expect(result.recommended == nil)
    }

    @Test func usesExactCountsOncePrivateItemsAreDecrypted() throws {
        let keys = try SelfKeys()
        let olderTags = Self.privateTags(40)
        let newerTags = Self.privateTags(2)
        let older = try keys.privateMuteList(olderTags, createdAt: 1000)
        let newer = try keys.privateMuteList(newerTags, createdAt: 2000)
        let scan = Lazarus.rank(muteProfile, [
            LazarusTaggedEvent(event: newer, relayUrl: "wss://a"),
            LazarusTaggedEvent(event: older, relayUrl: "wss://b"),
        ])
        let decrypted = Lazarus.merge(muteProfile, scan, privateTags: [older.id: olderTags, newer.id: newerTags])
        let olderCandidate = try #require(decrypted.candidates.first { $0.id == older.id })
        #expect(olderCandidate.itemCount == LazarusItemCount(count: 0, partial: false, privateCount: 40))
        #expect(decrypted.recommended?.id == older.id)
        #expect(decrypted.candidates[0].foundOn == ["wss://b"])
    }

    // MARK: - Delta with private items

    /// An item that moved between public and private isn't a change.
    @Test func diffsPrivateItemsTogetherWithPublicTags() throws {
        let keys = try SelfKeys()
        let items = Self.privateTags(3)
        let (a, b, c) = (items[0], items[1], items[2])
        let currentBase = try keys.privateMuteList([a, b], createdAt: 2000)
        let current = NostrEvent(id: currentBase.id, pubkey: currentBase.pubkey, kind: 10000, createdAt: 2000,
                                 tags: [c], content: currentBase.content, sig: currentBase.sig)
        let chosen = try keys.privateMuteList([a, c], createdAt: 1000)
        let delta = Lazarus.delta(chosen: chosen, current: current, privateTags: [current.id: [a, b], chosen.id: [a, c]])
        #expect(delta.removed == [b])
        #expect(delta.addedCount == 0)
        #expect(!delta.privateUnknown)
    }

    @Test func flagsADeltaWhosePrivateItemsWereNotDecrypted() throws {
        let keys = try SelfKeys()
        let current = try keys.privateMuteList(Self.privateTags(3), createdAt: 2000)
        let chosen = try keys.privateMuteList(Self.privateTags(5), createdAt: 1000)
        #expect(Lazarus.delta(chosen: chosen, current: current).privateUnknown)
    }
}
