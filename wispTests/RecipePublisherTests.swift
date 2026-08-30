import Foundation
import Testing
@testable import wisp

/// Gate for `RecipePublisher` (Concern 2.3): Blossom-failure fallback, optimistic
/// cache insert, deleteKind derivation, tombstone `a`+`k` tags, and the write ∪
/// articles ∪ pantry broadcast set.
///
/// Hermetic — no relay, no Blossom, no ObjectBox. The live publish is a
/// separate opt-in suite.
@MainActor
struct RecipePublisherTests {

    private let sourceImage = "https://example.com/cover.jpg"
    private let hostedImage = "https://blossom.example/abc.jpg"
    private let writeRelay = "wss://write.example"
    private let articles = ["wss://relay.primal.net", "wss://nos.lol"]
    private let pantry = "wss://pantry.zap.cooking"

    private let recipeBodyIngredients = ["1 cup flour"]
    private let recipeBodyDirections = ["Mix.", "Bake."]

    private func makeKeypair() throws -> Keypair {
        let priv = Schnorr.randomPrivkey()
        let pub = try Schnorr.xonlyPubkey(privkey32: priv)
        return Keypair(privkey: Hex.encode(priv), pubkey: Hex.encode(pub))
    }

    private func draft(
        title: String? = "Hermetic Test Stew",
        image: String? = "https://example.com/cover.jpg",
        images: [String]? = nil
    ) -> RecipeParser.Recipe {
        RecipeParser.Recipe(
            id: "",
            author: "",
            dTag: "",
            title: title,
            images: images ?? image.map { [$0] } ?? [],
            summary: "A test recipe.",
            publishedAt: 0,
            hashtags: [],
            categories: ["test"],
            content: RecipeParser.RecipeContent(
                ingredients: recipeBodyIngredients,
                directions: recipeBodyDirections
            )
        )
    }

    /// Mutable probe for the publisher's injected environment.
    private final class Probe: @unchecked Sendable {
        var cached: [NostrEvent] = []
        var published: [(NostrEvent, [String])] = []
        var deletions: [(NostrEvent, NostrEvent)] = []
        var uploadCalls = 0
        var uploadShouldFail = true
        var downloadShouldFail = false
        var accepted: [String] = ["wss://relay.primal.net"]
        var writeRelays: [String] = ["wss://write.example"]
        var order: [String] = []
    }

    private func publisher(_ probe: Probe) -> RecipePublisher {
        RecipePublisher(env: RecipePublisher.Environment(
            downloadImage: { url in
                if probe.downloadShouldFail { return nil }
                return (Data("img".utf8), "image/jpeg")
            },
            uploadBlossom: { _, _, _ in
                probe.uploadCalls += 1
                if probe.uploadShouldFail { return nil }
                return "https://blossom.example/abc.jpg"
            },
            writeRelays: { _ in probe.writeRelays },
            cacheEvent: { event in
                probe.order.append("cache")
                probe.cached.append(event)
            },
            applyLocalDeletion: { replacement, deletion in
                probe.deletions.append((replacement, deletion))
            },
            publish: { event, relays in
                probe.order.append("publish")
                probe.published.append((event, relays))
                return probe.accepted.filter { target in
                    relays.contains { RecipePublisher.normalizeRelay($0) == RecipePublisher.normalizeRelay(target) }
                }
            },
            now: { 1_800_000_000 },
            articlesRelays: ["wss://relay.primal.net", "wss://nos.lol"],
            pantryRelay: "wss://pantry.zap.cooking"
        ))
    }

    // MARK: - Blossom-failure fallback

    /// Save must never block on Blossom. Upload failure keeps the source URL
    /// on the signed event's `image` tag.
    @Test func blossomFailure_fallsBackToSourceURL() async throws {
        let probe = Probe()
        probe.uploadShouldFail = true
        let kp = try makeKeypair()
        let result = try await publisher(probe).publish(
            recipe: draft(),
            categories: ["test"],
            keypair: kp,
            includeClientTag: false
        )
        guard case .published(_, _, let event, _, _) = result else {
            Issue.record("expected published")
            return
        }
        #expect(probe.uploadCalls == 1)
        let imageTags = event.tags.filter { $0.count >= 2 && $0[0] == "image" }.map { $0[1] }
        #expect(imageTags == [sourceImage])
        #expect(RecipeParser.isRecipe(event))
    }

    @Test func blossomSuccess_usesHostedURL() async throws {
        let probe = Probe()
        probe.uploadShouldFail = false
        let kp = try makeKeypair()
        let result = try await publisher(probe).publish(
            recipe: draft(),
            categories: ["test"],
            keypair: kp,
            includeClientTag: false
        )
        guard case .published(_, _, let event, _, _) = result else {
            Issue.record("expected published")
            return
        }
        let imageTags = event.tags.filter { $0.count >= 2 && $0[0] == "image" }.map { $0[1] }
        #expect(imageTags == [hostedImage])
    }

    @Test func downloadFailure_fallsBackToSourceURLWithoutUploading() async throws {
        let probe = Probe()
        probe.downloadShouldFail = true
        let kp = try makeKeypair()
        let result = try await publisher(probe).publish(
            recipe: draft(),
            categories: ["test"],
            keypair: kp,
            includeClientTag: false
        )
        guard case .published(_, _, let event, _, _) = result else {
            Issue.record("expected published")
            return
        }
        #expect(probe.uploadCalls == 0)
        let imageTags = event.tags.filter { $0.count >= 2 && $0[0] == "image" }.map { $0[1] }
        #expect(imageTags == [sourceImage])
    }

    // MARK: - Optimistic cache

    /// Cache runs before the relay publish, so the recipe appears immediately
    /// even when every relay rejects or times out.
    @Test func publish_cachesOptimisticallyBeforeBroadcast() async throws {
        let probe = Probe()
        probe.accepted = []
        let kp = try makeKeypair()
        let result = try await publisher(probe).publish(
            recipe: draft(),
            categories: ["test"],
            keypair: kp,
            includeClientTag: false
        )
        guard case .published(let author, let dTag, let event, _, let accepted) = result else {
            Issue.record("expected published, got \(result)")
            return
        }
        #expect(probe.order == ["cache", "publish"])
        #expect(probe.cached.count == 1)
        #expect(probe.cached.first?.id == event.id)
        #expect(accepted.isEmpty)
        #expect(author == kp.pubkey)
        #expect(dTag == RecipeSerializer.slug("Hermetic Test Stew"))
        #expect(event.kind == RecipeParser.recipeKind)
    }

    // MARK: - Broadcast set

    @Test func publish_targetsWriteRelaysAndArticlesAndPantry() async throws {
        let probe = Probe()
        let kp = try makeKeypair()
        _ = try await publisher(probe).publish(
            recipe: draft(),
            categories: ["test"],
            imageURLs: [hostedImage],
            keypair: kp,
            includeClientTag: false
        )
        let relays = probe.published.first?.1 ?? []
        let keys = Set(relays.map { RecipePublisher.normalizeRelay($0) })
        #expect(keys.contains("wss://write.example"))
        #expect(keys.contains("wss://relay.primal.net"))
        #expect(keys.contains("wss://nos.lol"))
        #expect(keys.contains("wss://pantry.zap.cooking"))
        // Pantry is kind-gated: 30023 only. Duplicate write/articles URLs
        // collapse, so the set is not write+articles+pantry by count-with-dupes.
        #expect(relays.count == keys.count)
    }

    @Test func kind5_isNotMirroredToPantry() async throws {
        let probe = Probe()
        let kp = try makeKeypair()
        let pub = try await publisher(probe).publish(
            recipe: draft(),
            categories: ["test"],
            imageURLs: [hostedImage],
            keypair: kp,
            includeClientTag: false
        )
        guard case .published(_, _, let event, _, _) = pub else { return }
        probe.published.removeAll()
        _ = try await publisher(probe).delete(event: event, keypair: kp)
        // Two broadcasts: replacement (30023, pantry yes) and kind-5 (pantry no).
        #expect(probe.published.count == 2)
        let replacementTargets = Set((probe.published[0].1).map { RecipePublisher.normalizeRelay($0) })
        let deletionTargets = Set((probe.published[1].1).map { RecipePublisher.normalizeRelay($0) })
        #expect(replacementTargets.contains("wss://pantry.zap.cooking"))
        #expect(!deletionTargets.contains("wss://pantry.zap.cooking"))
        #expect(probe.published[1].0.kind == Nip09.kindDeletion)
    }

    // MARK: - Deletion: deleteKind + a/k tags

    @Test func delete_derivesKindFromTheEvent_andTombstoneCarriesAAndK() async throws {
        let probe = Probe()
        let kp = try makeKeypair()
        let pub = try await publisher(probe).publish(
            recipe: draft(),
            categories: ["test"],
            imageURLs: [hostedImage],
            keypair: kp,
            includeClientTag: false
        )
        guard case .published(_, let dTag, let event, _, _) = pub else {
            Issue.record("expected published")
            return
        }
        let result = try await publisher(probe).delete(event: event, keypair: kp)
        guard case .deleted = result else {
            Issue.record("expected deleted, got \(result)")
            return
        }
        #expect(probe.deletions.count == 1)
        let replacement = probe.deletions[0].0
        let deletion = probe.deletions[0].1

        #expect(replacement.kind == event.kind)
        #expect(replacement.kind == RecipeParser.recipeKind)
        #expect(replacement.content == RecipeDeletion.tombstoneContent)
        #expect(RecipeDeletion.isBlankedReplacement(replacement))
        #expect(!RecipeParser.isRecipe(replacement))

        #expect(deletion.kind == Nip09.kindDeletion)
        let a = deletion.tags.first { $0.first == "a" }
        let k = deletion.tags.first { $0.first == "k" }
        let e = deletion.tags.first { $0.first == "e" }
        #expect(a == ["a", "\(event.kind):\(kp.pubkey):\(dTag)"])
        #expect(k == ["k", String(event.kind)])
        #expect(e == ["e", event.id])
        // Both a and k — the §7.9 contract. Not e-only, not a hardcoded 30023
        // sitting next to a different kind.
        #expect(a != nil && k != nil)
    }

    @Test func delete_usesTheEventsOwnKindOnANonDefaultKind() async throws {
        let probe = Probe()
        let kp = try makeKeypair()
        // A signed kind-35000 stand-in: the publisher must not rewrite it to 30023.
        let foreign = try await Signer.sign(
            keypair: kp,
            kind: 35000,
            tags: [["d", "premium-stew"], ["t", "zapcooking"], ["title", "Premium"]],
            content: recipeBodyIngredients.joined(separator: "\n"),
            createdAt: 1_700_000_000
        )
        _ = try await publisher(probe).delete(event: foreign, keypair: kp)
        #expect(probe.deletions.count == 1)
        let replacement = probe.deletions[0].0
        let deletion = probe.deletions[0].1
        #expect(replacement.kind == 35000)
        #expect(deletion.tags.contains(["a", "35000:\(kp.pubkey):premium-stew"]))
        #expect(deletion.tags.contains(["k", "35000"]))
        #expect(deletion.tags.contains(["e", foreign.id]))
        // Kind-5 is outside PANTRY_MIRROR_KINDS; the replacement is too
        // (35000), so neither broadcast should include pantry.
        for (_, relays) in probe.published {
            #expect(!relays.map { RecipePublisher.normalizeRelay($0) }.contains("wss://pantry.zap.cooking"))
        }
    }

    @Test func delete_refusesFutureDatedRecipe() async throws {
        let probe = Probe()
        let kp = try makeKeypair()
        let future = try await Signer.sign(
            keypair: kp,
            kind: RecipeParser.recipeKind,
            tags: [["d", "future-stew"], ["t", "zapcooking"], ["title", "Future"]],
            content: "## Ingredients\n\n- x\n\n## Directions\n\n1. y.\n",
            createdAt: 1_800_000_000 + RecipeDeletion.futureDateGraceSeconds
        )
        let result = try await publisher(probe).delete(event: future, keypair: kp)
        guard case .error(let message) = result else {
            Issue.record("expected error, got \(result)")
            return
        }
        #expect(message.contains("too far in the future"))
        #expect(probe.deletions.isEmpty)
        #expect(probe.published.isEmpty)
    }

    @Test func delete_refusesNonAuthor() async throws {
        let probe = Probe()
        let author = try makeKeypair()
        let other = try makeKeypair()
        let event = try await Signer.sign(
            keypair: author,
            kind: RecipeParser.recipeKind,
            tags: [["d", "stew"], ["t", "zapcooking"], ["title", "Stew"]],
            content: "## Ingredients\n\n- x\n\n## Directions\n\n1. y.\n",
            createdAt: 1_700_000_000
        )
        let result = try await publisher(probe).delete(event: event, keypair: other)
        guard case .error(let message) = result else {
            Issue.record("expected error, got \(result)")
            return
        }
        #expect(message.contains("your own"))
        #expect(probe.deletions.isEmpty)
    }

    // MARK: - Validation

    @Test func publish_requiresTitleAndImage() async throws {
        let probe = Probe()
        let kp = try makeKeypair()
        let noTitle = try await publisher(probe).publish(
            recipe: draft(title: "  "),
            categories: [],
            keypair: kp,
            includeClientTag: false
        )
        guard case .error(let t) = noTitle else {
            Issue.record("expected title error")
            return
        }
        #expect(t.contains("title"))

        let noImage = try await publisher(probe).publish(
            recipe: draft(image: nil, images: []),
            categories: [],
            keypair: kp,
            includeClientTag: false
        )
        guard case .error(let i) = noImage else {
            Issue.record("expected image error")
            return
        }
        #expect(i.contains("image"))
        #expect(probe.cached.isEmpty)
    }

    @Test func publish_withoutKeypair_asksToSignIn() async throws {
        let probe = Probe()
        let result = try await publisher(probe).publish(
            recipe: draft(),
            categories: [],
            keypair: nil,
            includeClientTag: false
        )
        guard case .error(let message) = result else {
            Issue.record("expected error")
            return
        }
        #expect(message.contains("Sign in"))
    }
}
