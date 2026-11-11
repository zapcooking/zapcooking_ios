import Foundation

/// A BUD-10 `blossom:` media reference — `blossom:<sha256>[.<ext>][?params]`.
/// Content-addressed, so it names no server: resolution hints ride in the
/// query — repeatable `xs` (servers that hold the blob), `as` (author hex
/// pubkey, whose kind:10063 list may hold more servers), and `sz` (blob size
/// in bytes). Kept Foundation-only so the test suite can pin the format.
struct BlossomUri: Equatable {
    let sha256: String
    let ext: String?
    let serverHints: [String]
    let authors: [String]
    let sizeBytes: Int?

    static let scheme = "blossom:"
    private static let hex64Regex = try! NSRegularExpression(pattern: #"^[0-9a-f]{64}$"#, options: [.caseInsensitive])

    static func parse(_ raw: String) -> BlossomUri? {
        guard raw.lowercased().hasPrefix(scheme) else { return nil }
        let reference = String(raw.dropFirst(scheme.count))
        let queryStart = reference.firstIndex(of: "?")
        let hashPart = queryStart.map { String(reference[..<$0]) } ?? reference
        let query = queryStart.map { String(reference[reference.index(after: $0)...]) }

        let hashSegments = hashPart.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        guard let hash = hashSegments.first, isHex64(String(hash)) else { return nil }
        let ext: String? = hashSegments.count > 1
            ? hashSegments[1].isEmpty
                ? nil
                : hashSegments[1].allSatisfy { $0.isLetter || $0.isNumber } ? hashSegments[1].lowercased() : nil
            : nil

        var hints: [String] = []
        var authors: [String] = []
        var sizeBytes: Int? = nil
        if let query {
            for pair in query.split(separator: "&") {
                guard let eq = pair.firstIndex(of: "=") else { continue }
                let key = pair[..<eq]
                let value = String(pair[pair.index(after: eq)...])
                switch key {
                case "xs": if !value.isEmpty { hints.append(value) }
                case "as": if isHex64(value) { authors.append(value.lowercased()) }
                case "sz": sizeBytes = Int(value)
                default: break
                }
            }
        }
        return BlossomUri(sha256: hash.lowercased(), ext: ext, serverHints: hints, authors: authors, sizeBytes: sizeBytes)
    }

    /// The BUD-01 blob route on `server` — `https://<host>/<sha256>`, without
    /// the extension: the bare hash is the canonical GET, and some servers 404
    /// the extended path. A hint that already carries a scheme is used as-is.
    func candidateUrls(_ server: String) -> String {
        var base = server.contains("://") ? server : "https://\(server)"
        while base.hasSuffix("/") { base.removeLast() }
        return "\(base)/\(sha256)"
    }

    private static func isHex64(_ value: String) -> Bool {
        hex64Regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
    }
}
