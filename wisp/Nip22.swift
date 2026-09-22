import Foundation

/// NIP-22 comments (kind 1111).
///
/// A comment is always scoped to a root — either a nostr event (`E`/`A` tags)
/// or an external identifier (`I` tag, per NIP-73: a URL, podcast GUID,
/// geohash, ISBN…). Uppercase tags name the *root* scope, lowercase name the
/// *immediate parent*, so a top-level comment repeats the same value in both.
///
/// Two jobs. Rendering: recover enough context that a comment on a web page
/// doesn't read as a stray remark with no subject — see `ExternalRef`.
/// Composing: a reply to an externally-rooted comment must itself be a
/// kind 1111 with the root's `I`/`K` tags, never a kind 1 with NIP-10 tags
/// — see `buildReplyTags(to:relayHint:)` and `ComposeViewModel`.
nonisolated enum Nip22 {
    static let kindComment = 1111

    /// The external thing a comment is scoped to, when the scope isn't a
    /// nostr event. `kind` is NIP-73's identifier type (`web`, `podcast:item:guid`,
    /// `isbn`, …); `value` is the identifier itself.
    struct ExternalRef: Equatable {
        let value: String
        let kind: String
        /// Optional hint from the tag's third position — for non-URL
        /// identifiers this is where a human-openable page lives (e.g. a
        /// podcast GUID pointing at its episode page).
        let hint: String?

        /// The URL a "view the original" affordance should open, if any.
        /// Prefers the hint, since for non-`web` kinds the value itself isn't
        /// openable (`podcast:item:guid:…` is an identifier, not a link).
        var openableURL: URL? {
            if let hint, let url = URL(string: hint), url.scheme?.hasPrefix("http") == true {
                return url
            }
            guard kind == "web", let url = URL(string: value),
                  url.scheme?.hasPrefix("http") == true else { return nil }
            return url
        }

        /// Host shown as the source label, e.g. "bitcoinmagazine.com".
        var displayHost: String? {
            guard let host = openableURL?.host else { return nil }
            return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        }
    }

    static func isComment(_ event: NostrEvent) -> Bool { event.kind == kindComment }

    /// The comment's root scope when it's external (an `I` tag), else nil.
    ///
    /// Returns nil for comments rooted on a nostr event — those already render
    /// with their parent inline, so they need no extra treatment.
    static func externalRoot(of event: NostrEvent) -> ExternalRef? {
        guard isComment(event) else { return nil }
        // A comment scoped to a nostr event carries E/A; only treat I as the
        // root when neither is present, matching the spec's "root scope"
        // exclusivity.
        let hasEventRoot = event.tags.contains { $0.first == "E" || $0.first == "A" }
        guard !hasEventRoot else { return nil }
        guard let iTag = event.tags.first(where: { $0.count >= 2 && $0[0] == "I" }) else { return nil }
        let kind = event.tags.first(where: { $0.count >= 2 && $0[0] == "K" })?[1] ?? "web"
        let hint = iTag.count >= 3 && !iTag[2].isEmpty ? iTag[2] : nil
        return ExternalRef(value: iTag[1], kind: kind, hint: hint)
    }

    /// The comment's immediate parent when it's external (a lowercase `i` tag).
    /// Equals the root for a top-level comment; differs when replying to
    /// another comment on the same external item.
    static func externalParent(of event: NostrEvent) -> ExternalRef? {
        guard isComment(event) else { return nil }
        let hasEventParent = event.tags.contains { $0.first == "e" || $0.first == "a" }
        guard !hasEventParent else { return nil }
        guard let iTag = event.tags.first(where: { $0.count >= 2 && $0[0] == "i" }) else { return nil }
        let kind = event.tags.first(where: { $0.count >= 2 && $0[0] == "k" })?[1] ?? "web"
        let hint = iTag.count >= 3 && !iTag[2].isEmpty ? iTag[2] : nil
        return ExternalRef(value: iTag[1], kind: kind, hint: hint)
    }

    // MARK: - Event-rooted comments

    // A comment can be scoped to a nostr event instead of an external
    // identifier, and in the wild that root is very often a plain kind-1
    // note: a thread starts in NIP-10 and a participant's client switches to
    // comments partway down, carrying `E` = the kind-1 root with `K` = "1".
    // Sidecar captured exactly that shape off public relays
    // (dmnyc/sidecar#326). Only the external (`I`) side was read here before,
    // so those comments were invisible to counting and notifications.

    /// The event this comment is rooted on (uppercase `E`), or nil when the
    /// root is external or addressable.
    static func rootEventId(of event: NostrEvent) -> String? {
        tagValue(event, "E")
    }

    /// The kind of the root the comment is scoped to (uppercase `K`). A
    /// string on the wire, because an external root names a NIP-73 type
    /// (`web`, `podcast:item:guid`) rather than a number.
    static func rootKindRaw(of event: NostrEvent) -> String? {
        tagValue(event, "K")
    }

    /// Author of the root event (uppercase `P`).
    static func rootAuthor(of event: NostrEvent) -> String? {
        tagValue(event, "P")
    }

    /// The comment's immediate parent event (lowercase `e`). Equals the root
    /// for a top-level comment; points at another comment further down.
    static func parentEventId(of event: NostrEvent) -> String? {
        tagValue(event, "e")
    }

    /// The immediate parent's kind (lowercase `k`).
    ///
    /// This is the tag that decides whether someone answered a note or a
    /// comment, which is the distinction Sidecar labels and the reason this
    /// is carried onto the notification row rather than discarded.
    static func parentKindRaw(of event: NostrEvent) -> String? {
        tagValue(event, "k")
    }

    /// The immediate parent's kind as an integer, or nil when the parent is
    /// an external identifier (`k` = "web" and friends).
    static func parentKind(of event: NostrEvent) -> Int? {
        parentKindRaw(of: event).flatMap(Int.init)
    }

    /// Author of the immediate parent (lowercase `p`).
    static func parentAuthor(of event: NostrEvent) -> String? {
        tagValue(event, "p")
    }

    /// First value of the first tag with this exact name. Case matters — `E`
    /// and `e` mean different things in this NIP, so this deliberately does
    /// not fold case.
    private static func tagValue(_ event: NostrEvent, _ name: String) -> String? {
        guard let tag = event.tags.first(where: { $0.count >= 2 && $0[0] == name }),
              !tag[1].isEmpty else { return nil }
        return tag[1]
    }

    /// Build the tag set for a kind-1111 reply to `parent`, carrying its root
    /// scope forward unchanged and pointing the lowercase tags at `parent`.
    ///
    /// Only the external-root case is supported, which is the one Wisp can
    /// currently reply to.
    static func buildReplyTags(to parent: NostrEvent, relayHint: String = "") -> [[String]]? {
        guard let root = externalRoot(of: parent) else { return nil }

        var tags: [[String]] = []
        var rootTag = ["I", root.value]
        if let hint = root.hint { rootTag.append(hint) }
        tags.append(rootTag)
        tags.append(["K", root.kind])

        // Parent is the comment itself — an event — so the lowercase side uses
        // e/k/p rather than repeating the I tag.
        tags.append(["e", parent.id, relayHint, parent.pubkey])
        tags.append(["k", String(kindComment)])
        tags.append(["p", parent.pubkey])

        // Carry the root author forward when the parent named one.
        if let rootAuthor = parent.tags.first(where: { $0.count >= 2 && $0[0] == "P" }) {
            tags.append(rootAuthor)
        }
        return tags
    }
}
