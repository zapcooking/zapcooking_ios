import Foundation
import Testing
@testable import wisp

/// Characterization of `OnlyFoodFilter` against Android `OnlyFoodFilterTest`.
struct OnlyFoodFilterTests {

    private let now = 1_000_000

    private struct Config {
        var blocked: Set<String> = OnlyFoodFilter.blockedPubkeys
        var userBlocked: Set<String> = []
        var mutedWords: Set<String> = []
        var mutedThreads: Set<String> = []
        var deletedIds: Set<String> = []
        var wotEnabled = false
        var networkReady = false
        var currentUser = "me"
        var qualified: Set<String> = []
        var foodSeed: Set<String> = []
    }

    private func filter(_ cfg: Config) -> OnlyFoodFilter {
        let now = self.now
        let userBlocked = cfg.userBlocked
        let mutedWords = cfg.mutedWords
        let mutedThreads = cfg.mutedThreads
        let deletedIds = cfg.deletedIds
        let wotEnabled = cfg.wotEnabled
        let networkReady = cfg.networkReady
        let currentUser = cfg.currentUser
        let qualified = cfg.qualified
        let foodSeed = cfg.foodSeed
        return OnlyFoodFilter(
            nowSeconds: { now },
            blockedPubkeys: cfg.blocked,
            isUserBlocked: { userBlocked.contains($0) },
            containsMutedWord: { content in
                guard !mutedWords.isEmpty else { return false }
                let lower = content.lowercased()
                return mutedWords.contains { lower.contains($0) }
            },
            isThreadMuted: { mutedThreads.contains($0) },
            isDeleted: { deletedIds.contains($0) },
            isWotFiltered: { pk in
                if !wotEnabled { return false }
                if !networkReady { return false }
                if pk == currentUser { return false }
                if qualified.contains(pk) { return false }
                if foodSeed.contains(pk) { return false }
                return true
            }
        )
    }

    private func ev(
        _ id: String,
        pubkey: String = "good",
        createdAt: Int? = nil,
        content: String = "",
        tags: [[String]] = []
    ) -> NostrEvent {
        NostrEvent(
            id: id,
            pubkey: pubkey,
            kind: 1,
            createdAt: createdAt ?? now - 100,
            tags: tags,
            content: content,
            sig: ""
        )
    }

    @Test func rejectReasons_areCorrectAndOrdered() {
        let cfg = Config(
            userBlocked: ["ub"],
            mutedWords: ["bad"],
            mutedThreads: ["root-muted"],
            deletedIds: ["del"]
        )
        let f = filter(cfg)
        #expect(f.decideKind1(ev("fut", createdAt: now + 100)) == .futureDated)
        #expect(f.decideKind1(ev("b", pubkey: OnlyFoodFilter.blockedPubkeys.first!)) == .blockedPubkey)
        #expect(f.decideKind1(ev("u", pubkey: "ub")) == .userBlocked)
        #expect(f.decideKind1(ev("del")) == .deleted)
        #expect(f.decideKind1(ev("w", content: "so bad")) == .mutedWord)
        #expect(f.decideKind1(ev("root-muted")) == .threadMuted)
        #expect(f.decideKind1(ev("ok", content: "tasty")) == .accept)
    }

    @Test func structuralSpam_boundaries() {
        let f = filter(Config())
        let p = { (n: Int) in (0..<n).map { ["p", "p\($0)"] } }
        let t = { (n: Int) in (0..<n).map { ["t", "t\($0)"] } }
        #expect(f.decideKind1(ev("p24", tags: p(24))) == .accept)
        #expect(f.decideKind1(ev("p25", tags: p(25))) == .structuralSpam)
        #expect(f.decideKind1(ev("t5", tags: t(5))) == .accept)
        #expect(f.decideKind1(ev("t6", tags: t(6))) == .structuralSpam)
        #expect(f.decideKind1(ev("c6", content: "#a #b #c #d #e #f")) == .structuralSpam)
    }

    @Test func wot_isNoOp_whenNetworkNotReady() {
        let cfg = Config(wotEnabled: true, networkReady: false)
        #expect(filter(cfg).decideKind1(ev("stranger", pubkey: "stranger", content: "food")) == .accept)
    }

    @Test func wot_dropsStranger_onlyWhenEnabledAndReady() {
        let ready = Config(
            wotEnabled: true,
            networkReady: true,
            qualified: ["friend"],
            foodSeed: ["seeded"]
        )
        let f = filter(ready)
        #expect(f.decideKind1(ev("s", pubkey: "stranger", content: "food")) == .wotFiltered)
        #expect(f.decideKind1(ev("f", pubkey: "friend", content: "food")) == .accept)
        #expect(f.decideKind1(ev("seed", pubkey: "seeded", content: "food")) == .accept)
        #expect(f.decideKind1(ev("me", pubkey: "me", content: "food")) == .accept)
    }

    @Test func replies_areDropped() {
        let f = filter(Config())
        let reply = ev("reply", content: "food", tags: [["e", "root1", "", "reply"], ["p", "x"]])
        #expect(f.decideKind1(reply) == .reply)
    }

    @Test func live_isMuteOnly_wotIsNoOp() {
        let f = OnlyFoodFilter.live()
        #expect(f.isWotFiltered("stranger") == false)
    }
}
