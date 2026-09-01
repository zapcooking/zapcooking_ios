import Foundation

/// Sous Chef URL import (Concern 2.5) — `POST /api/extract-recipe/public`.
///
/// **Free and anonymous.** The URL import carries no NIP-98 header and no
/// pubkey — the server gates only the image/text modes (P2, not built here)
/// and rate-limits URL extraction per IP (8/hr · 30/day, `extract-url`
/// scope). Mirrors Android `ZapCookingApi.extractRecipeFromUrl` +
/// `ExtractUrlRequest`, which posts `{"url": …}` with no auth on the
/// compute client (build spec §2).
///
/// The 429 body is the one extract failure that carries **no `code`**
/// (`{ error: "rate_limited", retryAfter, scope }`), so it reaches callers
/// through `throwErrorIfNeeded`'s status fallback as
/// `.rateLimited(retryAfter:)` — never as `apiRejected`.
///
/// A struct (not a bare static) so the session tier is pinned by test:
/// `client` defaults to `HttpClientFactory.computeClient` and
/// `SousChefTests` asserts the identity — a refactor onto `generalClient`
/// (15 s, the exact regression Android paid for on the AI endpoints) fails
/// the suite, not just the doc.
///
/// The request is built here rather than through `ZapCookingApi.post` for
/// one reason: Android renders a dedicated "taking too long" line for
/// timeouts (`InterruptedIOException`), and the shared send path erases
/// `URLError.timedOut` into a locale-dependent `.transport` string. This
/// path throws `.transport(Self.timedOutTransportMessage)` instead —
/// stable, matchable — while every status/body failure still goes through
/// the shared `ZapCookingApi.throwErrorIfNeeded` taxonomy.
struct SousChefImportService {
    var client: URLSession = HttpClientFactory.computeClient

    /// Stable `.transport` payload for a timed-out extraction.
    /// `SousChefViewModel.importErrorMessage` keys its timeout copy on it.
    static let timedOutTransportMessage = "The request timed out."

    /// Extract a recipe from a public web page. Returns the structured
    /// recipe on success; failures surface through the 0.7a taxonomy
    /// (`ZapCookingApiError`). A 200 with `success: false` (defensive —
    /// the server uses non-2xx for failures today) maps to
    /// `.apiRejected(code: nil, message: server error)` so the view model
    /// renders the server string, matching Android's `resp.error` branch.
    func importRecipe(from url: String) async throws -> NormalizedRecipe {
        var request = URLRequest(
            url: ZapCookingApi.baseURL.appendingPathComponent("api/extract-recipe/public")
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(ZapCookingApi.encodeJSON(ExtractUrlRequest(url: url)).utf8)

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await client.data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            throw ZapCookingApiError.transport(Self.timedOutTransportMessage)
        } catch {
            throw ZapCookingApiError.transport(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw ZapCookingApiError.transport(URLError(.badServerResponse).localizedDescription)
        }
        try ZapCookingApi.throwErrorIfNeeded(status: http.statusCode, body: data)
        let decoded = try ZapCookingApi.decode(data, as: ExtractRecipeResponse.self)
        guard decoded.success, let recipe = decoded.recipe else {
            throw ZapCookingApiError.apiRejected(code: nil, message: decoded.error)
        }
        return recipe
    }
}

/// `POST /api/extract-recipe/public` body — `{"url": …}` only, no `type`
/// discriminator (that belongs to the authed sibling). Android
/// `ExtractUrlRequest` parity.
nonisolated struct ExtractUrlRequest: Encodable {
    let url: String
}

/// `/api/extract-recipe(/public)` response envelope. Lenient — every field
/// defaulted so a partial body never throws (Android parity).
nonisolated struct ExtractRecipeResponse: Decodable, Sendable, Equatable {
    var success: Bool
    var recipe: NormalizedRecipe?
    var error: String?

    init(success: Bool = false, recipe: NormalizedRecipe? = nil, error: String? = nil) {
        self.success = success
        self.recipe = recipe
        self.error = error
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            success: try c.decodeIfPresent(Bool.self, forKey: .success) ?? false,
            recipe: try c.decodeIfPresent(NormalizedRecipe.self, forKey: .recipe),
            error: try c.decodeIfPresent(String.self, forKey: .error)
        )
    }

    enum CodingKeys: String, CodingKey { case success, recipe, error }
}

/// The structured recipe the import endpoint returns — **NOT markdown**.
/// Field names match the server's `NormalizedRecipe`
/// (frontend `src/lib/parseRecipe.server.ts`) exactly; Android's DTO was
/// validated against a live response. All defaulted so a partial
/// extraction never throws.
nonisolated struct NormalizedRecipe: Decodable, Sendable, Equatable {
    var title: String = ""
    var summary: String = ""
    var chefsnotes: String = ""
    var preptime: String = ""
    var cooktime: String = ""
    var servings: String = ""
    var ingredients: [String] = []
    var directions: [String] = []
    var tags: [String] = []
    var imageUrls: [String] = []

    init(
        title: String = "",
        summary: String = "",
        chefsnotes: String = "",
        preptime: String = "",
        cooktime: String = "",
        servings: String = "",
        ingredients: [String] = [],
        directions: [String] = [],
        tags: [String] = [],
        imageUrls: [String] = []
    ) {
        self.title = title
        self.summary = summary
        self.chefsnotes = chefsnotes
        self.preptime = preptime
        self.cooktime = cooktime
        self.servings = servings
        self.ingredients = ingredients
        self.directions = directions
        self.tags = tags
        self.imageUrls = imageUrls
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            title: try c.decodeIfPresent(String.self, forKey: .title) ?? "",
            summary: try c.decodeIfPresent(String.self, forKey: .summary) ?? "",
            chefsnotes: try c.decodeIfPresent(String.self, forKey: .chefsnotes) ?? "",
            preptime: try c.decodeIfPresent(String.self, forKey: .preptime) ?? "",
            cooktime: try c.decodeIfPresent(String.self, forKey: .cooktime) ?? "",
            servings: try c.decodeIfPresent(String.self, forKey: .servings) ?? "",
            ingredients: try c.decodeIfPresent([String].self, forKey: .ingredients) ?? [],
            directions: try c.decodeIfPresent([String].self, forKey: .directions) ?? [],
            tags: try c.decodeIfPresent([String].self, forKey: .tags) ?? [],
            imageUrls: try c.decodeIfPresent([String].self, forKey: .imageUrls) ?? []
        )
    }

    enum CodingKeys: String, CodingKey {
        case title, summary, chefsnotes, preptime, cooktime, servings
        case ingredients, directions, tags, imageUrls
    }

    /// Map to a `RecipeParser.Recipe` for the read-only import preview,
    /// reusing the recipe rendering conventions. Pure (unit-tested).
    /// `id`/`author`/`dTag` are empty (not a published event — no byline,
    /// no date); blanks become nils so empty sections are omitted, not
    /// rendered blank; the backend `tags` land in `hashtags` (Android
    /// parity — they become the publish categories), `categories` stays
    /// empty. Empty `imageUrls` → `image` (the `images.first` cover) is
    /// nil → no hero, and publish is blocked on the missing image.
    func toRecipePreview() -> RecipeParser.Recipe {
        RecipeParser.Recipe(
            id: "",
            author: "",
            dTag: "",
            title: blankToNil(title),
            images: imageUrls,
            summary: blankToNil(summary),
            publishedAt: 0,
            hashtags: tags,
            categories: [],
            content: RecipeParser.RecipeContent(
                chefNotes: blankToNil(chefsnotes),
                details: RecipeParser.RecipeDetails(
                    prepTime: blankToNil(preptime),
                    cookTime: blankToNil(cooktime),
                    servings: blankToNil(servings)
                ),
                ingredients: ingredients,
                directions: directions,
                additionalMarkdown: nil
            )
        )
    }

    private func blankToNil(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
