import Foundation
import Testing
@testable import wisp

/// Live gate for Concern 2.5 — one real `POST /api/extract-recipe/public`.
///
/// Opt-in only (same mechanism as `Nip98LiveRoundTripTests`): touch
/// `wispTests/.souschef_live_enable` or set `SOUSCHEF_LIVE=1`. The endpoint
/// is anonymous, so no key is held and nothing is published — no §7.13
/// cleanup applies. It IS per-IP rate-limited (8/hr shared with any other
/// machine on the same egress IP), so this file makes exactly **one
/// request to one site** and must never join the default suite.
///
/// Site choice: Bon Appétit — verified working against this endpoint on
/// 2026-09-01 (the recorded clean fixture in `SousChefTests` is that
/// capture). AllRecipes returned `SOURCE_UNAVAILABLE` the same day, so a
/// transient failure here should be read alongside `errorFixture`: the
/// extraction pipeline's upstream fetch does flake per-site.
@Suite(.tags(.liveNetwork))
struct SousChefLiveTests {

    private static var isDeliberatelyEnabled: Bool {
        let enableURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent(".souschef_live_enable")
        if FileManager.default.fileExists(atPath: enableURL.path) { return true }
        return ProcessInfo.processInfo.environment["SOUSCHEF_LIVE"] == "1"
    }

    @Test(
        .tags(.liveNetwork),
        .enabled(
            if: SousChefLiveTests.isDeliberatelyEnabled,
            "Opt in: touch wispTests/.souschef_live_enable (one request, one rate-limit token)"
        )
    )
    @MainActor func urlImport_extractsARealRecipe() async throws {
        let recipe = try await SousChefImportService().importRecipe(
            from: "https://www.bonappetit.com/recipe/bas-best-chocolate-chip-cookies"
        )
        #expect(!recipe.title.isEmpty)
        #expect(!recipe.ingredients.isEmpty)
        #expect(!recipe.directions.isEmpty)
        #expect(!recipe.imageUrls.isEmpty)

        // The whole flow the screen runs: preview mapping + compose hand-off
        // both hold on live data.
        let preview = recipe.toRecipePreview()
        #expect(preview.image != nil)
        let markdown = SousChefViewModel.composeHandoffMarkdown(preview)
        #expect(markdown.contains("## Ingredients"))
        #expect(markdown.contains("## Directions"))
    }
}
