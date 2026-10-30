import Foundation

/// Turns a BUD-10 `blossom:` URI into a concrete https URL by probing the
/// servers that might hold the blob — the URI's own `xs` hints first, then
/// the signed-in account's configured Blossom servers — with HEAD requests
/// on the BUD-01 route (`https://<server>/<sha256>`); the first 200 wins.
/// Mirrors amethyst's resolver. Resolutions are cached per URI — the inline
/// view, the media grid and the full-screen pager can each ask for the same
/// URI in one render — and misses for five minutes, so an unreachable blob
/// isn't re-probed on every scroll.
actor BlossomUriResolver {
    static let shared = BlossomUriResolver()

    private var resolved: [String: String] = [:]
    private var misses: [String: Date] = [:]
    private var inFlight: [String: Task<String?, Never>] = [:]

    private static let missTTL: TimeInterval = 5 * 60
    /// Probes are cheap and must fail fast — the caller is a view waiting to
    /// draw an image, so a dead hint costs at most ~6s, not a full request TTL.
    private let probeSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 6
        config.timeoutIntervalForResource = 10
        return URLSession(configuration: config)
    }()

    func resolve(_ rawUri: String) async -> String? {
        if let hit = resolved[rawUri] { return hit }
        if let at = misses[rawUri], Date().timeIntervalSince(at) < Self.missTTL { return nil }

        // One resolution per URI at a time — the feed view, the media grid and
        // the pager asking together share it instead of each firing HEADs.
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

        return await withTaskGroup(of: String?.self) { group in
            for candidate in candidates {
                group.addTask { await self.headOk(candidate) }
            }
            for await hit in group where hit != nil {
                group.cancelAll()
                return hit
            }
            return nil
        }
    }

    private func headOk(_ url: String) async -> String? {
        guard let url = URL(string: url) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        guard let (_, response) = try? await probeSession.data(for: request),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode)
        else { return nil }
        return url.absoluteString
    }
}
