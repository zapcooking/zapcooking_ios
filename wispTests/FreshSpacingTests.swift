import Testing
@testable import wisp

/// Port of web `src/lib/freshFeed/spacing.test.ts`, one case for one.
@MainActor
struct FreshSpacingTests {
    nonisolated struct Post: FreshSpaceable, Equatable {
        let id: String
        let author: String
        var spacingId: String { id }
        var spacingAuthor: String { author }
    }

    static func authors(_ list: [Post]) -> String { list.map(\.author).joined() }
    static func ids(_ list: [Post]) -> [String] { list.map(\.id) }
    static func parse(_ specs: [String]) -> [Post] {
        specs.map { s in
            let parts = s.split(separator: ":").map(String.init)
            return p(parts[0], parts[1])
        }
    }

    // MARK: spaceAuthors

    @Test func spreadsARunOfOneAuthorThroughThePage() {
        let page = [p("1", "A"), p("2", "A"), p("3", "A"), p("4", "B"), p("5", "C"), p("6", "D"), p("7", "E")]
        #expect(Self.authors(FreshSpacing.spaceAuthors(before: [], incoming: page)) == "ABCADEA")
    }

    @Test func keepsEachAuthorsPostsInTheirOrder_deferralOnly() {
        let page = [p("1", "A"), p("2", "A"), p("3", "B"), p("4", "A"), p("5", "C"), p("6", "D")]
        let out = FreshSpacing.spaceAuthors(before: [], incoming: page)
        #expect(out.filter { $0.author == "A" }.map(\.id) == ["1", "2", "4"])
        #expect(Self.ids(out) == ["1", "3", "5", "2", "6", "4"])
    }

    @Test func respectsThePostsAlreadyOnScreen() {
        let before = [p("0", "X"), p("1", "A")]
        let out = FreshSpacing.spaceAuthors(before: before, incoming: [p("2", "A"), p("3", "B"), p("4", "C")])
        #expect(Self.authors(out) == "BCA")
    }

    @Test func keepsTheOrderWhenSpacingIsImpossible() {
        let page = [p("1", "A"), p("2", "A"), p("3", "A")]
        #expect(Self.ids(FreshSpacing.spaceAuthors(before: [], incoming: page)) == ["1", "2", "3"])
    }

    @Test func leavesAnAlreadySpacedPageUntouched() {
        let page = [p("1", "A"), p("2", "B"), p("3", "C"), p("4", "A")]
        #expect(FreshSpacing.spaceAuthors(before: [], incoming: page) == page)
    }

    @Test func keepsEveryPostExactlyOnce() {
        let pattern = Array("ABAAC")
        let page = (0..<30).map { p(String($0), String(pattern[$0 % 5])) }
        let out = FreshSpacing.spaceAuthors(before: [], incoming: page)
        #expect(Self.ids(out).sorted() == Self.ids(page).sorted())
    }

    // MARK: the first page, streamed (StreamSpacer)

    @Test func neverMovesOrReordersWhatIsAlreadyPlaced_whileStreamingOrAtEOSE() {
        var sp = FreshStreamSpacer<Post>()
        let stream = Self.parse(["a1:A", "a2:A", "a3:A", "b1:B", "a4:A", "c1:C", "a5:A", "a6:A", "b2:B", "d1:D"])
        var prev: [String] = []
        for post in stream {
            let now = Self.ids(sp.push(post))
            #expect(Array(now.prefix(prev.count)) == prev)
            prev = now
        }
        // The page's final list comes in the relay's order, not arrival order.
        let added = sp.finish([p("e1", "E")] + Array(stream.reversed()) + [p("a7", "A")])
        let final = Self.ids(sp.placed)
        #expect(Array(final.prefix(prev.count)) == prev)
        #expect(Self.ids(added) == Array(final.dropFirst(prev.count)))
        #expect(final.sorted() == (Self.ids(stream) + ["e1", "a7"]).sorted())
    }

    @Test func holdsAPostTooCloseToItsAuthor_andPlacesItWhenAnotherAuthorMakesRoom() {
        var sp = FreshStreamSpacer<Post>()
        sp.push(p("a1", "A"))
        #expect(Self.ids(sp.push(p("a2", "A"))) == ["a1"])
        #expect(Self.ids(sp.push(p("b1", "B"))) == ["a1", "b1"])
        #expect(Self.ids(sp.push(p("c1", "C"))) == ["a1", "b1", "c1", "a2"])
    }

    @Test func spacesAuthorsAsFarAsTheStreamAllows() {
        var sp = FreshStreamSpacer<Post>()
        let stream = Self.parse(["a1:A", "a2:A", "b1:B", "b2:B", "c1:C", "c2:C", "a3:A"])
        for post in stream { sp.push(post) }
        sp.finish(stream)
        let pks = sp.placed.map(\.author)
        for i in 1..<pks.count {
            for d in 1..<FreshSpacing.authorGap where i - d >= 0 {
                #expect(pks[i] != pks[i - d])
            }
        }
    }

    @Test func aPageAllFromOneCook_stillArrivesWholeInOrderAtTheEnd() {
        var sp = FreshStreamSpacer<Post>()
        for id in ["a1", "a2", "a3"] { sp.push(p(id, "A")) }
        #expect(Self.ids(sp.placed) == ["a1"])
        sp.finish([])
        #expect(Self.ids(sp.placed) == ["a1", "a2", "a3"])
    }

    @Test func eoseAddsOnlyWhatDidNotStream_aDuplicateIsIgnored() {
        var sp = FreshStreamSpacer<Post>()
        sp.push(p("a1", "A"))
        sp.push(p("a1", "A"))
        let added = sp.finish([p("a1", "A"), p("b1", "B")])
        #expect(Self.ids(added) == ["b1"])
        #expect(Self.ids(sp.placed) == ["a1", "b1"])
        #expect(sp.has("b1"))
    }

    // MARK: iOS-only

    @Test func nostrEventsSpaceByPubkey() {
        let e = { (id: String, pk: String) -> NostrEvent in
            NostrEvent(id: id, pubkey: pk, kind: 1, createdAt: 0, tags: [], content: "", sig: "")
        }
        let out = FreshSpacing.spaceAuthors(before: [], incoming: [e("1", "A"), e("2", "A"), e("3", "B"), e("4", "C")])
        #expect(out.map { $0.id } == ["1", "3", "4", "2"])
    }
}

private func p(_ id: String, _ author: String) -> FreshSpacingTests.Post {
    FreshSpacingTests.Post(id: id, author: author)
}
