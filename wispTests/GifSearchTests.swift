import Testing
import Foundation
@testable import wisp

// Ported from the web composer's gifSearch suite (itself ported from
// Sidecar, the reference implementation of the gifs.nostr.build picker).
// What matters is what a bad answer must not do: put a non-https link or an
// unknown format into a published note, or ask for an offset the API rejects.

struct GifSearchTests {
    // MARK: - Fixtures

    private func preview(animated: Any?, still: Any?) -> [String: Any] {
        ["width": 240, "height": 135, "animated": animated, "still": still]
    }

    private func item(overrides: [String: Any?] = [:]) -> [String: Any?] {
        var base: [String: Any?] = [
            "id": "aa.gif",
            "url": "https://image.nostr.build/aa.gif",
            "width": 480,
            "height": 270,
            "bytes": 123_456,
            "format": "gif",
            "title": " Good morning ",
            "previews": [
                "small": preview(animated: nil, still: "https://p/aa-s.png"),
                "medium": preview(animated: nil, still: "https://p/aa-m.png"),
                "w240": preview(animated: "https://p/aa-240.webp", still: "https://p/aa-240.png"),
            ] as [String: Any],
        ]
        for (key, value) in overrides { base[key] = value }
        return base
    }

    // MARK: - URLs

    @Test func searchURLAsksForSafeResultsOnePageAtATime() {
        let url = GifSearch.searchURL(query: "  good morning  ", offset: 24)!
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        #expect(components.scheme == "https")
        #expect(components.host == "gifs.nostr.build")
        #expect(components.path == "/api/v1/search")
        let params = Dictionary(uniqueKeysWithValues: components.queryItems!.map { ($0.name, $0.value ?? "") })
        #expect(params["q"] == "good morning")
        #expect(params["offset"] == "24")
        #expect(params["limit"] == String(GifSearch.pageSize))
        #expect(params["safe"] == "1")
    }

    @Test func searchURLCapsTheQueryAt500Characters() {
        let url = GifSearch.searchURL(query: String(repeating: "x", count: 900), offset: 0)!
        let q = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            .queryItems!.first { $0.name == "q" }!.value!
        #expect(q.count == 500)
    }

    @Test func suggestURLPointsAtTheSuggestEndpoint() {
        let url = GifSearch.suggestURL(query: "gm")!
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        #expect(components.path == "/api/v1/suggest")
        let params = Dictionary(uniqueKeysWithValues: components.queryItems!.map { ($0.name, $0.value ?? "") })
        #expect(params["limit"] == "6")
        #expect(params["safe"] == "1")
        #expect(params["offset"] == nil)
    }

    // MARK: - gif(fromItem:)

    @Test func gifCarriesItsLinkItsSizeAndTheAnimatedW240Preview() {
        let gif = GifSearch.gif(fromItem: item())
        #expect(gif?.url == "https://image.nostr.build/aa.gif")
        #expect(gif?.preview == "https://p/aa-240.webp")
        #expect(gif?.width == 480)
        #expect(gif?.height == 270)
        #expect(gif?.title == "Good morning")
    }

    @Test func gifFallsBackToTheFirstFrameWhenTooBigToAnimate() {
        let still = GifSearch.gif(fromItem: item(overrides: [
            "previews": ["w240": preview(animated: nil, still: "https://p/bb.png")] as [String: Any],
        ]))
        #expect(still?.preview == "https://p/bb.png")
    }

    @Test func gifFallsBackToTheMediumPreviewWhenThereIsNoW240() {
        let medium = GifSearch.gif(fromItem: item(overrides: [
            "previews": ["medium": preview(animated: nil, still: "https://p/m.png")] as [String: Any],
        ]))
        #expect(medium?.preview == "https://p/m.png")
    }

    @Test func gifRejectsAnythingThatCannotGoIntoANoteAsItIs() {
        let bad: [Any?] = [
            item(overrides: ["url": "http://image.nostr.build/aa.gif"]),
            item(overrides: ["url": "javascript:alert(1)"]),
            item(overrides: ["url": nil]),
            item(overrides: ["format": "mp4"]),
            item(overrides: ["width": 0]),
            item(overrides: ["height": "tall"]),
            item(overrides: ["previews": nil]),
            item(overrides: ["previews": ["w240": preview(animated: "http://p/x.webp", still: nil)] as [String: Any]]),
            nil,
            "aa.gif",
        ]
        for entry in bad {
            #expect(GifSearch.gif(fromItem: entry) == nil)
        }
    }

    // MARK: - parsePage

    @Test func parsePageDropsWhatItCannotShowAndSaysWhereTheNextOneStarts() {
        let page = GifSearch.parsePage([
            "count": 3, "offset": 0,
            "items": [item(), item(overrides: ["format": "mp4"])],
        ] as [String: Any])
        #expect(page.gifs.count == 1)
        // The offset counts every item the API sent, shown or not.
        #expect(page.next == 2)
        let tail = GifSearch.parsePage(["count": 3, "offset": 2, "items": [item()]] as [String: Any])
        #expect(tail.next == nil)
    }

    @Test func parsePageStopsPagingAtTheListAndAtTheLastOffsetTheAPIAccepts() {
        let full = GifSearch.parsePage([
            "count": 200, "offset": 192, "items": Array(repeating: item(), count: 8),
        ] as [String: Any])
        #expect(full.next == nil)

        let next192 = GifSearch.parsePage([
            "count": 500, "offset": 168, "items": Array(repeating: item(), count: 24),
        ] as [String: Any])
        #expect(next192.next == 192)

        let pastCeiling = GifSearch.parsePage([
            "count": 500, "offset": 192, "items": Array(repeating: item(), count: 24),
        ] as [String: Any])
        #expect(pastCeiling.next == nil)

        // An empty page ends the list whatever count claims.
        let empty = GifSearch.parsePage(["count": 50, "offset": 0, "items": []] as [String: Any])
        #expect(empty.next == nil)
    }

    @Test func parsePageAnswersJunkWithAnEmptyPage() {
        #expect(GifSearch.parsePage(nil).gifs.isEmpty)
        #expect(GifSearch.parsePage(nil).next == nil)
        #expect(GifSearch.parsePage(["items": "nope"] as [String: Any]).gifs.isEmpty)
        #expect(GifSearch.parsePage(["items": "nope"] as [String: Any]).next == nil)
    }

    // MARK: - Suggestions

    @Test func suggestionsAreTrimmedDedupedAndCapped() {
        let body: [String: Any] = [
            "terms": [
                ["term": " gm "], ["term": "gm"], ["term": ""],
                ["nope": 1], Optional<Any>.none,
                ["term": "gn"], ["term": "good"], ["term": "great"],
                ["term": "gg"], ["term": "go"], ["term": "gl"],
            ] as [Any],
        ]
        #expect(GifSearch.parseSuggestions(body) == ["gm", "gn", "good", "great", "gg", "go"])
        #expect(GifSearch.parseSuggestions([String: Any]()).isEmpty)
    }

    // MARK: - Error messages

    @Test func aRefusedKeyOrADownServiceIsUnavailableNotRetryable() {
        #expect(GifSearch.errorMessage(forStatus: 403) == "GIF search isn’t available right now.")
        #expect(GifSearch.errorMessage(forStatus: 401) == "GIF search isn’t available right now.")
        #expect(GifSearch.errorMessage(forStatus: 503) == "GIF search isn’t available right now.")
    }

    @Test func theRateLimitAsksForPatience() {
        #expect(GifSearch.errorMessage(forStatus: 429) == "Too many searches. Try again in a minute.")
    }

    @Test func everythingElseBlamesTheConnection() {
        #expect(GifSearch.errorMessage(forStatus: 500).hasPrefix("Couldn’t load GIFs"))
        #expect(GifSearch.errorMessage(forStatus: 0).hasPrefix("Couldn’t load GIFs"))
    }

    // MARK: - Topics

    /// gm leads 04:00–17:59 local; gn takes the evening and overnight.
    /// Built and read in one fixed timezone so the suite passes in any
    /// developer's locale.
    private var fixedCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }()

    private func at(hour: Int) -> Date {
        fixedCalendar.date(from: DateComponents(year: 2026, month: 10, day: 2, hour: hour, minute: 30))!
    }

    @Test func topicsOpenOnGmThroughTheDay() {
        #expect(GifSearch.topicsFor(now: at(hour: 4), calendar: fixedCalendar).first == "gm")
        #expect(GifSearch.topicsFor(now: at(hour: 9), calendar: fixedCalendar).first == "gm")
        #expect(GifSearch.topicsFor(now: at(hour: 17), calendar: fixedCalendar).first == "gm")
    }

    @Test func topicsOpenOnGnInTheEveningAndOvernight() {
        #expect(GifSearch.topicsFor(now: at(hour: 18), calendar: fixedCalendar).first == "gn")
        #expect(GifSearch.topicsFor(now: at(hour: 21), calendar: fixedCalendar).first == "gn")
        #expect(GifSearch.topicsFor(now: at(hour: 3), calendar: fixedCalendar).first == "gn")
    }

    @Test func topicsReorderWithoutDroppingOne() {
        #expect(GifSearch.topicsFor(now: at(hour: 21), calendar: fixedCalendar).count
                == GifSearch.topicsFor(now: at(hour: 9), calendar: fixedCalendar).count)
    }

    // MARK: - Paging

    @Test func loadsTheNextPageNearTheBottomNotWhileLoadingOrAfterTheLastPage() {
        // 0 + 600 >= 700 − 160
        #expect(GifSearch.shouldLoadMore(loading: false, nextOffset: 24, scrollTop: 0, clientHeight: 600, scrollHeight: 700))
        #expect(!GifSearch.shouldLoadMore(loading: false, nextOffset: 24, scrollTop: 0, clientHeight: 600, scrollHeight: 2000))
        #expect(!GifSearch.shouldLoadMore(loading: true, nextOffset: 24, scrollTop: 0, clientHeight: 600, scrollHeight: 700))
        #expect(!GifSearch.shouldLoadMore(loading: false, nextOffset: nil, scrollTop: 0, clientHeight: 600, scrollHeight: 700))
    }

    @Test func rechecksOnlyWhenTheCursorMovedForward() {
        #expect(GifSearch.pageAdvanced(0, 24))
        #expect(!GifSearch.pageAdvanced(24, 24))
        #expect(!GifSearch.pageAdvanced(48, 24))
        #expect(!GifSearch.pageAdvanced(176, nil))
    }
}
