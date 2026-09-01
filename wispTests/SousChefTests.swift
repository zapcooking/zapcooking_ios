import Foundation
import Testing
@testable import wisp

/// Hermetic coverage of Concern 2.5 — Sous Chef URL import. Response
/// decoding over recorded fixtures, the preview/hand-off mappings, the
/// Android-copy error mapping through the 0.7a taxonomy, the compute-client
/// pin, and the kill-switch gate. This file never opens a socket; the
/// opt-in network check lives in `SousChefLiveTests`.
struct SousChefTests {

    // MARK: - Fixtures

    /// Live capture, 2026-09-01: `POST /api/extract-recipe/public` with
    /// `https://www.bonappetit.com/recipe/bas-best-chocolate-chip-cookies`
    /// (HTTP 200). Byte-for-byte as returned — curly apostrophe, unicode
    /// fraction quantities, single rehostable `imageUrls` entry.
    static let cleanFixture = #"""
    {"success":true,"recipe":{"title":"BA’s Best Chocolate Chip Cookies","summary":"This chocolate chip cookie recipe features intentionally thin cookies with deeply caramelized flavor, crisp edges, and a soft, chewy center, elevated by brown butter for added richness.","chefsnotes":"Expect spread: This recipe is designed to bake up thin, with crisp, rippled edges. For slightly thicker cookies with less spread, chill the dough overnight or portion it into balls and freeze. Using a higher-protein all-purpose flour can also help limit spreading. Measure flour precisely and watch the bake, not the clock.","preptime":"20 min","cooktime":"10 min","servings":"16","ingredients":["1½ cups plus 1 Tbsp. (200 g) all-purpose flour","1¼ tsp. (4 g) Diamond Crystal or ¾ tsp. (4 g) Morton kosher salt","¾ tsp. (4 g) baking soda","¾ cup (1½ sticks; 169 g) unsalted butter, divided","1 cup (200 g) (packed) dark brown sugar","¼ cup (50 g) granulated sugar","1 large egg","2 large egg yolks","2 tsp. vanilla extract","6 oz. (170 g) bittersweet chocolate (60%–70% cacao), coarsely chopped, or semisweet chocolate chips"],"directions":["Place racks in upper and lower thirds of oven; preheat to 375°.","Whisk flour, salt, and baking soda in a small bowl; set aside.","Cook ½ cup unsalted butter in a large saucepan over medium heat until browned, about 4 minutes. Let cool for 1 minute.","Add remaining butter to brown butter until melted. Whisk in sugars until incorporated.","Add egg and egg yolks, whisking until smooth. Whisk in vanilla extract.","Fold dry ingredients into butter mixture until no dry spots remain, then fold in chocolate.","Using a scoop, portion out 16 balls of dough on parchment-lined baking sheets.","Bake cookies until deep golden brown and firm around the edges, about 8–10 minutes. Let cool on baking sheets."],"tags":["Dessert","Cookie","Chocolate","Snack","Easy"],"imageUrls":["https://assets.bonappetit.com/photos/5ca534485e96521ff23b382b/16:9/w_1280,c_limit/chocolate-chip-cookie.jpg"]}}
    """#

    /// Hand-built from the server's `NormalizedRecipe` shape: a partial
    /// extraction — no `directions` key at all, blank title, several
    /// fields absent. Must decode (all-defaulted) and preview without
    /// throwing; the missing pieces surface as omitted sections.
    static let partialFixture = #"""
    {"success":true,"recipe":{"title":"","summary":"A fragment.","ingredients":["1 cup flour"],"tags":[],"imageUrls":[]}}
    """#

    /// Live capture, 2026-09-01: the same endpoint with an AllRecipes URL
    /// the server could not fetch (HTTP 400). The standard extract error
    /// envelope — `success:false` + `error` + `code`.
    static let errorFixture = #"""
    {"success":false,"error":"That site could not be reached. Try again in a few minutes.","code":"SOURCE_UNAVAILABLE"}
    """#

    /// Hand-built from `src/lib/ipRateLimit.server.ts`: the 429 body is the
    /// one extract failure with **no `code` field** — `throwErrorIfNeeded`
    /// must classify it by status and keep `retryAfter`.
    static let rateLimit429Fixture = #"""
    {"error":"rate_limited","retryAfter":1800,"scope":"extract-url"}
    """#

    // MARK: - Decoding

    @Test func cleanFixture_decodesEveryField() throws {
        let resp = try JSONDecoder().decode(
            ExtractRecipeResponse.self, from: Data(Self.cleanFixture.utf8)
        )
        #expect(resp.success)
        let recipe = try #require(resp.recipe)
        #expect(recipe.title == "BA’s Best Chocolate Chip Cookies")
        #expect(recipe.summary.hasPrefix("This chocolate chip cookie recipe"))
        #expect(recipe.chefsnotes.hasPrefix("Expect spread"))
        #expect(recipe.preptime == "20 min")
        #expect(recipe.cooktime == "10 min")
        #expect(recipe.servings == "16")
        #expect(recipe.ingredients.count == 10)
        #expect(recipe.ingredients[0] == "1½ cups plus 1 Tbsp. (200 g) all-purpose flour")
        #expect(recipe.directions.count == 8)
        #expect(recipe.tags == ["Dessert", "Cookie", "Chocolate", "Snack", "Easy"])
        #expect(recipe.imageUrls.count == 1)
        #expect(recipe.imageUrls[0].hasPrefix("https://assets.bonappetit.com/"))
    }

    @Test func partialFixture_missingKeysDecodeToDefaults() throws {
        let resp = try JSONDecoder().decode(
            ExtractRecipeResponse.self, from: Data(Self.partialFixture.utf8)
        )
        #expect(resp.success)
        let recipe = try #require(resp.recipe)
        #expect(recipe.title == "")
        #expect(recipe.directions.isEmpty)
        #expect(recipe.preptime == "")
        #expect(recipe.servings == "")
        #expect(recipe.ingredients == ["1 cup flour"])
    }

    @Test func errorEnvelope_decodes_andEmptyBodyResponseDefaults() throws {
        let resp = try JSONDecoder().decode(
            ExtractRecipeResponse.self, from: Data(Self.errorFixture.utf8)
        )
        #expect(!resp.success)
        #expect(resp.recipe == nil)
        #expect(resp.error == "That site could not be reached. Try again in a few minutes.")

        let empty = try JSONDecoder().decode(ExtractRecipeResponse.self, from: Data("{}".utf8))
        #expect(!empty.success)
        #expect(empty.recipe == nil)
    }

    // MARK: - Taxonomy mapping (0.7a)

    @Test func errorFixture_sourceUnavailable_isApiRejectedWithCode() {
        #expect(throws: ZapCookingApiError.apiRejected(
            code: "SOURCE_UNAVAILABLE",
            message: "That site could not be reached. Try again in a few minutes."
        )) {
            try ZapCookingApi.throwErrorIfNeeded(status: 400, body: Data(Self.errorFixture.utf8))
        }
    }

    @Test func rateLimit429_codelessBody_isRateLimited_keepingRetryAfter() {
        // The extract 429 carries no `code` (ipRateLimit.server.ts) — it
        // must classify by status, never fall into apiRejected.
        #expect(throws: ZapCookingApiError.rateLimited(retryAfter: 1800)) {
            try ZapCookingApi.throwErrorIfNeeded(status: 429, body: Data(Self.rateLimit429Fixture.utf8))
        }
    }

    @Test func remainingExtractCodes_passThroughApiRejected() {
        // extractErrors.ts has 11 codes; ZapCookingApiTests pins 4. The
        // other 7 ride the same additive envelope.
        for code in [
            "INVALID_URL", "UNSUPPORTED_URL", "TEXT_TOO_LONG", "SOURCE_NOT_FOUND",
            "SOURCE_UNAVAILABLE", "SOURCE_TOO_LARGE", "TOO_MANY_REDIRECTS",
        ] {
            #expect(throws: ZapCookingApiError.apiRejected(code: code, message: "x")) {
                try ZapCookingApi.throwErrorIfNeeded(
                    status: 400,
                    body: Data("{\"success\":false,\"code\":\"\(code)\",\"error\":\"x\"}".utf8)
                )
            }
        }
    }

    // MARK: - Preview mapping

    @Test func toRecipePreview_blanksToNil_tagsToHashtags_categoriesEmpty() throws {
        let resp = try JSONDecoder().decode(
            ExtractRecipeResponse.self, from: Data(Self.cleanFixture.utf8)
        )
        let preview = try #require(resp.recipe).toRecipePreview()
        #expect(preview.id.isEmpty && preview.author.isEmpty && preview.dTag.isEmpty)
        #expect(preview.title == "BA’s Best Chocolate Chip Cookies")
        #expect(preview.image?.hasPrefix("https://assets.bonappetit.com/") == true)
        #expect(preview.hashtags == ["Dessert", "Cookie", "Chocolate", "Snack", "Easy"])
        #expect(preview.categories.isEmpty)
        #expect(preview.content.details.prepTime == "20 min")
        #expect(preview.content.details.servings == "16")
        #expect(preview.content.ingredients.count == 10)
        #expect(preview.content.directions.count == 8)
        #expect(preview.content.additionalMarkdown == nil)
    }

    @Test func toRecipePreview_partial_yieldsNilsAndNoCover() throws {
        let resp = try JSONDecoder().decode(
            ExtractRecipeResponse.self, from: Data(Self.partialFixture.utf8)
        )
        let preview = try #require(resp.recipe).toRecipePreview()
        #expect(preview.title == nil)
        #expect(preview.image == nil)
        #expect(preview.summary == "A fragment.")
        #expect(preview.content.details.prepTime == nil)
        #expect(preview.content.details.servings == nil)
        #expect(preview.content.directions.isEmpty)
    }

    // MARK: - Compute client pin

    @Test @MainActor func serviceUsesComputeClient() {
        // Identity, not just equal config: a refactor onto generalClient
        // (15 s) must fail here, not surface as field timeouts.
        #expect(SousChefImportService().client === HttpClientFactory.computeClient)
        #expect(SousChefImportService().client.configuration.timeoutIntervalForResource == 75)
    }

    // MARK: - Kill switch / gates

    @Test @MainActor func killSwitch_offHidesEntry_defaultIsOn() {
        #expect(!SousChefGate.entryVisible(flagEnabled: false))
        #expect(SousChefGate.entryVisible(flagEnabled: true))
        #expect(FeatureFlags.sousChefImportEnabled)
        #expect(SousChefGate.entryVisible())
    }

    @Test @MainActor func shouldOpenConfirm_truthTable() {
        #expect(SousChefGate.shouldOpenConfirm(canSign: true, hasImage: true, publishing: false))
        #expect(!SousChefGate.shouldOpenConfirm(canSign: false, hasImage: true, publishing: false))
        #expect(!SousChefGate.shouldOpenConfirm(canSign: true, hasImage: false, publishing: false))
        #expect(!SousChefGate.shouldOpenConfirm(canSign: true, hasImage: true, publishing: true))
    }

    @Test @MainActor func isImportUrl_wholeTokenRule() {
        #expect(SousChefGate.isImportUrl("https://example.com/recipes/sheet-pan-chicken"))
        #expect(SousChefGate.isImportUrl("  HTTP://e.com/r  "))
        #expect(!SousChefGate.isImportUrl(""))
        #expect(!SousChefGate.isImportUrl("example.com/recipe"))
        #expect(!SousChefGate.isImportUrl("check out https://e.com/r"))
        #expect(!SousChefGate.isImportUrl("https://e.com/a b"))
    }

    // MARK: - Error copy (Android parity)

    @Test @MainActor func importErrorMessage_perClass() {
        #expect(
            SousChefViewModel.importErrorMessage(.rateLimited(retryAfter: nil))
                == "Too many imports right now — try again in a bit."
        )
        #expect(
            SousChefViewModel.importErrorMessage(.rateLimited(retryAfter: 1800))
                == "Too many imports right now — try again in a bit. You can try again in about 30 minutes."
        )
        #expect(
            SousChefViewModel.importErrorMessage(.rateLimited(retryAfter: 45))
                == "Too many imports right now — try again in a bit. You can try again in about a minute."
        )
        #expect(
            SousChefViewModel.importErrorMessage(
                .apiRejected(code: "SOURCE_BLOCKED", message: "That site blocks imports.")
            ) == "That site blocks imports."
        )
        #expect(
            SousChefViewModel.importErrorMessage(.apiRejected(code: nil, message: nil))
                == "Couldn't import a recipe from that link."
        )
        #expect(
            SousChefViewModel.importErrorMessage(.requestFailed(status: 503, body: nil))
                == "Import failed (503)."
        )
        #expect(
            SousChefViewModel.importErrorMessage(
                .transport(SousChefImportService.timedOutTransportMessage)
            ) == "That site is taking too long — try again in a moment."
        )
        #expect(
            SousChefViewModel.importErrorMessage(.transport("Could not connect to the server."))
                == "Network error — check your connection and try again."
        )
        #expect(
            SousChefViewModel.importErrorMessage(.decoding("bad JSON"))
                == "Network error — check your connection and try again."
        )
    }

    // MARK: - Edit hand-off markdown

    @Test @MainActor func composeHandoffMarkdown_headingAndSections() throws {
        let resp = try JSONDecoder().decode(
            ExtractRecipeResponse.self, from: Data(Self.cleanFixture.utf8)
        )
        let preview = try #require(resp.recipe).toRecipePreview()
        let markdown = SousChefViewModel.composeHandoffMarkdown(preview)
        #expect(markdown.hasPrefix("# BA’s Best Chocolate Chip Cookies\n"))
        #expect(markdown.contains("## Ingredients"))
        #expect(markdown.contains("## Directions"))
        // Multiplier 1 must not rewrite quantities.
        #expect(markdown.contains("1½ cups plus 1 Tbsp. (200 g) all-purpose flour"))
    }

    @Test @MainActor func composeHandoffMarkdown_untitledFallback_andScaling() {
        let recipe = NormalizedRecipe(
            servings: "2",
            ingredients: ["2 cups flour"],
            directions: ["Mix."]
        ).toRecipePreview()
        let markdown = SousChefViewModel.composeHandoffMarkdown(recipe, multiplier: 2.0)
        #expect(markdown.hasPrefix("# Untitled\n"))
        #expect(markdown.contains(IngredientScaler.scaleLine("2 cups flour", multiplier: 2.0)))
        #expect(markdown.contains("Servings: \(IngredientScaler.scaleLine("2", multiplier: 2.0))"))
    }

    @Test @MainActor func handoff_roundTrips_intoComposePrefill() throws {
        let resp = try JSONDecoder().decode(
            ExtractRecipeResponse.self, from: Data(Self.cleanFixture.utf8)
        )
        let preview = try #require(resp.recipe).toRecipePreview()
        let markdown = SousChefViewModel.composeHandoffMarkdown(preview)

        let vm = RecipeComposeViewModel(env: RecipeComposeViewModel.Environment(
            uploadImage: { _, _, _ in "" },
            compressImage: { data, mime in (data, mime) }
        ))
        vm.prefillFromMarkdown(markdown)
        #expect(vm.title == "BA’s Best Chocolate Chip Cookies")
        #expect(vm.ingredients.count == 10)
        #expect(vm.directions.count == 8)
        #expect(vm.prepTime == "20 min")
        #expect(vm.cookTime == "10 min")
        #expect(vm.servings == "16")
        #expect(vm.prefillNotice == nil)
        // The hand-off drops images/categories/summary by design
        // (Android/web parity) — compose demands its own photo + category.
        #expect(vm.images.isEmpty)
        #expect(vm.categories.isEmpty)
        #expect(vm.summary == "")
        #expect(vm.blockReason(canSign: true) != nil)
    }

    // MARK: - View model state machine

    @Test @MainActor func importUrl_success_landsInPreview_andResetsScale() async throws {
        let recipe = try #require(
            try JSONDecoder().decode(
                ExtractRecipeResponse.self, from: Data(Self.cleanFixture.utf8)
            ).recipe
        )
        let vm = SousChefViewModel(importRecipe: { _ in recipe })
        vm.scale = 2.0
        vm.importUrl("https://www.bonappetit.com/recipe/x")
        try await waitUntil { vm.state != .loading }
        #expect(vm.state == .preview(recipe.toRecipePreview()))
        #expect(vm.scale == 1.0)
        #expect(vm.scaledIngredients.count == 10)
    }

    @Test @MainActor func importUrl_apiError_rendersAndroidCopy() async throws {
        let vm = SousChefViewModel(importRecipe: { _ in
            throw ZapCookingApiError.rateLimited(retryAfter: nil)
        })
        vm.importUrl("https://e.com/r")
        try await waitUntil { vm.state != .loading }
        #expect(vm.state == .error("Too many imports right now — try again in a bit."))
    }

    @Test @MainActor func importUrl_ignoresBlankInput_andReentry() async throws {
        let calls = Counter()
        let vm = SousChefViewModel(importRecipe: { _ in
            await calls.increment()
            // Park until cancelled — the second call below must not stack.
            try await Task.sleep(for: .seconds(60))
            return NormalizedRecipe()
        })
        vm.importUrl("   ")
        #expect(vm.state == .idle)

        vm.importUrl("https://e.com/r")
        #expect(vm.state == .loading)
        vm.importUrl("https://e.com/other")
        try await waitUntil { await calls.value >= 1 }
        // Yield a few extra turns: a second task would have incremented by now.
        for _ in 0..<5 { await Task.yield() }
        #expect(await calls.value == 1)
        #expect(vm.state == .loading)
    }

    @Test @MainActor func publish_withoutKey_setsSignInCopy_perAction() async {
        let recipe = NormalizedRecipe(
            title: "T", ingredients: ["i"], directions: ["d"],
            imageUrls: ["https://e.com/i.jpg"]
        )
        let vm = SousChefViewModel(importRecipe: { _ in recipe })
        vm.importUrl("https://e.com/r")
        try? await waitUntil { vm.state != .loading }

        await vm.publish(
            publisher: RecipePublisher.shared, keypair: nil, includeClientTag: false
        )
        #expect(vm.publishState == .error("Sign in to publish recipes."))

        await vm.saveToCookbook(
            publisher: RecipePublisher.shared,
            bookmarks: RecipeBookmarkRepository.shared,
            keypair: nil,
            includeClientTag: false
        )
        #expect(vm.publishState == .error("Sign in to save recipes to My Kitchen."))
    }

    @Test @MainActor func publish_withoutPreview_isNoOp() async {
        let vm = SousChefViewModel(importRecipe: { _ in NormalizedRecipe() })
        await vm.publish(
            publisher: RecipePublisher.shared, keypair: nil, includeClientTag: false
        )
        #expect(vm.publishState == .idle)
    }

    // MARK: - Helpers

    private actor Counter {
        private(set) var value = 0
        func increment() { value += 1 }
    }

    @MainActor
    private func waitUntil(
        timeout: TimeInterval = 5,
        _ condition: @MainActor () async -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        Issue.record("waitUntil timed out")
    }
}
