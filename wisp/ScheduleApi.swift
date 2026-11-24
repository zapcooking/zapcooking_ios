import Foundation

/// Client for Zap Cooking's scheduled-posts API.
///
/// **The contract is `docs/schedule-contract.md` on `main` in
/// `zapcooking/frontend`.** Web, Android and iOS all schedule through it; this
/// file follows it and web's `src/lib/scheduleClient.ts`, so a post scheduled
/// on one client appears in, and can be cancelled from, the others. Where this
/// file and the contract disagree, the contract wins.
///
/// The model: the event is signed on the device with `created_at` set to the
/// publish time, then POSTed. The server holds no key and cannot alter it; a
/// sweep broadcasts it, unchanged, when its time comes.
///
/// Three things here are deliberate and easy to undo by accident:
/// - **Every request signs its own NIP-98 header** through `Nip98.authHeader`,
///   never `Nip98HeaderCache`. The contract says not to reuse one.
/// - **A 401 is retried once with a freshly signed header**, wherever the
///   first came from (the usual cause is a header that aged past 60 s behind a
///   remote signer's prompt).
/// - **The error code is in the body's `error` field** (`ZapCookingApi` reads
///   `code`), and callers branch on it, never on the HTTP status alone. A code
///   this client does not know is `.unknown`: codes may be added.
nonisolated enum ScheduleApi {

    static let origin = "https://zap.cooking"
    static let path = "/api/schedule"

    // MARK: - Times

    /// The earliest time a date picker should offer (contract: clients enforce
    /// 5 minutes; the server's own floor is 120 s).
    static let pickerMinLeadSeconds = 5 * 60
    /// Checked at the point of signing: the picked time must still be more
    /// than this far off, so the request cannot reach the server inside its
    /// 120 s floor after a signer prompt and a round trip.
    static let signMinLeadSeconds = 3 * 60
    /// Strictly less than 90 days out.
    static let maxLeadSeconds = 90 * 86_400

    // MARK: - Relays

    /// At most this many client relays (the sweep opens 2 fixed + 4).
    static let maxRelays = 4
    /// Each relay URL must be shorter than this.
    static let maxRelayUrlLength = 200

    /// The two relays the sweep always publishes to in `all` mode
    /// (`SCHEDULER_FLOOR_RELAYS` in the frontend's `workers/cron/sweep.ts`).
    /// Sending them is harmless but spends two of the four places.
    static let floorRelays = ["wss://nos.lol", "wss://relay.primal.net"]

    /// Relays that never store a note. This is `ENDED_HOST_RELAYS_NEVER` in
    /// the frontend's `src/lib/live/endedEvent.ts`; keep the two lists the
    /// same. purplepag.es holds profiles and relay lists only.
    static let relaysNeverStoringNotes = ["wss://purplepag.es"]

    /// `PRIVATE_SUFFIXES` in the frontend's `src/lib/live/endedEvent.ts`.
    private static let privateSuffixes = [
        ".local", ".localhost", ".localdomain", ".internal", ".intranet",
        ".private", ".corp", ".home", ".lan", ".home.arpa", ".test",
        ".example", ".invalid", ".onion", ".i2p",
    ]

    /// Turn a relay list (the author's NIP-65 write relays, in their order)
    /// into a `relays` value the server will accept: only URLs that pass the
    /// server's own check, normalized, without duplicates, the floor relays or
    /// relays that never store notes, at most `maxRelays`. The server rejects
    /// the whole request for one bad entry, so this filter is not optional.
    ///
    /// A port of web's `pickScheduleRelays`; `ScheduleApiRelayTests` carries
    /// web's test cases so the clients agree on the same inputs.
    static func pickRelays(_ urls: [String]) -> [String] {
        let skip = Set((floorRelays + relaysNeverStoringNotes).compactMap(normalizedPublicRelay))
        var out: [String] = []
        for url in urls {
            if out.count >= maxRelays { break }
            guard url.utf16.count < maxRelayUrlLength,
                  let normalized = normalizedPublicRelay(url),
                  !skip.contains(normalized), !out.contains(normalized) else { continue }
            out.append(normalized)
        }
        return out
    }

    /// May the server open a connection to this relay? A port of
    /// `isPublicRelayUrl` in the frontend's `src/lib/live/endedEvent.ts`:
    /// `wss://` only, a public hostname (no IP literal of either family, no
    /// localhost, nothing that names a private network, at least one dot), no
    /// credentials, no whitespace, at most 200 characters.
    static func isPublicRelayUrl(_ value: String) -> Bool {
        normalizedPublicRelay(value) != nil
    }

    /// The server's canonical spelling of a relay that passes
    /// `isPublicRelayUrl`, or nil for one that does not. Mirrors
    /// `normalizeScheduleRelay` in the frontend's `src/lib/scheduleRelays.ts`:
    /// lowercase host, no default port, no trailing slash, no fragment; path
    /// and query kept as sent.
    static func normalizedPublicRelay(_ value: String) -> String? {
        guard value.utf16.count <= 200,
              !value.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) }),
              let components = URLComponents(string: value),
              components.scheme?.lowercased() == "wss",
              components.user == nil, components.password == nil,
              let rawHost = components.host?.lowercased(), !rawHost.isEmpty
        else { return nil }

        var host = rawHost
        if host.hasSuffix(".") { host.removeLast() }
        // IPv6 literal, with or without the brackets Foundation may strip.
        if host.isEmpty || host.hasPrefix("[") || host.contains(":") { return nil }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        // localhost and other single-label names.
        guard labels.count >= 2, let last = labels.last else { return nil }
        // IPv4 in any spelling: no all-numeric (or 0x…) last label.
        if isNumericLabel(last) { return nil }
        guard labels.allSatisfy(isHostLabel) else { return nil }
        if privateSuffixes.contains(where: { host == $0.dropFirst() || host.hasSuffix($0) }) { return nil }

        var out = "wss://" + rawHost
        if let port = components.port, port != 443 { out += ":\(port)" }
        var path = components.percentEncodedPath
        while path.hasSuffix("/") { path.removeLast() }
        out += path
        if let query = components.percentEncodedQuery, !query.isEmpty { out += "?" + query }
        return out
    }

    /// `^(\d+|0x[0-9a-f]*)$`
    private static func isNumericLabel(_ label: Substring) -> Bool {
        if !label.isEmpty, label.allSatisfy({ $0.isASCII && $0.isNumber }) { return true }
        guard label.hasPrefix("0x") else { return false }
        return label.dropFirst(2).allSatisfy { $0.isASCII && $0.isHexDigit }
    }

    /// `^[a-z0-9]([a-z0-9-]*[a-z0-9])?$`
    private static func isHostLabel(_ label: Substring) -> Bool {
        func alnum(_ c: Character) -> Bool { c.isASCII && (c.isLetter || c.isNumber) }
        guard let first = label.first, let last = label.last, alnum(first), alnum(last) else { return false }
        return label.allSatisfy { alnum($0) || $0 == "-" }
    }

    // MARK: - Signing

    /// Sign an event so that it publishes at `publishAt` (unix seconds):
    /// `created_at` is that time, and the event is signed once.
    ///
    /// The result is checked before it is returned, for every signer type: the
    /// event must be the one asked for (`created_at` still `publishAt`, same
    /// kind, tags, content and author) and its id and signature must verify. A
    /// signer that re-dates what it signs fails that check and comes back as
    /// `.signerChangedEvent`: posting it would schedule something other than
    /// what the person chose.
    ///
    /// Sign once. A create is retried with the same signed event; a re-signed
    /// one has a new id and would be scheduled twice. No proof of work on an
    /// event headed here: mining re-stamps `created_at`.
    static func sign(
        kind: Int,
        tags: [[String]],
        content: String,
        publishAt: Int,
        signer: any ScheduleEventSigning,
        now: Int = NostrClock.now()
    ) async -> Result<NostrEvent, ScheduleFailure> {
        guard publishAt > now + signMinLeadSeconds, publishAt < now + maxLeadSeconds else {
            return .failure(.badPublishTime)
        }
        let event: NostrEvent
        do {
            event = try await signer.signEvent(kind: kind, tags: tags, content: content, createdAt: publishAt)
        } catch is ScheduleSigningUnavailable {
            return .failure(.signedOut)
        } catch Signer.SignerError.localKeyMissing {
            return .failure(.signedOut)
        } catch Nip46.NipError.malformedResponse {
            // `Signer.sign` refuses a remote signer's event that is not the
            // one it asked for, re-dated ones included, with this error.
            return .failure(.signerChangedEvent)
        } catch {
            return .failure(.signFailed)
        }
        guard event.createdAt == publishAt,
              event.kind == kind,
              event.tags == tags,
              event.content == content,
              event.pubkey.lowercased() == signer.pubkeyHex.lowercased(),
              event.hasValidSignature() else {
            return .failure(.signerChangedEvent)
        }
        return .success(event)
    }

    // MARK: - Schedule

    /// `POST /api/schedule`. `event` comes from `sign`; `relays` is the
    /// author's NIP-65 write relays in their order, filtered here through
    /// `pickRelays` (and ignored in `pantry` mode).
    ///
    /// Safe to call again with the same event after `.network` or `.internal`:
    /// the server answers 409 for an event it already has, and that comes back
    /// as success with `alreadyScheduled` set.
    static func schedule(
        event: NostrEvent,
        relayMode: ScheduleRelayMode = .all,
        relays: [String] = [],
        signer: any Nip98Signing,
        session: URLSession
    ) async -> Result<ScheduleReceipt, ScheduleFailure> {
        // The server would answer bad_signature / pubkey_mismatch; neither
        // needs a round trip to find out.
        guard event.hasValidSignature() else { return .failure(.signerChangedEvent) }
        // `Nip98Signing` is main-actor isolated, hence the hop.
        let account = await signer.pubkeyHex
        guard event.pubkey.lowercased() == account.lowercased() else {
            return .failure(.pubkeyMismatch)
        }

        let picked = relayMode == .all ? pickRelays(relays) : []
        func post(_ withRelays: [String]) async -> Result<Response, ScheduleFailure> {
            await send(
                method: "POST", path: path,
                body: requestBody(event: event, relayMode: relayMode, relays: withRelays),
                signer: signer, session: session
            )
        }

        var sent = await post(picked)
        // Contract: on bad_relays, retry once without them so the post still
        // goes to the scheduler's own relays. `pickRelays` should make this
        // unreachable; if the server's rules tighten, it is not fatal.
        if case .success(let response) = sent, response.code == "bad_relays", !picked.isEmpty {
            sent = await post([])
        }
        let response: Response
        switch sent {
        case .failure(let failure): return .failure(failure)
        case .success(let value): response = value
        }

        if response.status == 201 {
            let body = response.object
            return .success(ScheduleReceipt(
                id: body["id"] as? String ?? event.id,
                publishAt: body["publish_at"] as? Int ?? event.createdAt,
                relayMode: (body["relay_mode"] as? String).flatMap(ScheduleRelayMode.init) ?? relayMode,
                relays: body["relays"] as? [String] ?? [],
                status: response.rowStatus ?? .pending,
                alreadyScheduled: false
            ))
        }

        if response.code == "already_scheduled",
           let status = response.rowStatus, status == .pending || status == .publishing || status == .sent {
            // An earlier attempt landed: that is the outcome the caller wanted.
            return .success(ScheduleReceipt(
                id: event.id, publishAt: event.createdAt, relayMode: relayMode,
                relays: picked, status: status, alreadyScheduled: true
            ))
        }
        return .failure(response.failure(allowing: scheduleCodes))
    }

    /// The exact bytes POSTed, and the bytes the NIP-98 `payload` tag hashes.
    static func requestBody(event: NostrEvent, relayMode: ScheduleRelayMode, relays: [String]) -> String {
        var body = "{\"event\":" + event.toJSON() + ",\"relay_mode\":\"" + relayMode.rawValue + "\""
        if !relays.isEmpty,
           let data = try? JSONSerialization.data(withJSONObject: relays, options: [.withoutEscapingSlashes]),
           let array = String(data: data, encoding: .utf8) {
            body += ",\"relays\":" + array
        }
        return body + "}"
    }

    // MARK: - List

    /// `GET /api/schedule[?status=…]`: the account's scheduled events, newest
    /// publish time first (the server's order), at most 100, no paging. Rows
    /// this client cannot read are skipped rather than failing the list.
    ///
    /// The events are not signature-checked: they come from our own server
    /// over TLS, are returned only to their author, and are only displayed.
    static func list(
        status: ScheduleStatus? = nil,
        signer: any Nip98Signing,
        session: URLSession
    ) async -> Result<[ScheduledPost], ScheduleFailure> {
        // The query string is not part of the NIP-98 `u` match: the header
        // signs the bare URL.
        let query = status.map { "?status=" + $0.rawValue } ?? ""
        switch await send(method: "GET", path: path, query: query, signer: signer, session: session) {
        case .failure(let failure):
            return .failure(failure)
        case .success(let response):
            guard response.status == 200, let items = response.object["items"] as? [Any] else {
                return .failure(response.failure(allowing: listCodes))
            }
            return .success(items.compactMap(ScheduledPost.init(row:)))
        }
    }

    // MARK: - Cancel

    /// `DELETE /api/schedule/{id}`. Only a pending post can be cancelled;
    /// `.notCancellable` carries the row's status so the UI can say what
    /// actually happened. A post that was already cancelled counts as done.
    static func cancel(
        id: String,
        signer: any Nip98Signing,
        session: URLSession
    ) async -> Result<ScheduleCancellation, ScheduleFailure> {
        // The id becomes a path segment; anything but an event id is not a row.
        guard id.utf8.count == 64, id.utf8.allSatisfy({ ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) }) else {
            return .failure(.notFound)
        }
        switch await send(method: "DELETE", path: path + "/" + id, signer: signer, session: session) {
        case .failure(let failure):
            return .failure(failure)
        case .success(let response):
            if response.status == 200, response.rowStatus == .cancelled {
                return .success(ScheduleCancellation(id: id, alreadyCancelled: false))
            }
            if response.code == "not_cancellable", response.rowStatus == .cancelled {
                return .success(ScheduleCancellation(id: id, alreadyCancelled: true))
            }
            return .failure(response.failure(allowing: cancelCodes))
        }
    }

    // MARK: - Transport

    /// A response that arrived, whatever its status.
    private struct Response {
        let status: Int
        let data: Data

        var object: [String: Any] {
            (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        }
        /// The server's `error` code, if the body carries one.
        var code: String? { object["error"] as? String }
        /// The row's status, where the server reports one.
        var rowStatus: ScheduleStatus? { (object["status"] as? String).flatMap(ScheduleStatus.init) }

        /// The failure this response stands for. A code the endpoint does not
        /// document, or no code at all, is `.unknown`.
        func failure(allowing allowed: Set<String>) -> ScheduleFailure {
            guard let code, allowed.contains(code) else { return .unknown }
            return ScheduleFailure(code: code, rowStatus: rowStatus)
        }
    }

    private static let commonCodes: Set<String> = ["auth_failed", "not_configured", "internal"]
    private static let scheduleCodes = commonCodes.union([
        "bad_request", "bad_relay_mode", "bad_relays", "bad_signature", "pubkey_mismatch",
        "bad_kind", "kind_not_allowed_for_relay_mode", "bad_publish_time", "too_large",
        "poll_closes_before_publish", "already_scheduled", "quota_exceeded", "rate_limited",
    ])
    private static let listCodes = commonCodes.union(["bad_status"])
    private static let cancelCodes = commonCodes.union(["not_found", "not_cancellable"])

    /// One authenticated request. The header is signed for this request alone
    /// and for the bare URL. On 401 the request is sent once more with a
    /// freshly signed header.
    private static func send(
        method: String,
        path: String,
        query: String = "",
        body: String? = nil,
        signer: any Nip98Signing,
        session: URLSession
    ) async -> Result<Response, ScheduleFailure> {
        let bareUrl = origin + path
        guard let url = URL(string: bareUrl + query) else { return .failure(.unknown) }
        var attempt = 0
        while true {
            let authorization: String
            do {
                authorization = try await Nip98.authHeader(
                    signer: signer, method: method, url: bareUrl, bodyString: body
                )
            } catch is Nip98.Error {
                return .failure(.signedOut)
            } catch Signer.SignerError.localKeyMissing {
                return .failure(.signedOut)
            } catch {
                return .failure(.signFailed)
            }

            var request = URLRequest(url: url)
            request.httpMethod = method
            request.setValue(authorization, forHTTPHeaderField: "Authorization")
            if let body {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = Data(body.utf8)
            }

            let data: Data
            let status: Int
            do {
                let (bytes, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else { return .failure(.network) }
                data = bytes
                status = http.statusCode
            } catch {
                return .failure(.network)
            }
            if status == 401, attempt == 0 {
                attempt += 1
                continue
            }
            return .success(Response(status: status, data: data))
        }
    }
}

// MARK: - Signing seam

/// Signs the event to be scheduled. Production is `AccountScheduleSigner`
/// (local key or NIP-46 remote signer, through `Signer`); tests stand in
/// signers that re-date or corrupt what they sign.
nonisolated protocol ScheduleEventSigning: Sendable {
    var pubkeyHex: String { get }
    func signEvent(kind: Int, tags: [[String]], content: String, createdAt: Int) async throws -> NostrEvent
}

/// Thrown by a signer for an account that cannot sign at all (watch-only).
nonisolated struct ScheduleSigningUnavailable: Error {}

/// The account's own signer, for the scheduled event.
nonisolated struct AccountScheduleSigner: ScheduleEventSigning {
    let keypair: Keypair

    var pubkeyHex: String { keypair.pubkey }

    func signEvent(kind: Int, tags: [[String]], content: String, createdAt: Int) async throws -> NostrEvent {
        guard Signer.canSign(keypair) else { throw ScheduleSigningUnavailable() }
        return try await Signer.sign(
            keypair: keypair, kind: kind, tags: tags, content: content, createdAt: createdAt
        )
    }
}

// MARK: - Models

nonisolated enum ScheduleStatus: String, Sendable, CaseIterable {
    /// Waiting for its time, or to be retried. The only cancellable status.
    case pending
    /// The sweep has claimed it and is broadcasting right now.
    case publishing
    /// At least one relay accepted it. Final.
    case sent
    /// Gave up: 10 failed attempts, or unsent 24 hours after its time. Final.
    case failed
    /// Cancelled by the author. Final.
    case cancelled
}

nonisolated enum ScheduleRelayMode: String, Sendable {
    /// The scheduler's public relays plus the author's own.
    case all
    /// The members' relay only.
    case pantry
}

/// What `POST /api/schedule` stored.
nonisolated struct ScheduleReceipt: Sendable, Equatable {
    let id: String
    /// Unix seconds; equals the event's `created_at`.
    let publishAt: Int
    let relayMode: ScheduleRelayMode
    /// As stored by the server (normalized).
    let relays: [String]
    let status: ScheduleStatus
    /// True when an earlier attempt had already stored this exact event.
    let alreadyScheduled: Bool
}

nonisolated struct ScheduleCancellation: Sendable, Equatable {
    let id: String
    /// True when it was already cancelled before this call.
    let alreadyCancelled: Bool
}

/// One row of `GET /api/schedule`.
nonisolated struct ScheduledPost: Sendable, Identifiable {
    let id: String
    /// Unix seconds; equals `event.createdAt`.
    let publishAt: Int
    let relayMode: ScheduleRelayMode
    let relays: [String]
    let status: ScheduleStatus
    let attempts: Int
    /// Diagnostic text from the sweep or a relay. Detail under plain copy;
    /// never the headline, and never parsed.
    let lastError: String?
    let sentAt: Int?
    /// The whole signed event, exactly as it was sent.
    let event: NostrEvent

    init(id: String, publishAt: Int, relayMode: ScheduleRelayMode, relays: [String],
         status: ScheduleStatus, attempts: Int, lastError: String?, sentAt: Int?, event: NostrEvent) {
        self.id = id
        self.publishAt = publishAt
        self.relayMode = relayMode
        self.relays = relays
        self.status = status
        self.attempts = attempts
        self.lastError = lastError
        self.sentAt = sentAt
        self.event = event
    }

    /// Nil for a row this client cannot read (no id, time, known status or
    /// event), which the list then skips.
    init?(row: Any) {
        guard let row = row as? [String: Any],
              let id = row["id"] as? String,
              let publishAt = row["publish_at"] as? Int,
              let status = (row["status"] as? String).flatMap(ScheduleStatus.init),
              let eventObject = row["event"] as? [String: Any],
              let event = NostrEvent(json: eventObject) else { return nil }
        self.init(
            id: id,
            publishAt: publishAt,
            relayMode: (row["relay_mode"] as? String).flatMap(ScheduleRelayMode.init) ?? .all,
            relays: row["relays"] as? [String] ?? [],
            status: status,
            attempts: row["attempts"] as? Int ?? 0,
            lastError: row["last_error"] as? String,
            sentAt: row["sent_at"] as? Int,
            event: event
        )
    }
}

// MARK: - Failures

/// Every way a call can fail: the contract's error codes, one case each, then
/// the ones that never reach the server.
nonisolated enum ScheduleFailure: Error, Sendable, Equatable {
    // The server's codes, in the contract's order.
    /// NIP-98 check failed, twice (the first 401 is retried).
    case authFailed
    case badRequest
    case badRelayMode
    /// Still refused after the retry without relays, or refused with none sent.
    case badRelays
    case badSignature
    case pubkeyMismatch
    case badKind
    case kindNotAllowedForRelayMode
    case badPublishTime
    case tooLarge
    case pollClosesBeforePublish
    /// This exact event is stored and will not go out: `status` is
    /// `cancelled` or `failed` (pending, publishing and sent are a success).
    /// Sign a new event to try again.
    case alreadyScheduled(status: ScheduleStatus?)
    case quotaExceeded
    case rateLimited
    case badStatus
    case notFound
    /// The post is not pending. `status` says what it is: publishing, sent
    /// or failed (already cancelled is a success).
    case notCancellable(status: ScheduleStatus?)
    case notConfigured
    case `internal`

    // Client-side.
    /// The account cannot sign (watch-only, or no key).
    case signedOut
    /// The signer refused or could not be reached.
    case signFailed
    /// The signer returned an event other than the one asked for, or one that
    /// does not verify. It was not sent.
    case signerChangedEvent
    /// The request did not complete.
    case network
    /// A code this client does not know, or a response with none.
    case unknown

    init(code: String, rowStatus: ScheduleStatus? = nil) {
        switch code {
        case "auth_failed": self = .authFailed
        case "bad_request": self = .badRequest
        case "bad_relay_mode": self = .badRelayMode
        case "bad_relays": self = .badRelays
        case "bad_signature": self = .badSignature
        case "pubkey_mismatch": self = .pubkeyMismatch
        case "bad_kind": self = .badKind
        case "kind_not_allowed_for_relay_mode": self = .kindNotAllowedForRelayMode
        case "bad_publish_time": self = .badPublishTime
        case "too_large": self = .tooLarge
        case "poll_closes_before_publish": self = .pollClosesBeforePublish
        case "already_scheduled": self = .alreadyScheduled(status: rowStatus)
        case "quota_exceeded": self = .quotaExceeded
        case "rate_limited": self = .rateLimited
        case "bad_status": self = .badStatus
        case "not_found": self = .notFound
        case "not_cancellable": self = .notCancellable(status: rowStatus)
        case "not_configured": self = .notConfigured
        case "internal": self = .internal
        default: self = .unknown
        }
    }
}
