import Foundation
import SwiftUI
import Testing
@testable import wisp

/// Hermetic coverage of Concern C-E — Cheffy chat. The web-ported copy
/// pools and recipe gates (cases from `src/lib/cheffy.test.ts`), the
/// auth-agnostic request shape, response decoding, the stateless-history
/// builder, the 0.7a error → bubble mapping, the membership gate mapping,
/// the compute-client pin, the kill switch, and the SVG path parser behind
/// `CheffyIcon`. This file never opens a socket; the opt-in network checks
/// live in `CheffyLiveTests`.
@MainActor
struct CheffyTests {

    // MARK: - Copy pools / pickLine (web `pickLine` cases)

    @Test func pickLine_singleEntryPoolReturnsIt() {
        #expect(Cheffy.pickLine(["only"]) == "only")
        #expect(Cheffy.pickLine(["only"], avoid: "only") == "only")
    }

    @Test func pickLine_emptyPoolReturnsEmpty() {
        #expect(Cheffy.pickLine([]) == "")
    }

    @Test func pickLine_avoidsImmediateRepeatByOneReroll() {
        let pool = ["a", "b", "c"]
        // Forced to land on the avoided line: the re-roll steps to the next.
        #expect(Cheffy.pickLine(pool, avoid: "b", randomIndex: { _ in 1 }) == "c")
        // Wraps around at the end of the pool.
        #expect(Cheffy.pickLine(pool, avoid: "c", randomIndex: { _ in 2 }) == "a")
        // Not the avoided line: returned as rolled.
        #expect(Cheffy.pickLine(pool, avoid: "b", randomIndex: { _ in 0 }) == "a")
    }

    @Test func copyPools_matchTheWebVerbatim() {
        #expect(Cheffy.promptPlaceholders.count == 6)
        #expect(Cheffy.promptPlaceholders[0] == "What are we cooking?")
        #expect(Cheffy.thinkingLines.count == 5)
        #expect(Cheffy.thinkingLines[2] == "Thinking with my whole spatula…")
        #expect(Cheffy.cookingLines.count == 5)
        #expect(Cheffy.cookingLines[2] == "Dinner has entered the chat…")
        #expect(Cheffy.errorLines.count == 4)
        #expect(Cheffy.errorLines[0] == "Cheffy dropped a spoon. Try that again.")
    }

    // MARK: - Recipe gates (web `looksLikeStructuredRecipe` cases)

    static let fullRecipe = """
    # Garlic Butter Pasta

    A quick, forgiving weeknight pasta.

    ## Details
    ⏲️ Prep time: 5 min
    🍳 Cook time: 15 min
    🍽️ Servings: 2

    ## Ingredients
    - 200 g spaghetti
    - 3 cloves garlic, sliced
    - 3 tbsp butter

    ## Directions
    1. Boil the pasta.
    2. Melt the butter and soften the garlic.
    3. Toss together with a splash of pasta water.
    """

    @Test func structuredRecipe_trueForFullRecipe() {
        #expect(Cheffy.looksLikeStructuredRecipe(Self.fullRecipe))
    }

    @Test func structuredRecipe_falseForConversationalAnswer() {
        #expect(!Cheffy.looksLikeStructuredRecipe(
            "You can absolutely swap yogurt for sour cream — it's a little tangier but works great in most dishes."
        ))
    }

    @Test func structuredRecipe_falseWithOnlyIngredients() {
        #expect(!Cheffy.looksLikeStructuredRecipe("# Idea\n\n## Ingredients\n- eggs\n- cheese"))
    }

    @Test func structuredRecipe_falseForEmptyAndNil() {
        #expect(!Cheffy.looksLikeStructuredRecipe(""))
        #expect(!Cheffy.looksLikeStructuredRecipe(nil))
    }

    @Test func structuredRecipe_headingsAreCaseInsensitiveAndNeedATitle() {
        #expect(Cheffy.looksLikeStructuredRecipe("# T\n## ingredients\n- a\n## DIRECTIONS\n1. b"))
        // No `# Title` line → not a recipe, even with both sections.
        #expect(!Cheffy.looksLikeStructuredRecipe("## Ingredients\n- a\n## Directions\n1. b"))
    }

    @Test func recipeRequest_matchesTheWebRegexes() {
        #expect(Cheffy.looksLikeRecipeRequest("Give me a dinner idea"))
        #expect(Cheffy.looksLikeRecipeRequest("What can I cook tonight?"))
        #expect(Cheffy.looksLikeRecipeRequest("I have: eggs, spinach, feta"))
        #expect(Cheffy.looksLikeRecipeRequest("i have eggs and rice"))
        #expect(!Cheffy.looksLikeRecipeRequest("Can I substitute yogurt for sour cream?"))
        // Word boundary: "cookie" is not "cook".
        #expect(!Cheffy.looksLikeRecipeRequest("Why did my cookies spread?"))
    }

    // MARK: - Request / response shapes

    @Test func request_isAuthAgnostic_noIdentityField() throws {
        let request = CheffyRequest(
            prompt: "hi", mode: .chat,
            messages: [CheffyMessage(role: "user", content: "a"), CheffyMessage(role: "assistant", content: "b")]
        )
        let json = ZapCookingApi.encodeJSON(request)
        let object = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(object["prompt"] as? String == "hi")
        #expect(object["mode"] as? String == "chat")
        #expect((object["messages"] as? [[String: String]])?.count == 2)
        // The server ignores a body pubkey (NIP-98 since 04cf67cd); the
        // model must not carry one, so a future migration is a call-site
        // change and never a model change.
        #expect(object["pubkey"] == nil)
        #expect(object["experience"] == nil)
        #expect(Set(object.keys) == ["prompt", "mode", "messages"])
    }

    @Test func request_hungryEncodesEmptyPromptAndMode() throws {
        let json = ZapCookingApi.encodeJSON(CheffyRequest(prompt: "", mode: .hungry, messages: []))
        let object = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(object["mode"] as? String == "hungry")
        #expect(object["prompt"] as? String == "")
    }

    @Test func response_decodesSuccessAndFailureShapes() throws {
        let ok = try JSONDecoder().decode(CheffyResponse.self, from: Data(#"{"ok":true,"output":"Sure — use less."}"#.utf8))
        #expect(ok.ok && ok.output == "Sure — use less.")
        // Live capture 2026-09-01: the bare 403 — no `code`.
        let denied = try JSONDecoder().decode(
            CheffyResponse.self, from: Data(#"{"ok":false,"error":"Cheffy is available to Cook+ members."}"#.utf8)
        )
        #expect(!denied.ok && denied.code == nil && denied.error == "Cheffy is available to Cook+ members.")
        // Partial body never throws.
        let partial = try JSONDecoder().decode(CheffyResponse.self, from: Data("{}".utf8))
        #expect(!partial.ok && partial.output == nil)
    }

    @Test func serviceUsesComputeClient() {
        // Identity, not just equal config: a refactor onto generalClient
        // (15 s) must fail here — Cheffy is whole-response, no streaming.
        #expect(CheffyService().client === HttpClientFactory.computeClient)
        #expect(CheffyService().client.configuration.timeoutIntervalForResource == 75)
    }

    // MARK: - Error taxonomy → bubble (branches on the typed error, never a status)

    @Test func bubble_bare403IsUnavailable_notADenial() {
        let m = CheffyViewModel.bubble(for: .apiRejected(code: nil, message: "Cheffy is available to Cook+ members."), id: 1)
        #expect(m.kind == .error)
        #expect(m.content == Cheffy.unavailableMessage)
        // Client copy only: the server's denial string never reaches the bubble.
        #expect(m.statusLine == nil)
        #expect(!m.content.contains("Cook+"))
        #expect(m.content.contains("right now") && m.content.contains("Try again"))
    }

    @Test func bubble_notMemberCodeIsGatedMessageOnly() {
        let m = CheffyViewModel.bubble(for: .membersOnly, id: 1)
        #expect(m.kind == .gated)
        #expect(m.content == Cheffy.membersOnlyMessage)
        // §4.3: no purchase surface in any gate copy.
        for copy in [Cheffy.membersOnlyMessage, Cheffy.unavailableMessage, Cheffy.signInMessage] {
            #expect(!copy.lowercased().contains("http"))
            #expect(!copy.contains("$") && !copy.lowercased().contains("subscribe") && !copy.lowercased().contains("upgrade"))
        }
        #expect(!FeatureFlags.membershipLinkoutEnabled)
    }

    @Test func bubble_codedRejectionShowsServerMessage() {
        let m = CheffyViewModel.bubble(for: .apiRejected(code: "SOMETHING", message: "Input is too long"), id: 1)
        #expect(m.kind == .error && m.content == "Input is too long")
    }

    @Test func bubble_401IsSignatureNotMembership() {
        let m = CheffyViewModel.bubble(for: .notSignedIn("Authentication required"), id: 1)
        #expect(m.kind == .error && m.content == Cheffy.signatureRejectedMessage)
    }

    @Test func bubble_rateLimitedSurfacesRetryAfter() {
        let m = CheffyViewModel.bubble(for: .rateLimited(retryAfter: 1800), id: 1)
        #expect(m.content.hasPrefix(Cheffy.rateLimitedMessage))
        #expect(m.content.contains("30 minutes"))
        #expect(CheffyViewModel.bubble(for: .rateLimited(retryAfter: nil), id: 1).content == Cheffy.rateLimitedMessage)
    }

    @Test func bubble_timeoutAndTransportAreDistinct() {
        let t = CheffyViewModel.bubble(for: .transport(ZapCookingApi.timedOutTransportMessage), id: 1)
        #expect(t.content == Cheffy.timedOutMessage)
        let n = CheffyViewModel.bubble(for: .transport("The Internet connection appears to be offline."), id: 1)
        #expect(n.content == Cheffy.networkErrorMessage)
        #expect(CheffyViewModel.bubble(for: .requestFailed(status: 500, body: nil), id: 1).content.contains("500"))
    }

    // MARK: - Membership gate mapping

    @Test func gate_onlyVerifiedOwnerInactiveIsNotMember() {
        #expect(CheffyViewModel.gate(for: MembershipStatus(found: true, isActive: false, owner: true)) == .notMember)
        #expect(CheffyViewModel.gate(for: MembershipStatus(found: false, isActive: false, owner: true)) == .notMember)
        #expect(CheffyViewModel.gate(for: MembershipStatus(found: true, isActive: true, owner: true)) == .open)
        // Degraded (no `owner`) answer is not a verified denial.
        #expect(CheffyViewModel.gate(for: MembershipStatus(found: true, isActive: false, owner: false)) == .open)
    }

    @Test func gate_readFailureLeavesComposerOpen_watchOnlyIsGated() async {
        let failing = CheffyViewModel(readMembership: { _ in throw ZapCookingApiError.transport("offline") })
        #expect(!failing.gateResolved)
        await failing.checkGate(keypair: Keypair(privkey: String(repeating: "1", count: 64), pubkey: String(repeating: "2", count: 64)))
        #expect(failing.gate == .open && failing.gateResolved)

        let denied = CheffyViewModel(readMembership: { _ in MembershipStatus(found: true, isActive: false, owner: true) })
        await denied.checkGate(keypair: Keypair(privkey: String(repeating: "1", count: 64), pubkey: String(repeating: "3", count: 64)))
        #expect(denied.gate == .notMember)
    }

    // MARK: - Stateless history

    private func msg(_ id: Int, _ role: CheffyViewModel.Role, _ kind: CheffyViewModel.Kind, _ content: String) -> CheffyViewModel.Message {
        CheffyViewModel.Message(id: id, role: role, content: content, kind: kind)
    }

    @Test func history_keepsResolvedTurnsOnly_andCaps() {
        var thread: [CheffyViewModel.Message] = [
            msg(1, .user, .text, "a"),
            msg(2, .cheffy, .recipe, "# R\n## Ingredients\n- x\n## Directions\n1. y"),
            msg(3, .cheffy, .pending, ""),
            msg(4, .cheffy, .error, "boom"),
            msg(5, .cheffy, .gated, Cheffy.membersOnlyMessage),
            msg(6, .user, .text, "   "),
        ]
        let history = CheffyViewModel.history(from: thread, excludeTrailingUser: false)
        #expect(history.map(\.role) == ["user", "assistant"])
        #expect(history[1].content.hasPrefix("# R"))

        // Retry drops the trailing user turn (it is re-sent as the prompt).
        thread.append(msg(7, .user, .text, "again"))
        let retry = CheffyViewModel.history(from: thread, excludeTrailingUser: true)
        #expect(retry.map(\.content) == ["a", thread[1].content])

        // Cap: last 12 resolved turns.
        var long: [CheffyViewModel.Message] = []
        for i in 0..<30 {
            long.append(msg(i, i % 2 == 0 ? .user : .cheffy, .text, "t\(i)"))
        }
        let capped = CheffyViewModel.history(from: long, excludeTrailingUser: false)
        #expect(capped.count == Cheffy.maxHistoryTurns)
        #expect(capped.first?.content == "t18" && capped.last?.content == "t29")
    }

    @Test func send_addsUserTurnAndPendingBubble_thenResolves() async throws {
        let vm = CheffyViewModel(
            sendTurn: { request, _ in
                #expect(request.mode == .chat)
                #expect(request.messages.isEmpty)
                return "Use a little less — yogurt is tangier."
            },
            readMembership: { _ in MembershipStatus(found: true, isActive: true, owner: true) }
        )
        let keypair = Keypair(privkey: String(repeating: "1", count: 64), pubkey: String(repeating: "4", count: 64))
        await vm.checkGate(keypair: keypair)
        vm.send("  Can I substitute yogurt for sour cream?  ", mode: .chat, keypair: keypair)
        #expect(vm.loading)
        #expect(vm.thread.count == 2)
        #expect(vm.thread[0].role == .user && vm.thread[0].content == "Can I substitute yogurt for sour cream?")
        #expect(vm.thread[1].kind == .pending && vm.thread[1].expression == .thinking)
        #expect(Cheffy.thinkingLines.contains(vm.thread[1].statusLine ?? ""))

        for _ in 0..<50 where vm.loading { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!vm.loading)
        #expect(vm.thread[1].kind == .text && vm.thread[1].content.hasPrefix("Use a little less"))
    }

    /// Retry drops only the trailing error bubble and re-sends the last turn
    /// with the earlier thread as history; an older error stays in the
    /// scrollback.
    @Test func retry_dropsOnlyTheTrailingError_andResendsTheLastTurn() async throws {
        var calls = 0
        let vm = CheffyViewModel(
            sendTurn: { request, _ in
                calls += 1
                if calls <= 2 { throw ZapCookingApiError.transport("offline") }
                #expect(request.prompt == "b")
                #expect(request.messages == [CheffyMessage(role: "user", content: "a")])
                return "answer to b"
            },
            readMembership: { _ in MembershipStatus(found: true, isActive: true, owner: true) }
        )
        let keypair = Keypair(privkey: String(repeating: "1", count: 64), pubkey: String(repeating: "4", count: 64))
        await vm.checkGate(keypair: keypair)

        vm.send("a", mode: .chat, keypair: keypair)
        for _ in 0..<50 where vm.loading { try await Task.sleep(for: .milliseconds(10)) }
        vm.send("b", mode: .chat, keypair: keypair)
        for _ in 0..<50 where vm.loading { try await Task.sleep(for: .milliseconds(10)) }
        #expect(vm.thread.map(\.kind) == [.text, .error, .text, .error])

        vm.retry(keypair: keypair)
        #expect(vm.thread.count == 4)
        #expect(vm.thread[1].kind == .error, "the earlier error stays as scrollback context")
        #expect(vm.thread[3].kind == .pending)
        for _ in 0..<50 where vm.loading { try await Task.sleep(for: .milliseconds(10)) }
        #expect(vm.thread.map(\.kind) == [.text, .error, .text, .text])
        #expect(vm.thread[3].content == "answer to b")
    }

    @Test func send_hungryShowsSurpriseLabel_recipeReplyGetsRecipeKind() async throws {
        let vm = CheffyViewModel(
            sendTurn: { request, _ in
                #expect(request.mode == .hungry && request.prompt.isEmpty)
                return Self.fullRecipe
            },
            readMembership: { _ in MembershipStatus(found: true, isActive: true, owner: true) }
        )
        let keypair = Keypair(privkey: String(repeating: "1", count: 64), pubkey: String(repeating: "5", count: 64))
        await vm.checkGate(keypair: keypair)
        vm.send("", mode: .hungry, keypair: keypair)
        #expect(vm.thread[0].content == Cheffy.surpriseMeLabel)
        #expect(vm.thread[1].expression == .cooking)
        for _ in 0..<50 where vm.loading { try await Task.sleep(for: .milliseconds(10)) }
        #expect(vm.thread[1].kind == .recipe && vm.thread[1].expression == .happy)
    }

    @Test func send_isRefusedWhenGated() async {
        let vm = CheffyViewModel(
            sendTurn: { _, _ in Issue.record("must not send when gated"); return "" },
            readMembership: { _ in MembershipStatus(found: true, isActive: false, owner: true) }
        )
        let keypair = Keypair(privkey: String(repeating: "1", count: 64), pubkey: String(repeating: "6", count: 64))
        await vm.checkGate(keypair: keypair)
        vm.send("hello", mode: .chat, keypair: keypair)
        #expect(vm.thread.isEmpty && !vm.loading)
    }

    // MARK: - Save hand-off: a Cheffy recipe prefills the existing compose form

    @Test func recipeReply_prefillsRecipeCompose() {
        let store = RecipeComposeViewModel()
        store.prefillFromMarkdown(Self.fullRecipe)
        #expect(store.title == "Garlic Butter Pasta")
        #expect(store.ingredients.map(\.text) == ["200 g spaghetti", "3 cloves garlic, sliced", "3 tbsp butter"])
        #expect(store.directions.count == 3)
        #expect(store.directions[0].text == "Boil the pasta.")
    }

    // MARK: - Kill switch

    @Test func killSwitch_offHidesEntry_defaultIsOn() {
        #expect(CheffyGate.entryVisible(flagEnabled: false) == false)
        #expect(CheffyGate.entryVisible(flagEnabled: true) == true)
        #expect(FeatureFlags.cheffyEnabled)
    }

    // MARK: - Icon geometry

    @Test func svgPath_parsesTheWebSubset() {
        let square = SvgPath.parse("M0 0 L10 0 L10 10 L0 10 Z")
        #expect(square.boundingRect == CGRect(x: 0, y: 0, width: 10, height: 10))
        let curve = SvgPath.parse("M22.6 40 Q25.6 36.4 28.6 40")
        #expect(!curve.isEmpty)
        #expect(abs(curve.boundingRect.minX - 22.6) < 0.01 && abs(curve.boundingRect.maxX - 28.6) < 0.01)
        // Negative / decimal numbers and implicit lineto after M.
        let tri = SvgPath.parse("M-1.5 2 4 2 4 -3Z")
        #expect(abs(tri.boundingRect.minX + 1.5) < 0.01 && abs(tri.boundingRect.minY + 3) < 0.01)
    }

    @Test func iconGeometry_everyExpressionHasFaceMouthBrow() {
        #expect(!CheffyIconGeometry.face.isEmpty && !CheffyIconGeometry.band.isEmpty && !CheffyIconGeometry.zap.isEmpty)
        for expression in Cheffy.Expression.allCases {
            let g = CheffyIconGeometry.geometry(for: expression)
            #expect(!g.mouth.isEmpty && !g.brow.isEmpty, "\(expression)")
        }
        #expect(CheffyIconGeometry.geometry(for: .excited).mouthFilled)
        #expect(CheffyIconGeometry.geometry(for: .happy).eyeStyle == .happy)
    }
}
