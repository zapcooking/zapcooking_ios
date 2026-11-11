import Foundation

/// The feed relay's topic list for spotlight cards: one plain HTTPS GET of
/// its NIP-11 document (web `topicList.ts` `loadTopics`), parsed by
/// `FreshTopicCatalog`. Approved by Seth 2026-11-11 for the app: no key, no
/// cookies, cached, never retried in a tight loop.
///
/// - The request is `GET https://feed.zap.cooking` with `Accept:
///   application/nostr+json` and nothing else: no cookies sent or stored,
///   no URL cache, no credentials. It names no reader.
/// - A usable answer (at least one topic group) is kept for
///   `successLifetime`. Callers in that window get it without a request.
/// - A failure (no connection, a non-2xx status, a body that isn't a topic
///   list, an oversized body) is never shown as an error. With no list yet
///   it is `.empty`, which means no spotlights. A list that expired is kept
///   instead, until a new one arrives. The next request waits out a hold
///   that grows with failures in a row (`failureHolds`), and callers during
///   the hold get the same answer without a request.
/// - Callers that arrive while a request is in flight share it.
///
/// ≠ web: web keeps the list for the whole tab session and asks again on
/// the very next call after a failure. Here a list expires after six hours
/// and a failure is held for 2 min, then 5, 15 and 30 min.
actor FreshTopicList {
    static let shared = FreshTopicList()

    /// How long a usable list is kept.
    static let successLifetime: TimeInterval = 6 * 60 * 60
    /// Waits after the 1st, 2nd, 3rd… failure in a row; the last repeats.
    static let failureHolds: [TimeInterval] = [2 * 60, 5 * 60, 15 * 60, 30 * 60]
    /// A NIP-11 document bigger than this is not a topic list.
    static let maxBodyBytes = 1_000_000

    private let url: URL
    private let fetch: @Sendable (URLRequest) async throws -> (Data, URLResponse)
    private let now: @Sendable () -> Date
    private let enabled: @Sendable () -> Bool

    private var cached: (catalog: FreshTopicCatalog, at: Date)?
    private var failures = 0
    private var failedAt: Date?
    private var inFlight: Task<FreshTopicCatalog?, Never>?
    /// Requests sent (tests).
    private(set) var requestCount = 0

    init(
        relayUrl: String = FeedRelay.url,
        fetch: (@Sendable (URLRequest) async throws -> (Data, URLResponse))? = nil,
        now: @escaping @Sendable () -> Date = { Date() },
        enabled: @escaping @Sendable () -> Bool = { FeatureFlags.freshSpecialsEnabled }
    ) {
        self.url = URL(string: FreshTopicCatalog.nip11Url(relayUrl))!
        let session = Self.makeSession()
        self.fetch = fetch ?? { try await session.data(for: $0) }
        self.now = now
        self.enabled = enabled
    }

    /// The session for the GET: ephemeral, no cookies in or out, no URL
    /// cache, short timeouts.
    nonisolated static func makeSession(protocolClasses: [AnyClass]? = nil) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.urlCredentialStorage = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        config.waitsForConnectivity = false
        if let protocolClasses { config.protocolClasses = protocolClasses }
        return URLSession(configuration: config)
    }

    /// The request: a GET with only the NIP-11 `Accept` header.
    nonisolated static func request(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.setValue("application/nostr+json", forHTTPHeaderField: "Accept")
        return request
    }

    /// Seconds until a failed list may be asked for again (0 = now).
    func holdLeft() -> TimeInterval {
        guard let failedAt, failures > 0 else { return 0 }
        let hold = Self.failureHolds[min(failures, Self.failureHolds.count) - 1]
        return max(0, failedAt.addingTimeInterval(hold).timeIntervalSince(now()))
    }

    /// The topic groups, or [] (no spotlights) while there is no list.
    func groups() async -> [FreshTopicGroup] {
        await catalog().groups
    }

    /// The catalog: the kept one while it is fresh, else one request (shared
    /// by concurrent callers) unless a failure hold is running.
    func catalog() async -> FreshTopicCatalog {
        guard enabled() else { return .empty }
        if let cached, now().timeIntervalSince(cached.at) < Self.successLifetime {
            return cached.catalog
        }
        let stale = cached?.catalog ?? .empty
        if let inFlight {
            return await inFlight.value ?? stale
        }
        guard holdLeft() == 0 else { return stale }
        requestCount += 1
        let fetch = self.fetch
        let request = Self.request(url)
        let task = Task<FreshTopicCatalog?, Never> {
            guard let (data, response) = try? await fetch(request),
                  let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                  data.count <= Self.maxBodyBytes else { return nil }
            let catalog = FreshTopicCatalog.parse(nip11: data)
            return catalog.groups.isEmpty ? nil : catalog
        }
        inFlight = task
        let result = await task.value
        inFlight = nil
        if let result {
            cached = (result, now())
            failures = 0
            failedAt = nil
        } else {
            failures += 1
            failedAt = now()
        }
        return result ?? stale
    }
}
