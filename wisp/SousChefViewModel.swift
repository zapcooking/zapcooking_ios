import Foundation
import Observation

/// Sous Chef — AI recipe import (Concern 2.5, port of Android
/// `SousChefViewModel`). v1 ships the **URL mode only**: free, anonymous,
/// IP-rate-limited (`SousChefImportService`). The member-gated image/text
/// modes are P2 and deliberately absent — with them goes the upsell
/// banner/membership machinery (nothing on this screen is gated).
///
/// From the read-only preview the user can **Publish** (the existing
/// `RecipePublisher` single-image Sous Chef path — source-image re-host
/// with URL fallback), **Save to my recipes** (publish + add to the
/// default Saved list; Cookbook membership requires a published event —
/// there is no local-only bookmark for an unpublished extraction),
/// **Edit** (markdown hand-off into `RecipeComposeView` via
/// `.prefillMarkdown`), or **Discard**.
///
/// The serving multiplier scales the *display* and the Edit hand-off;
/// Publish always publishes the recipe as imported (Android parity).
@Observable
@MainActor
final class SousChefViewModel {

    enum State: Equatable {
        case idle
        case loading
        case preview(RecipeParser.Recipe)
        case error(String)
    }

    /// Publish overlay state, distinct from the import `state`.
    enum PublishState: Equatable {
        case idle
        case publishing
        case published(author: String, dTag: String, savedToCookbook: Bool)
        case error(String)
    }

    private(set) var state: State = .idle
    private(set) var publishState: PublishState = .idle
    /// ½× / 1× / 2× / 3× display multiplier (same chip set as recipe
    /// detail). Reset with each new preview.
    var scale: Double = 1.0

    /// Test/production seam — production is the compute-client service.
    private let importRecipe: (String) async throws -> NormalizedRecipe

    init(importRecipe: ((String) async throws -> NormalizedRecipe)? = nil) {
        self.importRecipe = importRecipe ?? { try await SousChefImportService().importRecipe(from: $0) }
    }

    var previewRecipe: RecipeParser.Recipe? {
        if case .preview(let recipe) = state { return recipe }
        return nil
    }

    /// Ingredients with the current scale applied (unparseable lines stay
    /// verbatim — `IngredientScaler`'s contract).
    var scaledIngredients: [String] {
        guard let recipe = previewRecipe else { return [] }
        return recipe.content.ingredients.map { IngredientScaler.scaleLine($0, multiplier: scale) }
    }

    /// Servings chip, scaled. Prep/cook are free-text and never scaled.
    var scaledServings: String? {
        guard let raw = previewRecipe?.content.details.servings else { return nil }
        return IngredientScaler.scaleLine(raw, multiplier: scale)
    }

    // MARK: - Import

    func importUrl(_ rawUrl: String) {
        let url = rawUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        if url.isEmpty { return }
        // Re-entrancy guard the Android URL path relies on UI disabling
        // for (its known gap) — the state machine owns it here.
        if state == .loading { return }
        state = .loading
        // A fresh import starts a fresh publish story — a stale publish
        // error from the previous preview must not render under the next.
        publishState = .idle
        Task {
            do {
                let recipe = try await importRecipe(url)
                scale = 1.0
                state = .preview(recipe.toRecipePreview())
            } catch is CancellationError {
                return
            } catch let error as ZapCookingApiError {
                state = .error(Self.importErrorMessage(error))
            } catch {
                state = .error(Self.networkErrorCopy)
            }
        }
    }

    /// Android `SousChefViewModel.import` error branches, copy verbatim,
    /// mapped from the 0.7a taxonomy instead of raw HTTP codes. Pure —
    /// unit-tested per class.
    static func importErrorMessage(_ error: ZapCookingApiError) -> String {
        switch error {
        case .rateLimited(let retryAfter):
            // Android copy verbatim; unlike the web (which drops the field
            // on the floor), a server-provided retryAfter is surfaced.
            guard let retryAfter, retryAfter > 0 else { return Self.rateLimitedCopy }
            return Self.rateLimitedCopy + " You can try again in about \(Self.formatRetryAfter(retryAfter))."
        case .apiRejected(_, let message):
            // Server error string when present (Android's 400/`resp.error`
            // preference), else the generic import-failure line.
            return message ?? "Couldn't import a recipe from that link."
        case .requestFailed(let status, _):
            return "Import failed (\(status))."
        case .transport(let message) where message == SousChefImportService.timedOutTransportMessage:
            // Server-side URL extraction (page fetch + LLM parse) can
            // outlast even the compute client's 75 s on a slow/heavy site
            // — a "try again" case, not a connectivity failure.
            return "That site is taking too long — try again in a moment."
        default:
            return Self.networkErrorCopy
        }
    }

    static let rateLimitedCopy = "Too many imports right now — try again in a bit."
    static let networkErrorCopy = "Network error — check your connection and try again."

    static func formatRetryAfter(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded(.up))
        if minutes <= 1 { return "a minute" }
        return "\(minutes) minutes"
    }

    // MARK: - Publish / Save

    /// Publish the previewed recipe as a signed kind-30023. Categories come
    /// from the imported recipe's tags (mapped into `hashtags` by
    /// `toRecipePreview`). The UI confirms before calling this.
    func publish(publisher: RecipePublisher, keypair: Keypair?, includeClientTag: Bool) async {
        await runPublish(
            publisher: publisher, keypair: keypair,
            includeClientTag: includeClientTag, saveToCookbook: nil
        )
    }

    /// Publish, then add the published event to the canonical **Saved**
    /// list. Best-effort on the list write: publish succeeded, so a failed
    /// Cookbook write still lands on the published recipe (Android parity).
    func saveToCookbook(
        publisher: RecipePublisher,
        bookmarks: RecipeBookmarkRepository,
        keypair: Keypair?,
        includeClientTag: Bool
    ) async {
        await runPublish(
            publisher: publisher, keypair: keypair,
            includeClientTag: includeClientTag, saveToCookbook: bookmarks
        )
    }

    private func runPublish(
        publisher: RecipePublisher,
        keypair: Keypair?,
        includeClientTag: Bool,
        saveToCookbook: RecipeBookmarkRepository?
    ) async {
        guard let recipe = previewRecipe else { return }
        if publishState == .publishing { return }
        guard let keypair, !keypair.isWatchOnly else {
            publishState = .error(
                saveToCookbook != nil
                    ? "Sign in to save recipes to My Kitchen."
                    : "Sign in to publish recipes."
            )
            return
        }
        publishState = .publishing
        do {
            let result = try await publisher.publish(
                recipe: recipe,
                categories: recipe.hashtags,
                keypair: keypair,
                includeClientTag: includeClientTag
            )
            switch result {
            case .error(let message):
                publishState = .error(message)
            case .published(let author, let dTag, let event, _, _):
                if let saveToCookbook {
                    // Deterministic add to the default Saved list; failure
                    // is swallowed on purpose (publish already succeeded).
                    _ = await saveToCookbook.setRecipeInList(
                        dTag: RecipeBookmarkRepository.defaultListDTag,
                        event: event,
                        add: true,
                        keypair: keypair
                    )
                }
                publishState = .published(
                    author: author, dTag: dTag,
                    savedToCookbook: saveToCookbook != nil
                )
            }
        } catch is CancellationError {
            publishState = .idle
        } catch {
            publishState = .error(error.localizedDescription)
        }
    }

    func reset() {
        state = .idle
        publishState = .idle
        scale = 1.0
    }

    // MARK: - Edit hand-off

    /// Markdown payload for the composer hand-off
    /// (`RecipeComposeSession.prefillMarkdown` →
    /// `RecipeComposeViewModel.prefillFromMarkdown`). Pure port of Android
    /// `toComposeHandoffMarkdown`: applies the preview multiplier to
    /// ingredient quantities and servings, prefixes a `# Title` heading so
    /// prefill can extract it, then serializes via
    /// `RecipeSerializer.toContent`. No signing, no relays, no persistence.
    static func composeHandoffMarkdown(
        _ recipe: RecipeParser.Recipe, multiplier: Double = 1.0
    ) -> String {
        var scaled = recipe
        if abs(multiplier - 1.0) >= 1e-6 {
            scaled.content.details.servings = scaled.content.details.servings.map {
                IngredientScaler.scaleLine($0, multiplier: multiplier)
            }
            scaled.content.ingredients = scaled.content.ingredients.map {
                IngredientScaler.scaleLine($0, multiplier: multiplier)
            }
        }
        let title = scaled.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let heading = "# \((title?.isEmpty == false ? title! : "Untitled"))\n"
        return heading + RecipeSerializer.toContent(scaled)
    }
}

/// Pure enablement + copy for the Sous Chef entry point and the Publish /
/// Save confirm steps (port of Android `SousChefPublishConfirm`). The UI
/// must open a confirm dialog when `shouldOpenConfirm` is true and only
/// call `publish`/`saveToCookbook` from the dialog's confirm button —
/// never from the primary tap itself.
enum SousChefGate {
    static let publishConfirmMessage =
        "Publish to your followers? This posts the recipe publicly under your account."

    /// Honest copy: Saved-list membership requires a published a-coordinate.
    static let cookbookSaveConfirmMessage =
        "Save to My Kitchen? This publishes the recipe publicly under your account and adds it to your Saved list."

    static let savedToast = "Saved to My Kitchen"

    static func shouldOpenConfirm(canSign: Bool, hasImage: Bool, publishing: Bool) -> Bool {
        canSign && hasImage && !publishing
    }

    /// Kill switch → entry point. The flag is compile-time
    /// (`FeatureFlags.sousChefImportEnabled`); this seam is what the
    /// entry-point call sites branch on so the off state is assertable.
    static func entryVisible(flagEnabled: Bool = FeatureFlags.sousChefImportEnabled) -> Bool {
        flagEnabled
    }

    /// URL auto-detection for the input field. Verbatim port of the web
    /// `detectMode`'s URL rule (Android `SousChefDetect`): the **entire**
    /// trimmed input must be one `http(s)://` token. The image/text rules
    /// arrive with P2.
    static func isImportUrl(_ input: String) -> Bool {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return false }
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        return Self.urlToken.firstMatch(in: trimmed, range: range) != nil
    }

    private static let urlToken = try! NSRegularExpression(
        pattern: "^https?://\\S+$",
        options: .caseInsensitive
    )
}
