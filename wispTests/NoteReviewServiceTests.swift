import Foundation
import Testing
@testable import wisp

/// `NoteReviewService` — request shape and the response → result mapping
/// against the server's real shapes (frontend
/// `src/routes/api/zappy/note-review/+server.ts` at `eb99f009`). Never
/// opens a socket; the opt-in network checks live in `NoteReviewLiveTests`.
@MainActor
struct NoteReviewServiceTests {

    private func body(_ json: String) -> Data { Data(json.utf8) }

    // MARK: Request

    @Test func request_capsNoteTextBeforeSigning_andOmitsBlanks() {
        let long = String(repeating: "x", count: 1500)
        let capped = NoteReviewService.request(imageUrl: "https://a/b.jpg", mode: .recipe, noteText: "  \(long)  ", noteId: "ab")
        #expect(capped.noteText?.count == NoteReview.noteTextMaxChars)
        let blank = NoteReviewService.request(imageUrl: "https://a/b.jpg", mode: .comment, noteText: "  \n ", noteId: nil)
        #expect(blank.noteText == nil)
        #expect(blank.noteId == nil)
    }

    @Test func request_encodesTheWebShape_withNoIdentityField() throws {
        let request = NoteReviewService.request(imageUrl: "https://a/b.jpg", mode: .comment, noteText: "hi", noteId: "ab")
        let json = ZapCookingApi.encodeJSON(request)
        let obj = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(obj["imageUrl"] as? String == "https://a/b.jpg")
        #expect(obj["mode"] as? String == "comment")
        #expect(obj["noteText"] as? String == "hi")
        #expect(obj["noteId"] as? String == "ab")
        #expect(obj["pubkey"] == nil)
        // Optionals are omitted, not null (web `noteText?` parity).
        let bare = ZapCookingApi.encodeJSON(NoteReviewService.request(imageUrl: "https://a/b.jpg", mode: .recipe, noteText: nil, noteId: nil))
        #expect(!bare.contains("noteText"))
        #expect(!bare.contains("noteId"))
    }

    // MARK: Response mapping

    @Test func map_200_isSuccess_withTrimmedOutput() {
        let r = NoteReviewService.map(status: 200, body: body(#"{"ok":true,"output":"  Lovely crust!\n","mode":"comment"}"#))
        #expect(r == .success(output: "Lovely crust!"))
    }

    @Test func map_200_ignoresCreditsRemaining() {
        let r = NoteReviewService.map(status: 200, body: body(#"{"ok":true,"output":"x","mode":"comment","creditsRemaining":3}"#))
        #expect(r == .success(output: "x"))
    }

    @Test func map_okTrueButEmptyOutput_isError() {
        let r = NoteReviewService.map(status: 200, body: body(#"{"ok":true,"output":"  "}"#))
        #expect(r == .error(message: "Cheffy went quiet for a second. Please try again."))
    }

    @Test func map_403NotMember() {
        let r = NoteReviewService.map(status: 403, body: body(#"{"ok":false,"code":"NOT_MEMBER","error":"Cheffy photo review is available to Cook+ members — or 21 sats a draft."}"#))
        #expect(r == .notMember)
    }

    @Test func map_503MembershipUnavailable_isNotTheMembersGate() {
        let r = NoteReviewService.map(status: 503, body: body(#"{"ok":false,"code":"MEMBERSHIP_UNAVAILABLE","error":"Cheffy can't check your membership right now. Please try again shortly."}"#))
        #expect(r == .membershipUnavailable)
        #expect(r != .notMember)
    }

    @Test func map_bare403WithoutCode_isARetryableError_neverTheMembersGate() {
        // Chat-endpoint precedent: a code-less 403 may be a pantry outage.
        let r = NoteReviewService.map(status: 403, body: body(#"{"ok":false,"error":"Forbidden"}"#))
        #expect(r == .error(message: "Forbidden"))
    }

    @Test func map_429RateLimited_carriesRetryAfter() {
        let r = NoteReviewService.map(status: 429, body: body(#"{"ok":false,"code":"RATE_LIMITED","error":"breather","retryAfter":1800}"#))
        #expect(r == .rateLimited(retryAfter: 1800))
    }

    @Test func map_notFoodAndImageUnreadable_collapseToDeadEnd_withoutTheServerLine() {
        let notFood = NoteReviewService.map(status: 422, body: body(#"{"ok":false,"code":"NOT_FOOD","error":"That's a cat."}"#))
        let unreadable = NoteReviewService.map(status: 422, body: body(#"{"ok":false,"code":"IMAGE_UNREADABLE","error":"broken"}"#))
        #expect(notFood == .deadEnd)
        #expect(unreadable == .deadEnd)
    }

    @Test func map_statusCodeFallback_whenBodyIsUnparseable() {
        #expect(NoteReviewService.map(status: 403, body: body("<html>")) == .error(message: NoteReview.genericErrorLine))
        #expect(NoteReviewService.map(status: 503, body: body("<html>")) == .membershipUnavailable)
        #expect(NoteReviewService.map(status: 429, body: body("<html>")) == .rateLimited(retryAfter: nil))
        #expect(NoteReviewService.map(status: 422, body: body("<html>")) == .deadEnd)
    }

    @Test func map_401_isSignFailed() {
        #expect(NoteReviewService.map(status: 401, body: body(#"{"ok":false,"error":"Authentication required"}"#)) == .signFailed)
    }

    @Test func map_500_isError_withTheServerLine() {
        let r = NoteReviewService.map(status: 500, body: body(#"{"ok":false,"error":"Cheffy could not finish that one. Please try again."}"#))
        #expect(r == .error(message: "Cheffy could not finish that one. Please try again."))
    }

    @Test func map_400_isError_withTheServerLine() {
        let r = NoteReviewService.map(status: 400, body: body(#"{"ok":false,"error":"imageUrl must be https"}"#))
        #expect(r == .error(message: "imageUrl must be https"))
    }

    // MARK: Thrown errors

    @Test func map_transportTimeout_andNetwork() {
        #expect(NoteReviewService.map(error: ZapCookingApiError.transport(ZapCookingApi.timedOutTransportMessage)) == .error(message: Cheffy.timedOutMessage))
        #expect(NoteReviewService.map(error: ZapCookingApiError.transport("offline")) == .error(message: Cheffy.networkErrorMessage))
    }

    @Test func map_notSignedIn_isSignFailed() {
        #expect(NoteReviewService.map(error: ZapCookingApiError.notSignedIn("watch-only")) == .signFailed)
    }

    @Test func map_membersOnly_isTheOnlyPathIntoTheGate() {
        #expect(NoteReviewService.map(error: ZapCookingApiError.membersOnly) == .notMember)
        #expect(NoteReviewService.map(error: ZapCookingApiError.apiRejected(code: nil, message: nil)) == .error(message: NoteReview.genericErrorLine))
        #expect(NoteReviewService.map(error: ZapCookingApiError.apiRejected(code: "MEMBERSHIP_UNAVAILABLE", message: "x")) == .membershipUnavailable)
        #expect(NoteReviewService.map(error: ZapCookingApiError.apiRejected(code: "SOMETHING_NEW", message: "new line")) == .error(message: "new line"))
    }

    @Test func serviceUsesTheComputeClient() {
        #expect(NoteReviewService().client === HttpClientFactory.computeClient)
        #expect(NoteReviewService.path == "api/zappy/note-review")
    }
}
