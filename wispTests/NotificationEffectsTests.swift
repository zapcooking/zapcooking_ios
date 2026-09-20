import Foundation
import Testing
@testable import wisp

/// The Notification Sounds port from Android: the per-type effect table
/// (`Navigation.kt`'s four arrival collectors), the filter set both
/// repositories consult, and the zap-burst flag that drives the bottom bar.
@MainActor
struct NotificationEffectsTests {

    // MARK: - The parity table

    /// Replies and DMs are the same arrival: `icq_reply.mp3` plus a pulse.
    /// Android also blooms an ICQ flower over the tab for both; that is a
    /// Wisp house convention and is deliberately not ported, so neither
    /// draws anything.
    @Test func repliesAndDms_chimeAndPulse_withNoBurst() {
        for kind in [NotificationKind.reply, .dm] {
            let plan = NotificationEffectPlan.plan(for: kind, soundsOn: true, typeEnabled: true)
            #expect(plan == NotificationEffectPlan(sound: .reply, haptic: .pulse, burst: nil), "\(kind)")
        }
    }

    /// The zap burst is the only one we draw.
    @Test func zapIsTheOnlyBurst() {
        for kind in NotificationKind.allCases {
            let plan = NotificationEffectPlan.plan(for: kind, soundsOn: true, typeEnabled: true)
            #expect((plan.burst != nil) == (kind == .zap), "\(kind)")
        }
    }

    /// Reactions, reposts, mentions, quotes and votes all share the blip.
    /// Votes are the ones iOS used to drop on the floor — Android buckets
    /// `KIND_POLL_RESPONSE` into VOTES and blips it like the rest.
    @Test func blipCrowd_includesVotes() {
        for kind in [NotificationKind.reaction, .repost, .mention, .quote, .pollVote, .pollEnded] {
            let plan = NotificationEffectPlan.plan(for: kind, soundsOn: true, typeEnabled: true)
            #expect(plan == NotificationEffectPlan(sound: .blip, haptic: .blip, burst: nil), "\(kind)")
        }
    }

    @Test func zap_thunders_buzzes_andBursts() {
        let plan = NotificationEffectPlan.plan(for: .zap, soundsOn: true, typeEnabled: true)
        #expect(plan == NotificationEffectPlan(sound: .zap, haptic: .zapBuzz, burst: .zap))
    }

    // MARK: - The two gates, which are not symmetric

    /// The global toggle silences audio and nothing else — the haptic and
    /// the burst still run, as on Android.
    @Test func soundToggleOff_silencesAudioOnly() {
        for kind in NotificationKind.allCases {
            let on = NotificationEffectPlan.plan(for: kind, soundsOn: true, typeEnabled: true)
            let off = NotificationEffectPlan.plan(for: kind, soundsOn: false, typeEnabled: true)
            #expect(off.sound == nil, "\(kind)")
            #expect(off.haptic == on.haptic, "\(kind)")
            #expect(off.burst == on.burst, "\(kind)")
        }
    }

    /// Muting a type suppresses everything for it — sound, buzz and burst.
    /// Zaps are Android's one exception: the burst and the thunder ignore
    /// the filter and only the buzz honors it.
    @Test func mutedType_suppressesEverything_exceptTheZapBurst() {
        for kind in NotificationKind.allCases where kind != .zap {
            let plan = NotificationEffectPlan.plan(for: kind, soundsOn: true, typeEnabled: false)
            #expect(plan == .none, "\(kind)")
        }
        let zap = NotificationEffectPlan.plan(for: .zap, soundsOn: true, typeEnabled: false)
        #expect(zap == NotificationEffectPlan(sound: .zap, haptic: nil, burst: .zap))
    }

    /// Both gates shut: a muted zap on a silenced app still bursts, and
    /// nothing else in the table makes a sound or a move.
    @Test func bothGatesShut_leavesOnlyTheZapBurst() {
        for kind in NotificationKind.allCases where kind != .zap {
            #expect(NotificationEffectPlan.plan(for: kind, soundsOn: false, typeEnabled: false) == .none, "\(kind)")
        }
        let zap = NotificationEffectPlan.plan(for: .zap, soundsOn: false, typeEnabled: false)
        #expect(zap == NotificationEffectPlan(sound: nil, haptic: nil, burst: .zap))
    }

    /// Every kind maps to a filter bucket, so no arrival can slip past the
    /// per-type gate by having nothing to check against.
    @Test func everyKind_hasAFilterBucket() {
        for kind in NotificationKind.allCases {
            _ = NotificationFilter.bucket(for: kind)
        }
        #expect(NotificationFilter.bucket(for: .pollVote) == .votes)
        #expect(NotificationFilter.bucket(for: .pollEnded) == .votes)
        #expect(NotificationFilter.bucket(for: .dm) == .dms)
    }

    // MARK: - The filter set

    @Test func filterStore_defaultsToEverything_andRoundTrips() {
        let pubkey = "test_\(UUID().uuidString)"
        defer { UserDefaults.standard.removeObject(forKey: NotificationFilterStore.key(pubkey: pubkey)) }

        #expect(NotificationFilterStore.load(pubkey: pubkey) == Set(NotificationFilter.allCases))

        NotificationFilterStore.save([.zaps, .dms], pubkey: pubkey)
        #expect(NotificationFilterStore.load(pubkey: pubkey) == [.zaps, .dms])

        // "Everything off" is a real choice and must survive as empty, not
        // fall back to the all-types default.
        NotificationFilterStore.save([], pubkey: pubkey)
        #expect(NotificationFilterStore.load(pubkey: pubkey).isEmpty)
    }

    /// A filter removed in a later build drops out of the set instead of
    /// failing the load and stranding the user with no types.
    @Test func filterStore_dropsUnknownRawValues() {
        let pubkey = "test_\(UUID().uuidString)"
        let key = NotificationFilterStore.key(pubkey: pubkey)
        defer { UserDefaults.standard.removeObject(forKey: key) }

        UserDefaults.standard.set(["zaps", "not_a_filter", "replies"], forKey: key)
        #expect(NotificationFilterStore.load(pubkey: pubkey) == [.zaps, .replies])
    }

    /// Scoped per account — switching accounts must not inherit the other
    /// account's filter.
    @Test func filterStore_isPerAccount() {
        let a = "test_a_\(UUID().uuidString)", b = "test_b_\(UUID().uuidString)"
        defer {
            UserDefaults.standard.removeObject(forKey: NotificationFilterStore.key(pubkey: a))
            UserDefaults.standard.removeObject(forKey: NotificationFilterStore.key(pubkey: b))
        }
        NotificationFilterStore.save([.zaps], pubkey: a)
        #expect(NotificationFilterStore.load(pubkey: b) == Set(NotificationFilter.allCases))
    }

    // MARK: - Burst flags

    /// Android holds `isZapAnimating` for 900 ms.
    @Test func burstDuration_matchesAndroid() {
        #expect(NotificationBurstStore.zapDuration == 0.9)
    }

    @Test func fireZap_latchesThenClearsItself() async throws {
        let store = NotificationBurstStore()
        store.fireZap()
        #expect(store.zapBurst)
        try await Task.sleep(for: .seconds(NotificationBurstStore.zapDuration + 0.25))
        #expect(!store.zapBurst)
    }

    /// A second zap mid-burst restarts the window rather than letting the
    /// first one's timer cut it short.
    @Test func refiring_restartsTheWindow() async throws {
        let store = NotificationBurstStore()
        store.fireZap()
        try await Task.sleep(for: .seconds(NotificationBurstStore.zapDuration * 0.7))
        store.fireZap()
        // Past the first window's deadline, still lit because of the second.
        try await Task.sleep(for: .seconds(NotificationBurstStore.zapDuration * 0.5))
        #expect(store.zapBurst)
        try await Task.sleep(for: .seconds(NotificationBurstStore.zapDuration))
        #expect(!store.zapBurst)
    }

    /// `ZapBurstView` starts particles on a false→true edge of `isActive`.
    /// Refiring while already bursting never produces that edge, so the
    /// generation token has to move or the second zap draws nothing.
    @Test func refiring_bumpsGeneration() {
        let store = NotificationBurstStore()
        #expect(store.zapGeneration == 0)
        store.fireZap()
        #expect(store.zapGeneration == 1)
        store.fireZap()
        #expect(store.zapGeneration == 2)
        #expect(store.zapBurst)
    }
}
