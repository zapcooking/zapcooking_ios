import Foundation

/// Canonical relay lists referenced from many places in the app.
///
/// Before this existed the same 4-indexer literal appeared in 20+ files (every
/// repository, every feed view model, every list-editor view), so adding or
/// rotating an indexer required a sweeping find-replace and routinely missed
/// one or two sites. Keep additions here; let call sites read from the enum.
enum RelayDefaults {
    /// Indexer-grade relays used to discover kind-0 / kind-3 / kind-10002
    /// events when we don't yet know an author's outbox. Treat as a discovery
    /// pool — feed/notification queries should route through the user's
    /// scoreboard, not these.
    ///
    /// `purplepag.es` is the canonical profiles relay other clients (Amethyst,
    /// Coracle, Snort) write kind-0 to specifically for cross-client discovery,
    /// so it carries authors whose write relays we don't otherwise reach.
    /// `nos.lol` is a high-volume general relay that picks up profiles missing
    /// from the indexer-branded set.
    nonisolated static let indexers: [String] = [
        "wss://purplepag.es",
        "wss://indexer.nostrarchives.com",
        "wss://indexer.coracle.social",
        "wss://relay.primal.net",
        "wss://nos.lol"
    ]

    /// Generic fallback relays for paths where we have no scoreboard hint and
    /// the indexer set isn't appropriate (e.g. notifications, mutes, extended
    /// network bootstrap).
    nonisolated static let fallbacks: [String] = [
        "wss://relay.primal.net",
        "wss://nos.lol",
        "wss://relay.nostr.net"
    ]

    /// Bootstrap relay set used at first-launch / sign-up — wider than `indexers`
    /// because new users have no scoreboard yet, so we cast a slightly broader
    /// net to find their kind-0 / kind-3 / kind-10002 events.
    nonisolated static let onboarding: [String] = [
        "wss://indexer.coracle.social",
        "wss://relay.nos.social",
        "wss://nos.lol",
        "wss://indexer.nostrarchives.com",
        "wss://relay.primal.net"
    ]

    // MARK: - Zap Cooking role-based sets (build spec §2 "Relays")
    //
    // These are ROLE sets, not a single flattened pool. Android's CLAUDE.md is
    // explicit (and the spec carries the rule): these sets are NOT supersets of
    // each other — each carries its own membership. Do not merge them, and do
    // not collapse `articles` onto `indexers`/`default`. `indexers` above stays
    // the kind-0 / kind-3 / kind-10002 discovery pool and is NOT one of these.

    /// `default` — the core read/write relays a fresh account talks to. Also
    /// the fallback union for surfaces that don't need a specific role.
    nonisolated static let defaults: [String] = [
        "wss://nos.lol",
        "wss://relay.primal.net",
        "wss://relay.nostr.net"
    ]

    /// `members` — the Pantry, `wss://pantry.zap.cooking`. Writes and
    /// non-public reads are NIP-42 auth-gated. Nourish kind-30078 reads are
    /// **public** when the filter pins `authors` to the Nourish service pubkey
    /// and `kinds` to `[30078]` exclusively (`isPublicNourishFilter`); extra
    /// `#d`/`#l`/limit only narrow. Use `RelayPool.query`, not
    /// `GroupRelayPool` — issue #6 does not block this path. An AUTH
    /// challenge on that pinned REQ is a policy regression, not an empty
    /// corpus.
    nonisolated static let members: [String] = [
        "wss://pantry.zap.cooking"
    ]

    /// `discovery` — food/content discovery (trend, exploration). Distinct from
    /// `indexers` (which is for kind-0/3/10002 author discovery) and from
    /// `articles` (the recipe read union).
    nonisolated static let discovery: [String] = [
        "wss://nostr.wine",
        "wss://relay.primal.net",
        "wss://purplepag.es"
    ]

    /// `profiles` — the canonical profiles relay other clients write kind-0 to
    /// for cross-client discovery. Single relay by design.
    nonisolated static let profiles: [String] = [
        "wss://purplepag.es"
    ]

    /// `articles` — the **recipe** read union. Recipes are kind-30023 on the
    /// PUBLIC article relays, NOT on Pantry (build spec §2). Treat as a union
    /// — coverage is uneven (`nostr.wine` has probed at 0), so recipe reads fan
    /// out across the whole set and dedupe by addressable coordinate. Adding
    /// Pantry here would NOT help recipe loading and would add an auth hurdle.
    nonisolated static let articles: [String] = [
        "wss://relay.primal.net",
        "wss://nos.lol",
        "wss://nostr.wine",
        "wss://eden.nostr.land",
        "wss://relay.noswhere.com"
    ]
}
