import Foundation

/// Publishes a recipe as a signed event in the primary `RecipeFormat`
/// (`RecipeFormats.primary` — NIP-23 `kind 30023` today; the seam lets a future
/// format become primary without touching this class) — the shared create spine
/// (Sous Chef Publish later; the manual recipe-create form in 2.4).
///
/// Mirrors the web create flow: serialize via the primary format, **re-host the
/// cover image** through Blossom so the recipe owns its image (with a fallback
/// to the source URL if re-host fails — Save never blocks on it), sign with the
/// local key, cache locally so the detail/feed can render it **optimistically**
/// without waiting on relay propagation, and broadcast to the author's write
/// relays **and** `RelayDefaults.articles` (the "all" publish the web does, so
/// the recipe shows up in the Recipes feed). Write-relays-only would miss that
/// feed, which reads the articles union. Requires a signing key — watch-only
/// can't publish.
///
/// **§7.8 is recorded, not solved.** Same title ⇒ same slug ⇒ same d-tag ⇒
/// silently REPLACES that author's existing recipe. A collision warning is a
/// known gap on both platforms; the web mitigates with a "make your title
/// unique" caption. That caption is a 2.4 UI concern. This type must not grow
/// one.
///
/// Port of Android `repo/RecipePublisher.kt`. `RecipeSerializer` /
/// `RecipeParser` / `RecipeRepository` / `IngredientScaler` are consumed, not
/// modified.
@MainActor
final class RecipePublisher {

    /// Test/production seam. Production (`shared`) talks to Blossom, the
    /// articles union, ObjectBox, and `RecipeRepository`. Tests inject fakes so
    /// the suite stays hermetic.
    struct Environment {
        var downloadImage: (String) async -> (Data, String)?
        var uploadBlossom: (Data, String, Keypair) async -> String?
        var writeRelays: (String) async -> [String]
        var cacheEvent: (NostrEvent) -> Void
        var applyLocalDeletion: (NostrEvent, NostrEvent) -> Void
        var publish: (NostrEvent, [String]) async -> [String]
        var now: () -> Int
        var articlesRelays: [String]
        var pantryRelay: String?
    }

    enum Result {
        /// `[author]`/`[dTag]` address the just-published recipe (cached locally).
        /// `accepted` is the subset of `targeted` that returned OK; the rest
        /// rejected or timed out. Partial success is a finding, not a failure
        /// to paper over — the event is already cached.
        case published(author: String, dTag: String, event: NostrEvent, targeted: [String], accepted: [String])
        case error(String)
    }

    /// Outcome of `delete`. Deliberately **not** a `Result` variant: publish
    /// outcomes are matched exhaustively at their call sites, and a third case
    /// there would only ever be unreachable.
    enum DeleteResult {
        case deleted(targeted: [String], accepted: [String])
        case error(String)
    }

    static let shared = RecipePublisher(env: .production)

    /// 10 MB — Android `MAX_IMAGE_BYTES`. Oversize/unknown-length-overrun →
    /// fall back to the source URL rather than buffering a huge image.
    nonisolated static let maxImageBytes = 10 * 1024 * 1024

    /// Kinds mirrored to pantry.zap.cooking on recipe publish. Only 30023 today
    /// — pantry's write policy exempts only KindRecipe (30023) from NIP-42 auth.
    static let pantryMirrorKinds: Set<Int> = [30023]

    private let env: Environment

    init(env: Environment) {
        self.env = env
    }

    // MARK: - Publish (Sous Chef / imported source-image path)

    /// Sous Chef Publish path: the recipe carries a single **source image URL**
    /// (from the imported recipe) that we re-host through Blossom so the recipe
    /// owns its image. Re-host failure falls back to the source URL (Save never
    /// blocks on it).
    func publish(
        recipe: RecipeParser.Recipe,
        categories: [String],
        keypair: Keypair?,
        includeClientTag: Bool
    ) async throws -> Result {
        guard let keypair else { return .error("Sign in to save recipes.") }
        let title = recipe.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let title, !title.isEmpty else {
            return .error("This recipe needs a title to publish.")
        }
        let sourceImage = recipe.image?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let sourceImage, !sourceImage.isEmpty else {
            return .error("Add an image to publish this recipe.")
        }

        let imageURL = try await reHost(sourceImage, keypair: keypair) ?? sourceImage
        return try await publishCore(
            recipe: recipe,
            categories: categories,
            imageURLs: [imageURL],
            keypair: keypair,
            includeClientTag: includeClientTag,
            title: title
        )
    }

    // MARK: - Publish (compose path: images already on Blossom)

    /// Manual recipe-compose path: images are **already hosted** on Blossom
    /// (uploaded from the device by the compose screen, which blocks publish
    /// until every upload has resolved), so no re-host — every URL goes straight
    /// into an `image` tag (first = cover), mirroring the web's multi-image
    /// create. Title/image are guaranteed by the screen's validation, but
    /// re-checked here so the publisher is never the one to sign a bad event.
    func publish(
        recipe: RecipeParser.Recipe,
        categories: [String],
        imageURLs: [String],
        keypair: Keypair?,
        includeClientTag: Bool
    ) async throws -> Result {
        guard let keypair else { return .error("Sign in to publish recipes.") }
        let title = recipe.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let title, !title.isEmpty else {
            return .error("This recipe needs a title to publish.")
        }
        let images = imageURLs.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !images.isEmpty else {
            return .error("Add an image to publish this recipe.")
        }
        return try await publishCore(
            recipe: recipe,
            categories: categories,
            imageURLs: images,
            keypair: keypair,
            includeClientTag: includeClientTag,
            title: title
        )
    }

    // MARK: - Edit

    /// Recipe-edit path: republish `original` as a **replacement** at the same
    /// address, through the same spine the create paths use — so an edit reaches
    /// the relays a **new** recipe would: the author's *current* write relays ∪
    /// `RelayDefaults.articles`.
    ///
    /// The address is not re-derived from the (possibly changed) title; it comes
    /// off `original` inside the format's `serializeEdit`. Serialized by
    /// **`original`'s own format**, not `RecipeFormats.primary`: an edit replaces
    /// a specific event, and re-encoding it into a different format would leave
    /// the original live at its own address rather than replacing it.
    ///
    /// Only the author may edit — the same reason `delete` refuses: an event
    /// signed by anyone else replaces nothing, because a replaceable address is
    /// `(kind, pubkey, d)`.
    func publishEdit(
        original: NostrEvent,
        recipe: RecipeParser.Recipe,
        categories: [String],
        imageURLs: [String],
        keypair: Keypair?,
        includeClientTag: Bool
    ) async throws -> Result {
        guard let keypair else { return .error("Sign in to edit recipes.") }
        guard original.pubkey == keypair.pubkey else {
            return .error("You can only edit your own recipes.")
        }
        let title = recipe.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let title, !title.isEmpty else {
            return .error("This recipe needs a title to publish.")
        }
        let images = imageURLs.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !images.isEmpty else {
            return .error("Add an image to publish this recipe.")
        }
        guard let format = RecipeFormats.forEvent(original) else {
            return .error("This recipe can't be edited from this device.")
        }
        return try await publishCore(
            recipe: recipe,
            categories: categories,
            imageURLs: images,
            keypair: keypair,
            includeClientTag: includeClientTag,
            title: title
        ) {
            (
                format.serializeEdit(
                    recipe: recipe,
                    title: title,
                    imageUrls: images,
                    categories: categories,
                    original: original
                ),
                RecipeParser.dTag(original)
            )
        }
    }

    // MARK: - Delete

    /// Delete a published recipe — the web `handleDelete` fan-out, on the same
    /// `broadcast` path the recipe was published on. Publishing and deleting a
    /// recipe reach **the same relays** by construction.
    ///
    /// Two events, per `RecipeDeletion`: the blanked replacement (kind = the
    /// recipe's own kind) and the kind-5 deletion request. Neither carries a
    /// NIP-89 client tag: a tombstone stays minimal.
    ///
    /// Only the author may delete. A recipe dated past the future-date ceiling
    /// is refused too (`RecipeDeletion.isDeletableNow`) — its tombstone would
    /// be dropped by every reader, so reporting success would be a lie.
    func delete(event: NostrEvent, keypair: Keypair?) async throws -> DeleteResult {
        guard let keypair else { return .error("Sign in to delete recipes.") }
        guard event.pubkey == keypair.pubkey else {
            return .error("You can only delete your own recipes.")
        }
        let now = env.now()
        guard RecipeDeletion.isDeletableNow(event, now: now) else {
            return .error("This recipe is dated too far in the future to delete from this device.")
        }
        do {
            let createdAt = RecipeDeletion.deletionTimestamp(event, now: now)
            let replacement = try await Signer.sign(
                keypair: keypair,
                kind: event.kind,
                tags: RecipeDeletion.blankedReplacementTags(event),
                content: RecipeDeletion.tombstoneContent,
                createdAt: createdAt
            )
            let deletionRequest = try await Signer.sign(
                keypair: keypair,
                kind: Nip09.kindDeletion,
                tags: RecipeDeletion.deletionRequestTags(event),
                content: RecipeDeletion.deletionRequestContent,
                createdAt: createdAt
            )
            let replacementBroadcast = await broadcast(replacement)
            let deletionBroadcast = await broadcast(deletionRequest)
            env.applyLocalDeletion(replacement, deletionRequest)
            let targeted = uniqued(replacementBroadcast.targeted + deletionBroadcast.targeted)
            let accepted = uniqued(replacementBroadcast.accepted + deletionBroadcast.accepted)
            return .deleted(targeted: targeted, accepted: accepted)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .error("Couldn't delete this recipe — \(error.localizedDescription).")
        }
    }

    // MARK: - Core

    private func publishCore(
        recipe: RecipeParser.Recipe,
        categories: [String],
        imageURLs: [String],
        keypair: Keypair,
        includeClientTag: Bool,
        title: String,
        encode: (() -> (UnsignedRecipeEvent, String))? = nil
    ) async throws -> Result {
        do {
            let (unsigned, dTag) = encode?() ?? (
                RecipeFormats.primary.serialize(
                    recipe: recipe,
                    title: title,
                    imageUrls: imageURLs,
                    categories: categories
                ),
                RecipeFormats.primary.slug(title)
            )
            var tags = unsigned.tags
            if includeClientTag { tags.append(["client", "Zap Cooking"]) }

            let event = try await Signer.sign(
                keypair: keypair,
                kind: unsigned.kind,
                tags: tags,
                content: unsigned.content
            )
            // Cache first so the detail screen / Recipes tab render
            // optimistically (no relay round-trip).
            env.cacheEvent(event)
            let outcome = await broadcast(event)
            return .published(
                author: keypair.pubkey,
                dTag: dTag,
                event: event,
                targeted: outcome.targeted,
                accepted: outcome.accepted
            )
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .error("Couldn't publish this recipe — \(error.localizedDescription).")
        }
    }

    /// The recipe write surface: the author's write relays **and**
    /// `RelayDefaults.articles` (the web's "all" publish, so the recipe shows
    /// up in the Recipes feed), plus the pantry mirror for mirrored kinds.
    /// Every recipe event — publish and delete alike — goes through here.
    private func broadcast(_ event: NostrEvent) async -> (targeted: [String], accepted: [String]) {
        var targeted: [String] = []
        var seen = Set<String>()
        func add(_ url: String) {
            let key = Self.normalizeRelay(url)
            guard !key.isEmpty, seen.insert(key).inserted else { return }
            targeted.append(url)
        }
        let writes = await env.writeRelays(event.pubkey)
        for url in writes { add(url) }
        for url in env.articlesRelays { add(url) }
        if Self.pantryMirrorKinds.contains(event.kind),
           let pantry = env.pantryRelay {
            add(pantry)
        }
        let accepted = await env.publish(event, targeted)
        return (targeted, accepted)
    }

    /// Fetch the remote image and re-upload to Blossom; nil on any failure (→
    /// caller falls back to the source URL). Bounded so "Save never blocks on
    /// re-host" holds even for a huge/slow image.
    private func reHost(_ url: String, keypair: Keypair) async throws -> String? {
        try Task.checkCancellation()
        guard let (bytes, mime) = await env.downloadImage(url), !bytes.isEmpty else {
            return nil
        }
        try Task.checkCancellation()
        return await env.uploadBlossom(bytes, mime, keypair)
    }

    private func uniqued(_ urls: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for url in urls {
            let key = Self.normalizeRelay(url)
            guard seen.insert(key).inserted else { continue }
            out.append(url)
        }
        return out
    }

    /// Canonical form for URL equality (dedupe): trim, drop trailing slashes,
    /// lowercase. Comparison only — the original URL is what we connect with.
    nonisolated static func normalizeRelay(_ url: String) -> String {
        var s = url.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    /// Bounded GET. Declared-oversize (`Content-Length` > cap) or a body
    /// that overruns the cap returns nil. 20 s timeout matches Android's
    /// `callTimeout` so Save never waits on a huge/slow image.
    nonisolated static func downloadCapped(
        url: String,
        maxBytes: Int = maxImageBytes,
        timeout: TimeInterval = 20
    ) async -> (Data, String)? {
        guard let requestURL = URL(string: url) else { return nil }
        var request = URLRequest(url: requestURL)
        request.timeoutInterval = timeout
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse {
                guard (200..<300).contains(http.statusCode) else { return nil }
                let length = http.expectedContentLength
                if length > 0 && length > maxBytes { return nil }
            }
            guard !data.isEmpty, data.count <= maxBytes else { return nil }
            let rawMime = (response as? HTTPURLResponse)?.mimeType
                ?? response.mimeType
                ?? "image/jpeg"
            let mime = rawMime.split(separator: ";").first.map(String.init)?.trimmingCharacters(in: .whitespaces)
                ?? "image/jpeg"
            return (data, mime.hasPrefix("image/") ? mime : "image/jpeg")
        } catch {
            return nil
        }
    }
}

extension RecipePublisher.Environment {
    static var production: RecipePublisher.Environment {
        RecipePublisher.Environment(
            downloadImage: { url in
                await RecipePublisher.downloadCapped(url: url)
            },
            uploadBlossom: { bytes, mime, keypair in
                let servers = BlossomServerList.cached(for: keypair.pubkey)
                do {
                    return try await BlossomClient.upload(
                        bytes: bytes,
                        mime: mime,
                        servers: servers,
                        keypair: keypair
                    ).url
                } catch {
                    return nil
                }
            },
            writeRelays: { pubkey in
                await RelayListRepository.shared.getWriteRelays(pubkey)
            },
            cacheEvent: { event in
                RecipeRepository.shared.ingest([event])
                Task { await EventPersistQueue.shared.enqueue(event) }
            },
            applyLocalDeletion: { replacement, deletion in
                // Persist both so a cold start paints from ObjectBox the same
                // way a relay echo would. `RecipeRepository.ingest` drops
                // non-recipes (the blanked replacement fails `isRecipe`), so
                // in-memory eviction of the live coordinate waits on a feed
                // refresh — ingest has no remove. 2.4's delete UI should
                // refresh after this returns; do not add an evict API here.
                Task { await EventPersistQueue.shared.enqueue([replacement, deletion]) }
            },
            publish: { event, relays in
                await RelayPool.publish(event: event, to: relays, timeout: 8)
            },
            now: { NostrClock.now() },
            articlesRelays: RelayDefaults.articles,
            pantryRelay: RelayDefaults.members.first
        )
    }
}
