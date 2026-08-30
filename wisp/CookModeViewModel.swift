import Foundation
import Observation
import SwiftUI

/// Frozen cook-mode payload. Scale is snapshotted at "Start cooking" —
/// there is no live binding back to `RecipeDetailViewModel`. Directions
/// and prep / cook times are copied verbatim and never scaled.
///
/// Concern 1.8b. iOS-original; Android's cook mode was never wired.
struct CookModeSession: Identifiable, Equatable {
    let id: UUID
    let title: String
    let directions: [String]
    let scaledIngredients: [String]
    let scaledServings: String?
    let scale: Double

    init(
        title: String,
        directions: [String],
        scaledIngredients: [String],
        scaledServings: String?,
        scale: Double,
        id: UUID = UUID()
    ) {
        self.id = id
        self.title = title
        self.directions = directions
        self.scaledIngredients = scaledIngredients
        self.scaledServings = scaledServings
        self.scale = scale
    }

    /// Snapshot the recipe at `scale`. Ingredients and servings go through
    /// `IngredientScaler`; directions do not. Prep / cook are omitted —
    /// they do not scale and they are not needed mid-step.
    static func snapshot(recipe: RecipeParser.Recipe, scale: Double) -> CookModeSession {
        CookModeSession(
            title: recipe.title ?? "Untitled",
            directions: recipe.content.directions,
            scaledIngredients: recipe.content.ingredients.map {
                IngredientScaler.scaleLine($0, multiplier: scale)
            },
            scaledServings: recipe.content.details.servings.map {
                IngredientScaler.scaleLine($0, multiplier: scale)
            },
            scale: scale
        )
    }
}

/// Pager + wake-lock claims for `CookModeView`. One cook-mode screen holds
/// at most one wake-lock claim, and only while it is visible *and* the
/// scene is `.active`.
@Observable
@MainActor
final class CookModeViewModel {

    let session: CookModeSession
    var stepIndex: Int = 0
    var ingredientsExpanded: Bool = false

    var stepCount: Int { session.directions.count }
    var hasSteps: Bool { stepCount > 0 }
    var canGoBack: Bool { stepIndex > 0 }
    var canGoForward: Bool { stepIndex + 1 < stepCount }

    var stepPositionLabel: String {
        guard hasSteps else { return "No steps" }
        return "Step \(stepIndex + 1) of \(stepCount)"
    }

    var currentStepText: String {
        guard session.directions.indices.contains(stepIndex) else { return "" }
        return session.directions[stepIndex]
    }

    /// Exposed so tests can assert the idle-timer setter, not just the count.
    let wakeLock: CookWakeLock

    @ObservationIgnored private var visible = false
    @ObservationIgnored private var scenePhase: ScenePhase = .active
    @ObservationIgnored private var holding = false

    init(session: CookModeSession, wakeLock: CookWakeLock = .shared) {
        self.session = session
        self.wakeLock = wakeLock
    }

    func goBack() {
        guard canGoBack else { return }
        stepIndex -= 1
    }

    func goForward() {
        guard canGoForward else { return }
        stepIndex += 1
    }

    func onAppear(phase: ScenePhase) {
        visible = true
        scenePhase = phase
        syncWakeLock()
    }

    func onDisappear() {
        visible = false
        syncWakeLock()
    }

    func handleScenePhase(_ phase: ScenePhase) {
        scenePhase = phase
        syncWakeLock()
    }

    func handleTerminate() {
        wakeLock.forceZero()
        holding = false
    }

    /// +1 while visible and `.active`. `-1` on disappear / background /
    /// inactive so this screen drops only its own claim. `forceZero` is
    /// terminate-only — the process is dying, and `forceZero` on a live
    /// shared lock would clear another window's cook-mode claim.
    private func syncWakeLock() {
        let shouldHold = visible && scenePhase == .active
        if shouldHold {
            if !holding {
                wakeLock.acquire()
                holding = true
            }
        } else if holding {
            wakeLock.release()
            holding = false
        }
    }
}
