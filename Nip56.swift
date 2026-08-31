import Foundation

/// NIP-56 reporting (kind 1984). Port of Android `nostr/Nip56.kt`.
///
/// A report carries the reported pubkey as a typed `p` tag and, for a specific
/// event, the reported id as a typed `e` tag. The human-facing category
/// (e.g. Child Safety / CSAM) is mapped onto the closest NIP-56 standard type
/// for interoperability; the precise label is preserved in content so
/// moderators can distinguish CSAM from generic "illegal".
nonisolated enum Nip56 {

    static let kindReport = 1984

    /// User-facing report categories. `nip56Type` is the standard NIP-56
    /// report-type emitted on the p/e tags; `label` is the precise category
    /// recorded in the report content.
    ///
    /// NIP-56 standard types: nudity, malware, profanity, illegal, spam,
    /// impersonation, other. "Child Safety / CSAM" and "Harassment" have no
    /// dedicated type, so they map to the closest bucket (illegal / other)
    /// and stay explicit via the label in content.
    enum ReportCategory: String, CaseIterable, Sendable {
        case childSafety
        case spam
        case harassment
        case illegal
        case other

        var nip56Type: String {
            switch self {
            case .childSafety, .illegal: return "illegal"
            case .spam: return "spam"
            case .harassment, .other: return "other"
            }
        }

        var label: String {
            switch self {
            case .childSafety: return "Child Safety / CSAM"
            case .spam: return "Spam"
            case .harassment: return "Harassment"
            case .illegal: return "Illegal content"
            case .other: return "Other"
            }
        }
    }

    /// Known Pantry moderation pubkeys. Reports are addressed to these
    /// (extra `p` tags) so ops can find them via `kinds:[1984] #p:<admin>`.
    static let pantryModAdmins: [String] = [
        "a723805cda67251191c8786f4da58f797e6977582301354ba8e91bcb0342dc9c",
        "319ad3e790634dbe86f14db9c2995b26ee3c6228be55f89c4c7fea9acc01d50a",
    ]

    /// NIP-56 standard report types (3rd element of a typed report `p`/`e` tag).
    static let reportTypes: Set<String> = [
        "nudity", "malware", "profanity", "illegal", "spam", "impersonation", "other",
    ]

    /// Build the tags for a kind-1984 report. Matches Android `buildReportTags`.
    static func buildReportTags(
        reportedPubkey: String,
        category: ReportCategory,
        eventId: String? = nil,
        groupId: String? = nil,
        recipients: [String] = []
    ) -> [[String]] {
        var tags: [[String]] = [["p", reportedPubkey, category.nip56Type]]
        if let eventId, !eventId.isEmpty {
            tags.append(["e", eventId, category.nip56Type])
        }
        if let groupId, !groupId.isEmpty {
            tags.append(["h", groupId])
        }
        var seen = Set<String>([reportedPubkey])
        for recipient in recipients where !recipient.isEmpty && seen.insert(recipient).inserted {
            tags.append(["p", recipient])
        }
        return tags
    }

    /// Report content = the precise category label, plus the optional reason.
    static func reportContent(category: ReportCategory, reason: String) -> String {
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "[\(category.label)]"
        }
        return "[\(category.label)] \(trimmed)"
    }

    /// A parsed kind-1984 report.
    struct ReportInfo: Equatable, Sendable {
        var id: String
        var reporterPubkey: String
        var reportedPubkey: String
        var categoryLabel: String
        var reason: String
        var reportedEventId: String?
        var groupId: String?
        var createdAt: Int
    }

    /// Parse a kind-1984 event, or nil if it isn't a usable report.
    ///
    /// The reported user is the `p` tag whose 3rd element is a known NIP-56
    /// report type; a routing/admin `p` tag whose 3rd element is a relay hint
    /// is not mistaken for it.
    static func parseReport(_ event: NostrEvent) -> ReportInfo? {
        guard event.kind == kindReport else { return nil }
        let typedP = event.tags.first(where: {
            $0.count >= 3 && $0[0] == "p" && reportTypes.contains($0[2])
        }) ?? event.tags.first(where: { $0.count >= 3 && $0[0] == "p" })
        guard let typedP, typedP.count >= 2 else { return nil }

        let reportedPubkey = typedP[1]
        let reportedEventId = event.tags.first(where: { $0.count >= 2 && $0[0] == "e" })?[1]
        let groupId = event.tags.first(where: { $0.count >= 2 && $0[0] == "h" })?[1]

        let trimmed = event.content.trimmingCharacters(in: .whitespacesAndNewlines)
        var label = typedP.count >= 3 ? typedP[2] : ""
        var reason = trimmed
        // `[Label] optional reason` — Android CONTENT_REGEX, including reasons
        // that span newlines (DOT_MATCHES_ALL).
        if trimmed.first == "[",
           let close = trimmed.firstIndex(of: "]") {
            let captured = String(trimmed[trimmed.index(after: trimmed.startIndex)..<close])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !captured.isEmpty { label = captured }
            let after = trimmed.index(after: close)
            reason = String(trimmed[after...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return ReportInfo(
            id: event.id,
            reporterPubkey: event.pubkey,
            reportedPubkey: reportedPubkey,
            categoryLabel: label,
            reason: reason,
            reportedEventId: reportedEventId,
            groupId: groupId,
            createdAt: event.createdAt
        )
    }
}
