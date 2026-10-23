import Testing
import Foundation
@testable import wisp

// Locks in the GifPickerModel state machine the PR review flagged: the
// loading flag outliving a cancelled search, pagination reading the text
// field instead of the query that owns the grid, an auto-advanced page
// losing its loading state to the apply that started it, and tail
// visibility describing a grid the last page already grew past.

@MainActor
private func waitUntil(_ description: String, _ condition: @MainActor () -> Bool) async {
    for _ in 0..<200 {
        if condition() { return }
        try? await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("Timed out waiting for \(description)")
}

private func gif(_ i: Int) -> Gif {
    Gif(url: "https://image.nostr.build/\(i).gif",
        preview: "https://image.nostr.build/w240/\(i).webp",
        width: 240, height: 135, title: "g\(i)", format: "gif")
}

private func pageOf24(startingAt start: Int, next: Int?) -> GifPage {
    GifPage(gifs: (start..<(start + 24)).map(gif), next: next)
}

/// Scripts search responses by offset, records every request, and can hold
/// chosen offsets in flight so tests can observe state mid-request. Locking
/// lives in synchronous helpers — `NSLock` is unavailable from async
/// contexts.
private final class ScriptedGifSearchClient: GifSearchClient, @unchecked Sendable {
    private let lock = NSLock()
    private var pages: [Int: GifPage] = [:]
    private var heldOffsets: Set<Int> = []
    private var gates: [Int: [CheckedContinuation<GifPage, Never>]] = [:]
    private var recorded: [(query: String, offset: Int)] = []

    var requests: [(query: String, offset: Int)] {
        lock.lock(); defer { lock.unlock() }
        return recorded
    }

    func search(query: String, offset: Int) async throws -> GifPage {
        if recordRequest(query: query, offset: offset) {
            return await withCheckedContinuation { continuation in
                park(continuation, at: offset)
            }
        }
        return page(at: offset)
    }

    func suggest(query: String) async throws -> [String] { [] }

    func page(_ page: GifPage, at offset: Int) {
        lock.lock(); pages[offset] = page; lock.unlock()
    }

    /// Park requests for this offset until `release`, so a test can watch
    /// the model's state while the page is in flight.
    func hold(_ offset: Int) {
        lock.lock(); heldOffsets.insert(offset); lock.unlock()
    }

    func release(_ offset: Int) {
        lock.lock()
        heldOffsets.remove(offset)
        let waiting = gates.removeValue(forKey: offset) ?? []
        let page = pages[offset] ?? GifPage(gifs: [], next: nil)
        lock.unlock()
        for continuation in waiting { continuation.resume(returning: page) }
    }

    /// Records the request and reports whether it must be held.
    private func recordRequest(query: String, offset: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        recorded.append((query, offset))
        return heldOffsets.contains(offset)
    }

    private func park(_ continuation: CheckedContinuation<GifPage, Never>, at offset: Int) {
        lock.lock()
        gates[offset, default: []].append(continuation)
        lock.unlock()
    }

    private func page(at offset: Int) -> GifPage {
        lock.lock(); defer { lock.unlock() }
        return pages[offset] ?? GifPage(gifs: [], next: nil)
    }
}

/// A search that never answers, for watching cancel-time state.
private struct UnansweringGifSearchClient: GifSearchClient {
    func search(query: String, offset: Int) async throws -> GifPage {
        try await Task.sleep(for: .seconds(60))
        return GifPage(gifs: [], next: nil)
    }
    func suggest(query: String) async throws -> [String] { [] }
}

struct GifPickerModelTests {
    @Test @MainActor func clearingTheSearchEndsTheSpinnerEvenMidRequest() {
        let model = GifPickerModel(client: UnansweringGifSearchClient())
        model.searchNow("gm")
        #expect(model.loading)
        model.searchNow("")
        #expect(!model.loading)
        #expect(model.placedCount == 0)
    }

    @Test @MainActor func pagingAsksTheQueryThatOwnsTheGridNotTheTextBeingTyped() async {
        let client = ScriptedGifSearchClient()
        client.page(pageOf24(startingAt: 0, next: 24), at: 0)
        client.page(pageOf24(startingAt: 24, next: 48), at: 24)
        let model = GifPickerModel(client: client)
        model.ensureColumnCount(forWidth: 400)
        model.searchNow("gm")
        await waitUntil("first page placed") { model.placedCount == 24 && !model.loading }
        model.query = "coffee" // typed, debounce pending — the grid is still "gm"'s
        model.cellAppeared(at: model.placedCount - 1)
        await waitUntil("second page requested") { client.requests.count == 2 }
        #expect(client.requests.map(\.query) == ["gm", "gm"])
        #expect(client.requests.map(\.offset) == [0, 24])
    }

    @Test @MainActor func anAutoAdvancedPageKeepsLoadingAndIgnoresStrayTailAppearances() async {
        let client = ScriptedGifSearchClient()
        client.page(pageOf24(startingAt: 0, next: 24), at: 0)
        // Same URLs as page one: grows nothing, so the visible tail advances on.
        client.page(pageOf24(startingAt: 0, next: 48), at: 24)
        client.page(pageOf24(startingAt: 48, next: nil), at: 48)
        client.hold(48)
        let model = GifPickerModel(client: client)
        model.ensureColumnCount(forWidth: 400)
        model.searchNow("gm")
        await waitUntil("first page placed") { model.placedCount == 24 && !model.loading }
        model.cellAppeared(at: model.placedCount - 1) // tail on screen → page two
        await waitUntil("duplicate page advanced to the held third") {
            client.requests.count == 3 && model.loading
        }
        // While the third page is in flight a stray tail re-appearance must
        // not duplicate the request — which the clobbered loading flag allowed.
        model.cellAppeared(at: model.placedCount - 1)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(client.requests.count == 3)
        #expect(model.loading)
        client.release(48)
        await waitUntil("held page applied") { !model.loading }
        // 24 through the duplicate page, 48 once the released page places
        // its fresh items.
        #expect(model.placedCount == 48)
    }

    @Test @MainActor func aFirstPageThatPlacesNothingStillFetchesTheNext() async {
        let client = ScriptedGifSearchClient()
        client.page(GifPage(gifs: [], next: 24), at: 0) // every item rejected upstream
        client.page(pageOf24(startingAt: 0, next: nil), at: 24)
        let model = GifPickerModel(client: client)
        model.ensureColumnCount(forWidth: 400)
        model.searchNow("gm")
        await waitUntil("rejected page auto-advanced to a real one") {
            model.placedCount == 24 && !model.loading
        }
        #expect(client.requests.map(\.offset) == [0, 24])
    }

    @Test @MainActor func aPageThatGrowsTheGridWaitsForItsOwnTailToAppear() async {
        let client = ScriptedGifSearchClient()
        client.page(pageOf24(startingAt: 0, next: 24), at: 0)
        client.page(pageOf24(startingAt: 24, next: 48), at: 24)
        client.page(pageOf24(startingAt: 48, next: nil), at: 48)
        let model = GifPickerModel(client: client)
        model.ensureColumnCount(forWidth: 400)
        model.searchNow("gm")
        await waitUntil("first page placed") { model.placedCount == 24 && !model.loading }
        model.cellAppeared(at: model.placedCount - 1) // tail visible → page two
        await waitUntil("second page placed") { model.placedCount == 48 && !model.loading }
        try? await Task.sleep(for: .milliseconds(100))
        #expect(client.requests.count == 2) // no chain-load nobody saw the tail of
        model.cellAppeared(at: model.placedCount - 1) // the new tail appears
        await waitUntil("third page placed") { model.placedCount == 72 && !model.loading }
        #expect(client.requests.map(\.offset) == [0, 24, 48])
    }
}
