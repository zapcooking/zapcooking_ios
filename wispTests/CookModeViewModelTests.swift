import Foundation
import SwiftUI
import Testing
@testable import wisp

/// Concern 1.8b — `CookWakeLock` is refcounted and scoped to screen
/// visibility, never to a running timer. Tests drive a recording setter
/// so the suite does not touch the process idle timer.
@MainActor
struct CookWakeLockTests {

    @Test func acquire_setsIdleTimer_releaseClearsWhenCountHitsZero() {
        var applied: [Bool] = []
        let lock = CookWakeLock(applyIdleTimer: { applied.append($0) })

        lock.acquire()
        #expect(lock.count == 1)
        #expect(lock.isIdleTimerDisabled)
        #expect(lock.lastApplied == true)
        #expect(applied == [true])

        lock.acquire()
        #expect(lock.count == 2)
        #expect(lock.lastApplied == true)
        #expect(applied == [true, true])

        lock.release()
        #expect(lock.count == 1)
        #expect(lock.isIdleTimerDisabled)
        #expect(lock.lastApplied == true)

        lock.release()
        #expect(lock.count == 0)
        #expect(lock.isIdleTimerDisabled == false)
        #expect(lock.lastApplied == false)
        #expect(applied.last == false)
    }

    @Test func release_atZero_isNoOp() {
        var applied: [Bool] = []
        let lock = CookWakeLock(applyIdleTimer: { applied.append($0) })
        lock.release()
        #expect(lock.count == 0)
        #expect(applied.isEmpty)
        #expect(lock.lastApplied == false)
    }

    @Test func forceZero_dropsEveryClaim_idleTimerFalse() {
        var applied: [Bool] = []
        let lock = CookWakeLock(applyIdleTimer: { applied.append($0) })
        lock.acquire()
        lock.acquire()
        lock.forceZero()
        #expect(lock.count == 0)
        #expect(lock.isIdleTimerDisabled == false)
        #expect(lock.lastApplied == false)
        #expect(applied.last == false)
    }
}

/// Pager + snapshot + the appear/background/disappear pairing the view
/// uses. After disappear, `lastApplied` is asserted false explicitly —
/// gate 2, do not assume teardown ran.
@MainActor
struct CookModeViewModelTests {

    private func lock() -> (CookWakeLock, Box<[Bool]>) {
        let applied = Box<[Bool]>([])
        let wake = CookWakeLock(applyIdleTimer: { applied.value.append($0) })
        return (wake, applied)
    }

    private func recipe(
        title: String = "Soup",
        ingredients: [String] = ["1 cup flour", "Salt"],
        directions: [String] = ["Mix.", "Bake."],
        servings: String? = "4",
        prepTime: String? = "10 min",
        cookTime: String? = "30 min"
    ) -> RecipeParser.Recipe {
        RecipeParser.Recipe(
            id: "aa",
            author: String(repeating: "a", count: 64),
            dTag: "soup",
            title: title,
            images: [],
            summary: nil,
            publishedAt: 0,
            hashtags: ["zapcooking"],
            categories: [],
            content: RecipeParser.RecipeContent(
                details: RecipeParser.RecipeDetails(
                    prepTime: prepTime,
                    cookTime: cookTime,
                    servings: servings
                ),
                ingredients: ingredients,
                directions: directions
            )
        )
    }

    private func tuscan() -> RecipeParser.Recipe {
        guard let event = NostrEvent.fromJSON(RecipeParserTests.tuscanPeposoJSON) else {
            Issue.record("Tuscan Peposo fixture failed to decode")
            fatalError("fixture decode failed")
        }
        return RecipeParser.parse(event)
    }

    // MARK: - Snapshot scale

    @Test func snapshot_at2x_doublesLeadingQuantities_notDirections() {
        let session = CookModeSession.snapshot(recipe: tuscan(), scale: 2.0)
        #expect(session.scale == 2.0)
        #expect(session.scaledIngredients.first == "2 kg beef for stewing (chuck or similar)")
        #expect(session.scaledIngredients.contains("1500 ml red wine"))
        #expect(session.scaledIngredients.contains("8 garlic cloves"))
        #expect(session.scaledIngredients.contains("Salt"))
        #expect(session.scaledServings == nil)
        #expect(session.directions.count == 6)
        #expect(session.directions.first == "Cut beef into large chunks.")
        #expect(session.directions.last == "Rest 10 minutes, adjust salt, serve hot.")
    }

    @Test func snapshot_scalesServings_omitsPrepAndCook() {
        let session = CookModeSession.snapshot(
            recipe: recipe(servings: "4", prepTime: "10 min", cookTime: "3 hours"),
            scale: 2.0
        )
        #expect(session.scaledServings == "8")
        #expect(session.scaledIngredients.contains("2 cup flour"))
        // Session has no prep/cook fields — they do not scale and they
        // are not shown in cook mode.
        #expect(session.directions == ["Mix.", "Bake."])
    }

    @Test func snapshot_isFrozen_laterRecipeMutationDoesNotBind() {
        var source = recipe(ingredients: ["1 kg beef"], directions: ["Cook."])
        let session = CookModeSession.snapshot(recipe: source, scale: 2.0)
        source.content.ingredients = ["9 kg beef"]
        source.content.directions = ["Changed."]
        #expect(session.scaledIngredients == ["2 kg beef"])
        #expect(session.directions == ["Cook."])
    }

    @Test func snapshot_doesNotParseDurationFromStepText() {
        let steps = [
            "Rest 10 minutes, adjust salt.",
            "Add 2 cups water.",
            "Bake at 350°F.",
        ]
        let session = CookModeSession.snapshot(
            recipe: recipe(directions: steps),
            scale: 1.0
        )
        #expect(session.directions == steps)
        // No duration field exists to auto-fill. A wrong timer is worse
        // than no timer; Add timer opens the 1.8a sheet as-is.
    }

    // MARK: - Pager

    @Test func pager_singleLongStep_usable() {
        let long = String(repeating: "Stir the pot. ", count: 40)
        let session = CookModeSession.snapshot(
            recipe: recipe(directions: [long]),
            scale: 1.0
        )
        let vm = CookModeViewModel(session: session, wakeLock: lock().0)
        #expect(vm.stepCount == 1)
        #expect(vm.stepPositionLabel == "Step 1 of 1")
        #expect(vm.canGoBack == false)
        #expect(vm.canGoForward == false)
        #expect(vm.currentStepText == long)
        vm.goForward()
        vm.goBack()
        #expect(vm.stepIndex == 0)
    }

    @Test func pager_sixteenSteps_pagesAndClamps() {
        let steps = (1...16).map { "Do thing \($0)." }
        let session = CookModeSession.snapshot(
            recipe: recipe(directions: steps),
            scale: 1.0
        )
        let vm = CookModeViewModel(session: session, wakeLock: lock().0)
        #expect(vm.stepCount == 16)
        #expect(vm.stepPositionLabel == "Step 1 of 16")
        #expect(vm.canGoBack == false)
        #expect(vm.canGoForward)

        vm.goBack()
        #expect(vm.stepIndex == 0)

        for _ in 0..<15 { vm.goForward() }
        #expect(vm.stepIndex == 15)
        #expect(vm.stepPositionLabel == "Step 16 of 16")
        #expect(vm.canGoForward == false)
        #expect(vm.currentStepText == "Do thing 16.")

        vm.goForward()
        #expect(vm.stepIndex == 15)

        vm.goBack()
        #expect(vm.stepIndex == 14)
        #expect(vm.stepPositionLabel == "Step 15 of 16")
    }

    // MARK: - Wake lock pairing (gates 2 and 3)

    @Test func appear_thenDisappear_idleTimerFalseExplicitly() {
        let (wake, applied) = lock()
        let vm = CookModeViewModel(
            session: CookModeSession.snapshot(recipe: recipe(), scale: 1),
            wakeLock: wake
        )
        vm.onAppear(phase: .active)
        #expect(wake.isIdleTimerDisabled)
        #expect(wake.lastApplied == true)

        vm.onDisappear()
        // Gate 2: check the setter, do not assume teardown ran.
        #expect(wake.count == 0)
        #expect(wake.isIdleTimerDisabled == false)
        #expect(wake.lastApplied == false)
        #expect(applied.value.last == false)
    }

    @Test func backgroundReleases_activeReacquires() {
        let (wake, _) = lock()
        let vm = CookModeViewModel(
            session: CookModeSession.snapshot(recipe: recipe(), scale: 1),
            wakeLock: wake
        )
        vm.onAppear(phase: .active)
        #expect(wake.lastApplied == true)

        vm.handleScenePhase(.background)
        #expect(wake.count == 0)
        #expect(wake.lastApplied == false)

        vm.handleScenePhase(.active)
        #expect(wake.count == 1)
        #expect(wake.lastApplied == true)
    }

    @Test func inactiveReleases_likeBackground() {
        let (wake, _) = lock()
        let vm = CookModeViewModel(
            session: CookModeSession.snapshot(recipe: recipe(), scale: 1),
            wakeLock: wake
        )
        vm.onAppear(phase: .active)
        vm.handleScenePhase(.inactive)
        #expect(wake.lastApplied == false)
        #expect(wake.isIdleTimerDisabled == false)
    }

    @Test func terminate_forceZeros() {
        let (wake, applied) = lock()
        let vm = CookModeViewModel(
            session: CookModeSession.snapshot(recipe: recipe(), scale: 1),
            wakeLock: wake
        )
        vm.onAppear(phase: .active)
        vm.handleTerminate()
        #expect(wake.count == 0)
        #expect(wake.lastApplied == false)
        #expect(applied.value.last == false)
    }

    @Test func appearTwice_doesNotDoubleAcquire() {
        let (wake, _) = lock()
        let vm = CookModeViewModel(
            session: CookModeSession.snapshot(recipe: recipe(), scale: 1),
            wakeLock: wake
        )
        vm.onAppear(phase: .active)
        vm.onAppear(phase: .active)
        #expect(wake.count == 1)
        vm.onDisappear()
        #expect(wake.count == 0)
        #expect(wake.lastApplied == false)
    }

    @Test func wakeLockIsNotTiedToATimer() {
        // The lock has no timer API. Disappear releases even if the
        // caller would still have a 45-minute casserole running.
        let (wake, _) = lock()
        let vm = CookModeViewModel(
            session: CookModeSession.snapshot(recipe: recipe(), scale: 1),
            wakeLock: wake
        )
        vm.onAppear(phase: .active)
        vm.onDisappear()
        #expect(wake.isIdleTimerDisabled == false)
        #expect(wake.lastApplied == false)
    }
}

/// Mutable box so the idle-timer closure can append without capturing a var.
private final class Box<T> {
    var value: T
    init(_ value: T) { self.value = value }
}
