import Foundation
import Testing
@testable import wisp

/// Lazarus data recovery: the spec's conformance vectors for the pure core
/// (registry, ranking with clobber detection, episodes and settling,
/// grouping, delta identity, profile fields, the pre-sign re-read decision,
/// the recovery draft, relay-list and publish-relay rules, validation).
/// Ported from the spec's reference implementation suite and the zap.cooking
/// web suite (`src/lib/lazarus/recovery.test.ts`), spec 0.6.1-draft.
/// https://github.com/dmnyc/lazarus/blob/main/SPEC.md

// MARK: - Fixtures

enum LazarusFixture {
    static let pubkey = String(repeating: "ab", count: 32)

    /// A 64-hex id unique to this call.
    static func freshId() -> String {
        (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "").lowercased()
    }

    /// Unsigned: the pure core doesn't verify signatures (the scan engine does).
    static func event(
        id: String? = nil,
        kind: Int = 3,
        createdAt: Int,
        tags: [[String]] = [],
        content: String = "",
        pubkey: String = LazarusFixture.pubkey
    ) -> NostrEvent {
        NostrEvent(id: id ?? freshId(), pubkey: pubkey, kind: kind, createdAt: createdAt,
                   tags: tags, content: content, sig: "test-sig")
    }

    static func followList(_ count: Int, _ createdAt: Int, content: String = "") -> NostrEvent {
        event(kind: 3, createdAt: createdAt, tags: (0..<count).map { ["p", "pk\($0)"] }, content: content)
    }

    static func muteList(_ count: Int, _ createdAt: Int) -> NostrEvent {
        let types = ["p", "word", "t", "e"]
        return event(kind: 10000, createdAt: createdAt, tags: (0..<count).map { [types[$0 % 4], "item\($0)"] })
    }

    static func tagged(_ events: [NostrEvent], relay: String = "wss://a") -> [LazarusTaggedEvent] {
        events.map { LazarusTaggedEvent(event: $0, relayUrl: relay) }
    }

    static func rank(_ kind: Int, _ events: [NostrEvent], currentConfirmed: Bool = true) -> LazarusScanResult {
        Lazarus.rank(LazarusRegistry.profile(for: kind)!, tagged(events), currentConfirmed: currentConfirmed)
    }

    static func keypair() throws -> Keypair {
        let priv = Schnorr.randomPrivkey()
        let pub = try Schnorr.xonlyPubkey(privkey32: priv)
        return Keypair(privkey: Hex.encode(priv), pubkey: Hex.encode(pub))
    }

    static func signed(
        _ keypair: Keypair, kind: Int, createdAt: Int, tags: [[String]] = [], content: String = ""
    ) throws -> NostrEvent {
        try NostrEvent.sign(
            privkey32: Hex.decode(keypair.privkey)!, pubkey: keypair.pubkey,
            kind: kind, createdAt: createdAt, tags: tags, content: content
        )
    }
}

private typealias F = LazarusFixture

private let day = 24 * 3600
private let hour = 3600

// MARK: - Registry

struct LazarusRegistryTests {

    @Test func pinsTheTierOneKindsRequiredForConformance() {
        #expect(LazarusRegistry.profile(for: 3)?.tier == 1)
        #expect(LazarusRegistry.profile(for: 10000)?.tier == 1)
    }

    @Test func flagsKind10044AsMeaningfulEmptyWithNoRanking() {
        let profile = LazarusRegistry.profile(for: 10044)
        #expect(profile?.meaningfulEmpty == true)
        #expect(profile?.ranking == .intent)
    }

    /// Spec 0.6.1: NIP-4e lists encryption pubkeys in `n` tags, not `p`.
    @Test func countsTheNTagsNip4eListsEncryptionKeysIn() {
        let keyList = F.event(kind: 10044, createdAt: 1000, tags: [
            ["n", String(repeating: "a", count: 64)],
            ["n", String(repeating: "b", count: 64)],
            ["p", String(repeating: "c", count: 64)],
        ])
        #expect(LazarusRegistry.profile(for: 10044)?.itemCount(keyList).count == 2)
    }

    @Test func neverReturnsProfilesForUnregisteredKinds() {
        #expect(LazarusRegistry.profile(for: 30078) == nil)
        #expect(LazarusRegistry.profile(for: 1) == nil)
    }

    /// Every registered kind, tier then kind: the scope the zap.cooking
    /// Android app offers.
    @Test func offersEveryRegisteredKindInRegistryOrder() {
        #expect(LazarusRegistry.ordered.map(\.kind) == [3, 10000, 0, 10003, 10044, 10002, 10006, 10050])
    }

    @Test func warnsAboutReMutesAndStaleRelayLists() {
        #expect(LazarusRegistry.profile(for: 10000)?.requiredWarnings.contains(.remute) == true)
        #expect(LazarusRegistry.profile(for: 10002)?.requiredWarnings.contains(.staleRelays) == true)
        #expect(LazarusRegistry.profile(for: 10050)?.requiredWarnings.contains(.staleRelays) == true)
    }
}

// MARK: - Rank

struct LazarusRankTests {

    @Test func ranksCountKindsByItemCountNotRecency() {
        let olderBigger = F.followList(120, 1000)
        let newerSmaller = F.followList(2, 2000)
        let result = F.rank(3, [newerSmaller, olderBigger])
        #expect(result.candidates[0].id == olderBigger.id)
        // Current is still the newest version the scan saw.
        #expect(result.current?.id == newerSmaller.id)
        #expect(result.recommended?.id == olderBigger.id)
        #expect(result.recommended?.isRecommended == true)
    }

    @Test func neverRecommendsEmptyCandidatesEvenWhenNewest() {
        let tombstone = F.followList(0, 3000)
        let healthy = F.followList(50, 1000)
        let result = F.rank(3, [tombstone, healthy])
        #expect(result.current?.id == tombstone.id)
        #expect(result.recommended?.id == healthy.id)
    }

    @Test func recommendsNothingWhenCurrentIsAlreadyTheBest() {
        let result = F.rank(3, [F.followList(80, 3000), F.followList(10, 1000)])
        #expect(result.recommended == nil)
    }

    /// A few unfollows over time is curation, not a clobber.
    @Test func keepsTheCurrentVersionWhenAnOlderOneIsOnlySlightlyBigger() {
        let older = F.followList(1102, 1000)
        let result = F.rank(3, [older, F.followList(1094, 2000)])
        #expect(result.candidates[0].id == older.id)
        #expect(result.recommended == nil)
    }

    @Test func recommendsAnOlderVersionWhenTheCurrentOneLostALargeShareOfIt() {
        let beforeClobber = F.followList(1945, 1000)
        let result = F.rank(3, [beforeClobber, F.followList(1094, 2000)])
        #expect(result.recommended?.id == beforeClobber.id)
    }

    @Test func doesNotRecommendOverACoupleOfItemsOnASmallList() {
        #expect(F.rank(3, [F.followList(6, 1000), F.followList(4, 2000)]).recommended == nil)
    }

    /// Each step loses about a tenth: curation, even though 2000 to 1200 is 40%.
    @Test func keepsTheCurrentVersionWhenTheListShrankGraduallyHoweverFar() {
        let versions = [2000, 1800, 1600, 1400, 1200].enumerated().map { F.followList($1, 1000 + $0) }
        #expect(F.rank(3, versions).recommended == nil)
    }

    /// Slow curation from 3000 to 1945, then a clobber to empty and a partial rebuild.
    @Test func recommendsTheVersionBeforeTheLatestClobberNotAnOlderPeak() {
        let versions = [3000, 2600, 2250, 1945, 0, 500, 1094].enumerated().map { F.followList($1, 1000 + $0) }
        #expect(F.rank(3, versions).recommended?.id == versions[3].id)
    }

    @Test func treatsAClobberTheListHasBeenEditedOnForAWeekAsSettled() {
        let versions = [F.followList(1945, day), F.followList(1114, day + 60)]
            + [1112, 1110, 1105, 1100, 1094].enumerated().map { F.followList($1, ($0 + 2) * 2 * day) }
        #expect(F.rank(3, versions).recommended == nil)
    }

    @Test func stillRecommendsWhenTheEditsSinceAClobberAllCameWithinAWeek() {
        let versions = [F.followList(1945, hour), F.followList(1114, 2 * hour)]
            + [1112, 1110, 1105, 1100, 1094].enumerated().map { F.followList($1, ($0 + 3) * hour) }
        #expect(F.rank(3, versions).recommended?.id == versions[0].id)
    }

    @Test func treatsBackToBackDropsAsOneClobber() {
        let versions = [500, 3, 0].enumerated().map { F.followList($1, 1000 + $0) }
        #expect(F.rank(3, versions).recommended?.id == versions[0].id)
    }

    /// Clobbered, partly restored, and clobbered again within hours.
    @Test func pointsAtTheFullestVersionBeforeAClobberThatBounced() {
        let versions = [
            F.followList(1945, 10 * hour),
            F.followList(1114, 11 * hour),
            F.followList(1660, 12 * hour),
            F.followList(1114, 13 * hour),
            F.followList(1100, 5 * day),
            F.followList(1094, 90 * day),
        ]
        #expect(F.rank(3, versions).recommended?.id == versions[0].id)
    }

    @Test func doesNotReachBackToAnUnrelatedClobberWeeksEarlier() {
        let versions = [
            F.followList(3000, day),
            F.followList(2000, day + 60),        // clobbered
            F.followList(2950, 2 * day),         // restored the next day
            F.followList(2600, 20 * day),        // then curated down over two months
            F.followList(2250, 40 * day),
            F.followList(1945, 60 * day),
            F.followList(1114, 60 * day + 60),   // clobbered again
            F.followList(1100, 90 * day),
        ]
        #expect(F.rank(3, versions).recommended?.id == versions[5].id)
    }

    @Test func recommendsNothingForMeaningfulEmptyKindsAndRequiresIntent() {
        let keys = F.event(kind: 10044, createdAt: 1000, tags: [["n", "encryption-pubkey-1"]])
        let emptied = F.event(kind: 10044, createdAt: 2000)
        let result = F.rank(10044, [emptied, keys])
        #expect(result.requiresIntentConfirmation)
        #expect(result.recommended == nil)
        // Still offered, in recency order, and not labeled damage.
        #expect(result.candidates.count == 2)
        #expect(result.candidates[0].id == emptied.id)
        #expect(!Lazarus.isPastEmptyVersion(result.candidates[0], profile: LazarusRegistry.profile(for: 10044)!))
    }

    /// Spec "Relay outcomes": drops are measured against current, and a scan
    /// that never reached a write relay may be measuring the wrong one.
    @Test func recommendsNothingWhileCurrentIsUnconfirmed() {
        let result = F.rank(3, [F.followList(40, 1000), F.followList(3, 2000)], currentConfirmed: false)
        #expect(!result.currentConfirmed)
        #expect(result.recommended == nil)
    }

    @Test func recencyKindsAreNewestFirstWithNoRecommendation() {
        let versions = (0..<3).map { F.event(kind: 0, createdAt: 1000 + $0, content: "{\"name\":\"v\($0)\"}") }
        let result = F.rank(0, versions)
        #expect(result.candidates.map(\.id) == versions.reversed().map(\.id))
        #expect(result.recommended == nil)
    }

    @Test func dedupesByEventIdAndAccumulatesFoundOnRelays() {
        let shared = F.followList(5, 1000)
        let result = Lazarus.rank(LazarusRegistry.profile(for: 3)!, [
            LazarusTaggedEvent(event: shared, relayUrl: "wss://a"),
            LazarusTaggedEvent(event: shared, relayUrl: "wss://b"),
            LazarusTaggedEvent(event: shared, relayUrl: "wss://a"),
        ])
        #expect(result.candidates.count == 1)
        #expect(result.candidates[0].foundOn == ["wss://a", "wss://b"])
    }

    @Test func countsMuteListsAcrossAllNip51TagTypes() {
        #expect(F.rank(10000, [F.muteList(8, 1000)]).candidates[0].itemCount.count == 8)
    }

    @Test func marksEncryptedContentCandidatesAsPartiallyCounted() throws {
        let keypair = try F.keypair()
        let key = try Nip44.getConversationKey(
            privkey32: Hex.decode(keypair.privkey)!, peerXonlyPubkey32: Hex.decode(keypair.pubkey)!
        )
        let encrypted = try Nip44.encrypt(plaintext: "[[\"p\",\"a\"],[\"p\",\"b\"]]", conversationKey: key)
        let withPrivate = F.followList(3, 1000, content: encrypted)
        #expect(F.rank(3, [withPrivate]).candidates[0].itemCount.partial)
    }

    @Test func doesNotTreatLegacyRelayJsonInAFollowListAsPrivateItems() {
        let withRelays = F.followList(3, 1000, content: "{\"wss://relay\": {\"read\": true}}")
        #expect(F.rank(3, [withRelays]).candidates[0].itemCount == LazarusItemCount(count: 3, partial: false))
    }
}

// MARK: - Grouping and display order

struct LazarusGroupingTests {

    private func ranked(_ counts: [Int]) -> (events: [NostrEvent], scan: LazarusScanResult) {
        let events = counts.enumerated().map { F.followList($1, 1000 + $0) }
        return (events, F.rank(3, events))
    }

    /// Rows as ids: a version row is its id, a group is its ids.
    private func shape(_ items: [LazarusListItem]) -> [[String]] {
        items.map { item in
            switch item {
            case .version(let candidate): return [candidate.id]
            case .group(let candidates, _): return ["group"] + candidates.map(\.id)
            }
        }
    }

    private let follows = LazarusRegistry.profile(for: 3)!

    @Test func foldsARunOfSmallEditsAndKeepsTheCurrentVersionOnItsOwnRow() {
        let (events, scan) = ranked([1100, 1101, 1099, 1098, 1097, 1096, 1095, 1094])
        #expect(shape(Lazarus.group(scan, profile: follows)) == [
            [events[7].id],
            ["group"] + events[0..<7].reversed().map(\.id),
        ])
    }

    @Test func foldsAClobberIntoItsOwnGroupApartFromTheCurationAroundIt() {
        let (events, scan) = ranked([2000, 1990, 1980, 1945, 1114, 1110, 1100, 1094])
        let items = Lazarus.group(scan, profile: follows)
        #expect(shape(items) == [
            [events[7].id],
            ["group", events[6].id, events[5].id],
            ["group", events[4].id, events[3].id],
            ["group", events[2].id, events[1].id, events[0].id],
        ])
        let clobbered = items.map { item -> Bool in
            if case .group(_, let clobbered) = item { return clobbered }
            return false
        }
        #expect(clobbered == [false, false, true, false])
        #expect(scan.recommended?.id == events[3].id)
    }

    @Test func keepsEmptyVersionsOnTheirOwnRows() {
        let (events, scan) = ranked([500, 490, 0, 480, 470, 460])
        #expect(shape(Lazarus.group(scan, profile: follows)) == [
            [events[5].id],
            ["group", events[4].id, events[3].id],
            [events[2].id],
            [events[1].id],
            [events[0].id],
        ])
    }

    @Test func canLeaveOutPastEmptyVersionsButNeverAnEmptyCurrentOne() {
        let (events, scan) = ranked([500, 490, 0, 480, 470, 460])
        #expect(shape(Lazarus.group(scan, profile: follows, hidePastEmpty: true)) == [
            [events[5].id],
            ["group", events[4].id, events[3].id],
            [events[1].id],
            [events[0].id],
        ])
        let emptied = ranked([300, 0])
        #expect(shape(Lazarus.group(emptied.scan, profile: follows, hidePastEmpty: true)) == [
            [emptied.events[1].id],
            [emptied.events[0].id],
        ])
    }

    @Test func pastEmptyVersionsAreNeverTheCurrentOneOrAMeaningfulEmptyKind() {
        let (_, scan) = ranked([300, 0, 280])
        let emptyPast = scan.candidates.first { $0.itemCount.range.max == 0 }!
        #expect(Lazarus.isPastEmptyVersion(emptyPast, profile: follows))
        let emptiedNow = ranked([300, 0]).scan
        #expect(!Lazarus.isPastEmptyVersion(emptiedNow.current!, profile: follows))
    }

    @Test func keepsEmptyVersionsOfMeaningfulEmptyKindsWhereEmptyIsAValidOption() {
        let events = [
            F.event(kind: 10044, createdAt: 1000),
            F.event(kind: 10044, createdAt: 1001, tags: [["n", String(repeating: "a", count: 64)]]),
        ]
        let profile = LazarusRegistry.profile(for: 10044)!
        let scan = F.rank(10044, events)
        #expect(Lazarus.group(scan, profile: profile, hidePastEmpty: true).count == 2)
    }

    @Test func doesNotGroupKindsWhereAnyTwoVersionsCanDiffer() {
        let events = (0..<3).map { F.event(kind: 0, createdAt: 1000 + $0, content: "{\"name\":\"a\"}") }
        let items = Lazarus.group(F.rank(0, events), profile: LazarusRegistry.profile(for: 0)!)
        #expect(items.allSatisfy { if case .version = $0 { return true } else { return false } })
    }

    @Test func sortsNewestFirstByDate() {
        let small = F.followList(10, 3000)
        let big = F.followList(500, 1000)
        let bigNewer = F.followList(500, 2000)
        let candidates = F.rank(3, [small, big, bigNewer]).candidates
        #expect(Lazarus.sorted(candidates, by: .date).map(\.id) == [small.id, bigNewer.id, big.id])
    }

    @Test func sortsLargestFirstBySizeNewestFirstOnTies() {
        let small = F.followList(10, 3000)
        let big = F.followList(500, 1000)
        let bigNewer = F.followList(500, 2000)
        let candidates = F.rank(3, [small, big, bigNewer]).candidates
        #expect(Lazarus.sorted(candidates, by: .size).map(\.id) == [bigNewer.id, big.id, small.id])
    }
}

// MARK: - Delta

struct LazarusDeltaTests {

    @Test func computesAdditionsRemovalsAndDirection() {
        let current = F.event(createdAt: 2000, tags: [["p", "a"], ["p", "b"]])
        let chosen = F.event(createdAt: 1000, tags: [["p", "b"], ["p", "c"]])
        let delta = Lazarus.delta(chosen: chosen, current: current)
        #expect(delta.addedCount == 1)
        #expect(delta.removedCount == 1)
        #expect(delta.grows)
        #expect(!delta.shrinks)
    }

    @Test func flagsAShrinkForSeparateConfirmation() {
        let current = F.event(createdAt: 2000, tags: [["p", "a"], ["p", "b"], ["p", "c"]])
        let chosen = F.event(createdAt: 1000, tags: [["p", "a"]])
        #expect(Lazarus.delta(chosen: chosen, current: current).shrinks)
    }

    /// Copilot review: the current version's encrypted items couldn't be
    /// counted, so the restore may drop items the counts can't see — that
    /// alone forces the shrink confirmation, even at zero counted removals.
    /// Only the current side does this: an undecryptable chosen version adds
    /// unknown items, it doesn't remove any.
    @Test func anUncountedCurrentSideCountsAsAShrink() {
        let encryptedCurrent = F.event(createdAt: 2000, tags: [], content: String(repeating: "A", count: 200))
        let chosen = F.event(createdAt: 1000, tags: [["p", "a"], ["p", "b"]])
        let delta = Lazarus.delta(chosen: chosen, current: encryptedCurrent)
        #expect(delta.currentPrivateUnknown)
        #expect(delta.privateUnknown)
        #expect(delta.removedCount == 0)
        #expect(delta.shrinks)
        #expect(!delta.grows)

        let encryptedChosen = F.event(createdAt: 2000, tags: [], content: String(repeating: "A", count: 200))
        let current = F.event(createdAt: 1000, tags: [["p", "a"], ["p", "b"]])
        let other = Lazarus.delta(chosen: encryptedChosen, current: current)
        #expect(other.privateUnknown)
        #expect(!other.currentPrivateUnknown)
        #expect(other.addedCount == 0)
        #expect(!other.shrinks)
    }

    @Test func treatsAFollowWhoseRelayHintOrPetnameChangedAsTheSameItem() {
        let current = F.event(createdAt: 2000, tags: [["p", "a"], ["p", "b", "wss://old"]])
        let chosen = F.event(createdAt: 1000, tags: [["p", "a", "wss://new", "alice"], ["p", "b"]])
        let delta = Lazarus.delta(chosen: chosen, current: current)
        #expect(delta.addedCount == 0)
        #expect(delta.removedCount == 0)
    }

    @Test func countsAChangedReadWriteMarkerOnRelayLists() {
        let current = F.event(kind: 10002, createdAt: 2000, tags: [["r", "wss://a", "read"]])
        let chosen = F.event(kind: 10002, createdAt: 1000, tags: [["r", "wss://a", "write"]])
        let delta = Lazarus.delta(chosen: chosen, current: current)
        #expect(delta.addedCount == 1)
        #expect(delta.removedCount == 1)
    }

    @Test func comparesEveryItemAgainstNoCurrentVersionAsAdded() {
        let chosen = F.event(createdAt: 1000, tags: [["p", "a"], ["p", "b"]])
        let delta = Lazarus.delta(chosen: chosen, current: nil)
        #expect(delta.addedCount == 2)
        #expect(delta.removedCount == 0)
    }
}

// MARK: - Profile fields

struct LazarusProfileChangeTests {

    private func profile(_ content: [String: Any], tags: [[String]] = []) -> NostrEvent {
        let data = try! JSONSerialization.data(withJSONObject: content, options: [.sortedKeys])
        return F.event(kind: 0, createdAt: 1000, tags: tags, content: String(data: data, encoding: .utf8)!)
    }

    @Test func listsOnlyTheProfileFieldsThatChange() {
        let current = profile(["name": "clobbered", "about": "same"])
        let chosen = profile(["name": "Daniel", "about": "same", "picture": "https://pic"])
        #expect(Lazarus.profileChanges(chosen: chosen, current: current) == [
            LazarusProfileChange(field: "name", from: "clobbered", to: "Daniel"),
            LazarusProfileChange(field: "picture", from: nil, to: "https://pic"),
        ])
    }

    /// A content restore replaces every field, so fields outside the
    /// well-known set count too.
    @Test func listsChangesToFieldsOutsideTheWellKnownSet() {
        let current = profile(["name": "same", "pronouns": "they/them", "zapcooking": ["chef": true]])
        let chosen = profile(["name": "same", "pronouns": "she/her"])
        let changes = Lazarus.profileChanges(chosen: chosen, current: current)
        #expect(changes.contains(LazarusProfileChange(field: "pronouns", from: "they/them", to: "she/her")))
        #expect(changes.contains(LazarusProfileChange(field: "zapcooking", from: "{\"chef\":true}", to: nil)))
        #expect(changes.count == 2)
    }

    @Test func showsNonStringValuesAsJsonInsteadOfReadingThemAsAbsent() {
        let current = profile(["name": "same"])
        let chosen = profile(["name": "same", "bot": true])
        #expect(Lazarus.profileChanges(chosen: chosen, current: current) == [
            LazarusProfileChange(field: "bot", from: nil, to: "true"),
        ])
    }

    @Test func coversEveryFieldAndTagARestoreWouldReplace() {
        let current = profile(["name": "same", "pronouns": "they/them"], tags: [["emoji", "wave", "https://wave"]])
        let chosen = profile(["name": "same", "bot": false])
        #expect(Lazarus.profileChanges(chosen: chosen, current: current) == [
            LazarusProfileChange(field: "bot", from: nil, to: "false"),
            LazarusProfileChange(field: "pronouns", from: "they/them", to: nil),
            LazarusProfileChange(field: "emoji tags", from: "wave https://wave", to: nil),
        ])
    }

    @Test func readsAnEmptyOrWhitespaceStringAsAbsent() {
        let current = profile(["name": "same", "about": "   "])
        let chosen = profile(["name": "same"])
        #expect(Lazarus.profileChanges(chosen: chosen, current: current).isEmpty)
    }

    @Test func ignoresTagOrder() {
        let tags = [["emoji", "a", "https://a"], ["emoji", "b", "https://b"]]
        let current = profile(["name": "same"], tags: tags)
        let chosen = profile(["name": "same"], tags: tags.reversed())
        #expect(Lazarus.profileChanges(chosen: chosen, current: current).isEmpty)
    }
}

// MARK: - Pre-sign re-read

struct LazarusCheckCurrentTests {

    private let reviewed = F.followList(5, 2000)
    private let older = F.followList(5, 1000)
    private let newer = F.followList(5, 3000)

    private func answered(_ events: NostrEvent...) -> LazarusReadAnswer {
        LazarusReadAnswer(events: events, answered: true)
    }

    private func unanswered(_ events: NostrEvent...) -> LazarusReadAnswer {
        LazarusReadAnswer(events: events, answered: false)
    }

    private func isProceed(_ check: LazarusCurrentCheck, with id: String?) -> Bool {
        if case .proceed(let current) = check { return current?.id == id }
        return false
    }

    private func changedId(_ check: LazarusCurrentCheck) -> String? {
        if case .changed(let current) = check { return current.id }
        return nil
    }

    private func isUnconfirmed(_ check: LazarusCurrentCheck) -> Bool {
        if case .unconfirmed = check { return true }
        return false
    }

    /// The re-read asks fewer relays than the scan, so an older copy is no edit.
    @Test func proceedsOverAnOlderCopyOnTheWriteRelays() {
        let check = Lazarus.checkCurrent(reviewed: reviewed, local: older, answers: [answered(older), answered()])
        #expect(isProceed(check, with: reviewed.id))
    }

    @Test func reportsANewerVersionFromAWriteRelayOrTheLocalCopyAsAChange() {
        #expect(changedId(Lazarus.checkCurrent(reviewed: reviewed, local: nil, answers: [answered(older), answered(newer)])) == newer.id)
        #expect(changedId(Lazarus.checkCurrent(reviewed: reviewed, local: newer, answers: [answered()])) == newer.id)
        // A relay that sent a newer version and then failed still shows the edit.
        #expect(changedId(Lazarus.checkCurrent(reviewed: reviewed, local: nil, answers: [unanswered(newer)])) == newer.id)
    }

    @Test func treatsAVersionFoundWhenNoneWasReviewedAsAChange() {
        #expect(changedId(Lazarus.checkCurrent(reviewed: nil, local: nil, answers: [answered(older)])) == older.id)
    }

    @Test func refusesWhenNoWriteRelayAnswered() {
        #expect(isUnconfirmed(Lazarus.checkCurrent(reviewed: reviewed, local: older, answers: [unanswered(older), unanswered()])))
        #expect(isUnconfirmed(Lazarus.checkCurrent(reviewed: reviewed, local: nil, answers: [])))
    }

    /// The local copy can't confirm current on its own.
    @Test func neverConfirmsFromTheLocalCopyAlone() {
        #expect(isUnconfirmed(Lazarus.checkCurrent(reviewed: reviewed, local: reviewed, answers: [unanswered()])))
    }

    @Test func countsOneEmptyAnswerAsEnough() {
        #expect(isProceed(Lazarus.checkCurrent(reviewed: reviewed, local: nil, answers: [unanswered(), answered()]), with: reviewed.id))
    }

    /// A relay's real event wins a tie with this device's copy of the same version.
    @Test func prefersTheRelayCopyOverTheLocalCopyOnATie() {
        let relayCopy = F.followList(5, 3000)
        let localCopy = F.event(id: "local-3-3000", createdAt: 3000, tags: [["p", "x"]])
        #expect(changedId(Lazarus.checkCurrent(reviewed: reviewed, local: localCopy, answers: [answered(relayCopy)])) == relayCopy.id)
    }
}

// MARK: - Recovery draft

struct LazarusDraftTests {

    @Test func copiesTheCandidateVerbatimWithAFreshTimestamp() {
        let chosen = F.followList(4, 999, content: "{\"wss://relay\": {\"read\": true}}")
        let draft = Lazarus.draft(chosen: chosen, current: nil, now: 1_234_567_890)
        #expect(draft.kind == 3)
        #expect(draft.createdAt == 1_234_567_890)
        #expect(draft.content == chosen.content)
        #expect(draft.tags == chosen.tags)
    }

    /// Clobbering clients often have skewed clocks: an older timestamp would
    /// lose to the clobbered version on relays and in caches.
    @Test func datesTheDraftAfterTheVersionItReplacesEvenOneFromTheFuture() {
        let chosen = F.followList(4, 999)
        let current = F.followList(1, 1_234_568_490)   // ten minutes ahead of now
        #expect(Lazarus.draft(chosen: chosen, current: current, now: 1_234_567_890).createdAt == 1_234_568_491)
    }

    @Test func keepsEncryptedPrivateContentVerbatim() {
        let chosen = F.event(kind: 10000, createdAt: 999, content: "ciphertext?iv=abc")
        #expect(Lazarus.draft(chosen: chosen, current: nil, now: 5000).content == "ciphertext?iv=abc")
    }
}

// MARK: - Relays

struct LazarusRelayRulesTests {

    @Test func readsTheWriteRelaysFromMarkedAndUnmarkedRTags() {
        let list = F.event(kind: 10002, createdAt: 1000, tags: [
            ["r", "wss://both.example/"],
            ["r", "wss://inbox.example", "read"],
            ["r", "wss://outbox.example", "write"],
            ["relay", "wss://ignored.example"],
        ])
        let parsed = Lazarus.parseRelayList(list)
        #expect(parsed.write == ["wss://both.example", "wss://outbox.example"])
        #expect(parsed.read == ["wss://both.example", "wss://inbox.example"])
    }

    @Test func aRelayListNamingNoWriteRelaysCountsAsMissing() {
        let relays = Lazarus.userRelays(read: ["wss://inbox.example"], write: [], standIns: ["wss://default.example"])
        #expect(relays.status == .missing)
        #expect(relays.write == ["wss://default.example"])
        #expect(relays.read == ["wss://inbox.example"])
    }

    @Test func normalizesAndDedupesRelayUrlsDroppingUnreachableOnes() {
        #expect(Lazarus.uniqueRelays(["wss://Relay.Example/", "wss://relay.example", "https://x.example", "wss://abc.onion"])
                == ["wss://relay.example"])
    }

    @Test func judgesSuccessOnTheWriteRelaysAndSendsTheRestAsExtras() {
        let restoring = F.followList(3, 1000)
        let targets = Lazarus.publishRelays(
            currentWrite: ["wss://w1/", "wss://w2"], answeredRelays: ["wss://hist.nostr.land", "wss://w1"],
            restoring: restoring, standIns: ["wss://default"]
        )
        #expect(targets.judged == ["wss://w1", "wss://w2"])
        #expect(targets.extra == ["wss://hist.nostr.land"])
    }

    /// Spec 0.6: a relay list restore replaces the write relays themselves.
    @Test func judgesARelayListRestoreOnTheWriteRelaysTheRestoredVersionNames() {
        let restoring = F.event(kind: 10002, createdAt: 1000, tags: [
            ["r", "wss://alive/", "write"], ["r", "wss://both/"], ["r", "wss://inbox/", "read"],
        ])
        let targets = Lazarus.publishRelays(
            currentWrite: ["wss://dead/"], answeredRelays: ["wss://hist.nostr.land"],
            restoring: restoring, standIns: ["wss://default"]
        )
        #expect(targets.judged == ["wss://alive", "wss://both"])
        // The current write relays still get it as a best effort.
        #expect(targets.extra == ["wss://dead", "wss://hist.nostr.land"])
    }

    @Test func usesTheStandInsWhenTheRestoredRelayListNamesNoWriteRelays() {
        let restoring = F.event(kind: 10002, createdAt: 1000, tags: [["r", "wss://inbox/", "read"]])
        let targets = Lazarus.publishRelays(
            currentWrite: ["wss://dead/"], answeredRelays: [], restoring: restoring, standIns: ["wss://default"]
        )
        #expect(targets.judged == ["wss://default"])
        #expect(targets.extra == ["wss://dead"])
    }

    @Test func hasNothingToJudgeOnWithoutWriteRelays() {
        let targets = Lazarus.publishRelays(
            currentWrite: [], answeredRelays: ["wss://a"], restoring: F.followList(3, 1000), standIns: ["wss://d"]
        )
        #expect(targets.judged.isEmpty)
    }

    /// `until` is inclusive: the next page repeats the oldest event, and a
    /// cursor that didn't move means the relay is exhausted.
    @Test func pagesOnlyFromAFullPageAndOnlyWhenTheCursorMoves() {
        let full = (0..<50).map { F.followList(1, 1000 + $0) }
        #expect(Lazarus.nextCursor(validEvents: full, previous: nil) == 1000)
        #expect(Lazarus.nextCursor(validEvents: Array(full.prefix(49)), previous: nil) == nil)
        #expect(Lazarus.nextCursor(validEvents: full, previous: 2000) == 1000)
        #expect(Lazarus.nextCursor(validEvents: full, previous: 1000) == nil)
    }

    @Test func aScanNoRelayAnsweredWithNothingToShowFailed() {
        var page = LazarusFetchPage(queriedRelays: ["wss://a", "wss://b"], outcomes: ["wss://a": .failed, "wss://b": .timedOut])
        #expect(Lazarus.isFailedScan(page))
        page.tagged = F.tagged([F.followList(3, 1000)])
        #expect(!Lazarus.isFailedScan(page))
        page.tagged = []
        page.outcomes["wss://b"] = .answered
        #expect(!Lazarus.isFailedScan(page))
    }
}

// MARK: - Merging pages

struct LazarusMergeTests {
    private let follows = LazarusRegistry.profile(for: 3)!

    @Test func keepsTheCursorOfARelayWhoseOlderPageFailedAndDropsExhaustedOnes() {
        var scan = F.rank(3, [F.followList(10, 2000)])
        scan.olderCursors = ["wss://slow": 1500, "wss://done": 1600]
        let page = LazarusFetchPage(
            tagged: F.tagged([F.followList(10, 1400)], relay: "wss://done"),
            queriedRelays: ["wss://slow", "wss://done"],
            respondingRelays: ["wss://done"],
            olderCursors: [:],
            outcomes: ["wss://slow": .timedOut, "wss://done": .answered]
        )
        let merged = Lazarus.mergeOlder(follows, scan, page: page, privateTags: [:])
        #expect(merged.candidates.count == 2)
        #expect(merged.olderCursors == ["wss://slow": 1500])
    }

    /// A write relay answering on retry confirms current, which lifts the
    /// withheld recommendation.
    @Test func aWriteRelayAnsweringOnRetryConfirmsCurrent() {
        let full = F.followList(40, 1000)
        let clobbered = F.followList(3, 2000)
        let first = LazarusFetchPage(
            tagged: F.tagged([full, clobbered], relay: "wss://hist"),
            queriedRelays: ["wss://hist", "wss://w1"],
            respondingRelays: ["wss://hist"],
            outcomes: ["wss://hist": .answered, "wss://w1": .failed]
        )
        let scan = Lazarus.scanResult(follows, page: first, writeRelays: ["wss://w1"], relayList: .found)
        #expect(!scan.currentConfirmed)
        #expect(scan.recommended == nil)
        let retry = LazarusFetchPage(queriedRelays: ["wss://w1"], outcomes: ["wss://w1": .answered])
        let merged = Lazarus.mergeRetry(follows, scan, page: retry, writeRelays: ["wss://w1"], privateTags: [:])
        #expect(merged.currentConfirmed)
        #expect(merged.relayOutcomes?["wss://w1"] == .answered)
        #expect(merged.recommended?.id == full.id)
    }
}

// MARK: - Validation

struct LazarusValidationTests {

    @Test func acceptsARealSignedVersionOfTheScannedList() throws {
        let keypair = try F.keypair()
        let event = try F.signed(keypair, kind: 3, createdAt: 1000, tags: [["p", keypair.pubkey]])
        #expect(Lazarus.isVersion(event, kind: 3, pubkey: keypair.pubkey))
    }

    /// Relays are untrusted: a restore would sign whatever they return.
    @Test func rejectsForeignForgedOrTamperedEvents() throws {
        let keypair = try F.keypair()
        let someoneElse = try F.keypair()
        let event = try F.signed(keypair, kind: 3, createdAt: 1000, tags: [["p", "a"]])
        #expect(!Lazarus.isVersion(event, kind: 10000, pubkey: keypair.pubkey))
        #expect(!Lazarus.isVersion(event, kind: 3, pubkey: someoneElse.pubkey))
        let forgedSig = NostrEvent(id: event.id, pubkey: event.pubkey, kind: 3, createdAt: 1000,
                                   tags: event.tags, content: "", sig: String(repeating: "0", count: 128))
        #expect(!Lazarus.isVersion(forgedSig, kind: 3, pubkey: keypair.pubkey))
        let tampered = NostrEvent(id: event.id, pubkey: event.pubkey, kind: 3, createdAt: 1000,
                                  tags: [["p", "a"], ["p", "injected"]], content: "", sig: event.sig)
        #expect(!Lazarus.isVersion(tampered, kind: 3, pubkey: keypair.pubkey))
        let otherAuthorsSignature = try F.signed(someoneElse, kind: 3, createdAt: 1000, tags: [["p", "a"]])
        let reattributed = NostrEvent(id: otherAuthorsSignature.id, pubkey: keypair.pubkey, kind: 3, createdAt: 1000,
                                      tags: otherAuthorsSignature.tags, content: "", sig: otherAuthorsSignature.sig)
        #expect(!Lazarus.isVersion(reattributed, kind: 3, pubkey: keypair.pubkey))
    }
}
