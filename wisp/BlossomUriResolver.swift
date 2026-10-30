import Foundation
import CryptoKit

/// Turns a BUD-10 `blossom:` URI into a concrete https URL by fetching the
/// blob from the servers that might hold it — the URI's own `xs` hints
/// first, then the signed-in account's configured Blossom servers — on the
/// BUD-01 route (`https://<server>/<sha256>`), and verifying each download's
/// SHA-256 against the URI's hash before trusting it: the URI is
/// content-addressed, so a server answering 200 with the wrong bytes (a
/// "404 image", or a planted blob) is rejected and the next candidate is
/// tried. Amethyst verifies the same way. Candidates are tried sequentially
/// so a bad server costs one download, not N. Resolutions are cached per
/// URI — the inline view, the media grid and the full-screen pager can each
/// ask for the same URI in one render — and misses for five minutes, so an
/// unreachable blob isn't re-fetched on every scroll.
actor BlossomUriResolver {
    static let shared = BlossomUriResolver()

    private var resolved: [String: String] = [:]
    private var misses: [String: Date] = [:]
    private var inFlight: [String: Task<String?, Never>] = [:]

    private static let missTTL: TimeInterval = 5 * 60
    /// GET-and-verify downloads whole blobs (hash-checked before use), so
    /// the per-attempt budget has room for a multi-MB image on a slow server.
    private let probeSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 25
        return URLSession(configuration: config)
    }()

    func resolve(_ rawUri: String) async -> String? {
        if let hit = resolved[rawUri] { return hit }
        if let at = misses[rawUri], Date().timeIntervalSince(at) < Self.missTTL { return nil }

        // One resolution per URI at a time — the feed view, the media grid and
        // the pager asking together share it instead of each re-downloading.
        if let task = inFlight[rawUri] { return await task.value }
        let task = Task<String?, Never> { await self.probe(rawUri) }
        inFlight[rawUri] = task
        let hit = await task.value
        inFlight[rawUri] = nil

        if let hit {
            resolved[rawUri] = hit
        } else {
            misses[rawUri] = Date()
        }
        return hit
    }

    private func probe(_ rawUri: String) async -> String? {
        guard let uri = BlossomUri.parse(rawUri) else { return nil }
        var servers = uri.serverHints
        if let pubkey = NostrKey.load()?.pubkey {
            servers.append(contentsOf: BlossomServerList.cached(for: pubkey))
        }
        var seen = Set<String>()
        let candidates = servers.filter { seen.insert($0).inserted }.map { uri.candidateUrls($0) }

        for candidate in candidates {
            if let hit = await fetchVerified(urlString: candidate, sha256: uri.sha256) {
                return hit
            }
        }
        return nil
    }

    /// GETs the blob and returns the URL only when the bytes hash to `sha256`.
    private func fetchVerified(urlString: String, sha256: String) async -> String? {
        guard let url = URL(string: urlString) else { return nil }
        guard let (data, response) = try? await probeSession.data(from: url),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode)
        else { return nil }
        let digestHex = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return digestHex == sha256.lowercased() ? url.absoluteString : nil
    }
}
