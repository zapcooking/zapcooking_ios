import Foundation

extension RelayDefaults {
    /// Relays **confirmed** shut down. Every ingest point that writes a relay
    /// list into local state or into a to-be-published kind-10002 / kind-10050
    /// filters against this set (`RelayDecommission`), and `RelayListRepair`
    /// republishes an account's kind-10002 once without them.
    ///
    /// **Ships empty, on purpose.** The only candidate, `relay.damus.io`, was
    /// probed on 2026-09-07 (17:07 UTC) with a real websocket client: full
    /// handshake, kind-1 events with `created_at` within 5 s of wall-clock,
    /// EOSE, NIP-11 `strfry 1.1.0`. The "shut down end of July 2026" claim
    /// behind iOS #2 / Android #205 came from an HTTP/1.1 upgrade attempt that
    /// Cloudflare answers with 503 — an artifact of the probe, not of the relay.
    ///
    /// Rules for adding an entry:
    ///   - Only on a confirmed shutdown: the host no longer resolves, or the
    ///     operator announced it. A 503 on an HTTP upgrade is not evidence.
    ///   - Record the probe date and method in a comment beside the entry.
    ///   - Retire the entry once the host stops resolving for good; a dead
    ///     host is filtered by connection failure anyway, and the list should
    ///     not grow forever.
    ///   - The set is version-hashed (`RelayDecommission.version`), so any
    ///     change re-runs the one-time repair once per account.
    ///
    /// **Duplicated by hand**, like `HiddenRecipes`: keep in lockstep with
    /// Android `DEAD_RELAYS` (proposed in zap_cooking_android#203). Web never
    /// publishes a relay list and has no counterpart.
    ///
    /// "Dead" for *origination* is decided by a live probe, not by this set —
    /// see `RelayProber.probedFallback`. This set exists only for relays we
    /// would otherwise re-sign out of a user's existing list, where probing is
    /// unsafe (auth-gated, paid, private, or briefly-down relays would be
    /// stripped too).
    nonisolated static let decommissioned: Set<String> = []
}

/// Filters for `RelayDefaults.decommissioned`. Matching is by canonical host:
/// `wss://Relay.Example/` and `wss://relay.example/inbox` are the same dead
/// relay. Every function is a fixed point — pruning a pruned list changes
/// nothing — and returns its input untouched when the set is empty.
nonisolated enum RelayDecommission {

    /// Canonical lowercase host of a relay URL, or nil for anything
    /// `RelayUrlValidator.normalize` rejects.
    static func host(of url: String) -> String? {
        guard let normalized = RelayUrlValidator.normalize(url),
              let host = URL(string: normalized)?.host?.lowercased(),
              !host.isEmpty else { return nil }
        return host
    }

    static func hosts(of set: Set<String>) -> Set<String> {
        Set(set.compactMap(host(of:)))
    }

    static func isDecommissioned(
        _ url: String,
        in set: Set<String> = RelayDefaults.decommissioned
    ) -> Bool {
        guard !set.isEmpty, let h = host(of: url) else { return false }
        return hosts(of: set).contains(h)
    }

    /// Drop decommissioned relays from a NIP-65 list. Order and every
    /// `read` / `write` / `auth` flag of the survivors are untouched.
    static func prune(
        _ relays: [GeneralRelay],
        decommissioned set: Set<String> = RelayDefaults.decommissioned
    ) -> [GeneralRelay] {
        guard !set.isEmpty else { return relays }
        let dead = hosts(of: set)
        return relays.filter { r in
            guard let h = host(of: r.url) else { return true }
            return !dead.contains(h)
        }
    }

    /// Drop decommissioned relays from a plain URL list (kind-10050 style).
    static func prune(
        urls: [String],
        decommissioned set: Set<String> = RelayDefaults.decommissioned
    ) -> [String] {
        guard !set.isEmpty else { return urls }
        let dead = hosts(of: set)
        return urls.filter { u in
            guard let h = host(of: u) else { return true }
            return !dead.contains(h)
        }
    }

    /// Prune a **signed event's tags**, for the one-time republish.
    ///
    /// This deliberately operates on the fetched event's raw tags, NOT on the
    /// parsed `[GeneralRelay]` and NOT via `Nip51Lists.buildGeneralRelayTags`.
    /// Only `r` / `relay` tags whose URL is a decommissioned host are removed;
    /// every other tag — the surviving relays' `read` / `write` markers, their
    /// order, any extra positional fields, and any non-relay tag another
    /// client wrote (`client`, `alt`, …) — is carried into the republished
    /// event byte-for-byte. That preservation is what makes republishing a
    /// user's own list safe. A parse → rebuild round trip would silently
    /// normalise URLs, drop unknown tags, and collapse marker spellings, and
    /// that is a change to signed user data the user did not ask for. Do not
    /// refactor this onto the parser.
    ///
    /// `removed` lists the raw URLs dropped, in tag order, for logging and for
    /// the "no-op when clean" decision (`removed.isEmpty`).
    static func pruneTags(
        _ tags: [[String]],
        decommissioned set: Set<String> = RelayDefaults.decommissioned
    ) -> (tags: [[String]], removed: [String]) {
        guard !set.isEmpty else { return (tags, []) }
        let dead = hosts(of: set)
        var kept: [[String]] = []
        var removed: [String] = []
        for tag in tags {
            if tag.count >= 2, tag[0] == "r" || tag[0] == "relay",
               let h = host(of: tag[1]), dead.contains(h) {
                removed.append(tag[1])
                continue
            }
            kept.append(tag)
        }
        return (kept, removed)
    }

    /// Stable identity of a set's contents, used as the once-per-account
    /// repair marker value so a later addition re-runs the repair exactly once.
    static func version(of set: Set<String> = RelayDefaults.decommissioned) -> String {
        let hosts = hosts(of: set).sorted()
        return hosts.isEmpty ? "empty" : hosts.joined(separator: ",")
    }
}
