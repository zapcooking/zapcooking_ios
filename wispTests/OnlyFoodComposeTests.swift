import Foundation
import SwiftUI
import Testing
@testable import wisp

/// The OnlyFood composer's suggestion pills, replacing C-H's `#foodstr`
/// prefill: nothing is added to a note unless the user taps; a pill toggles
/// the tag in the body; the §7.3 structural cap is enforced exactly as
/// `OnlyFoodFilter` counts it; publishing with no food tag asks first.
/// Hermetic.
@MainActor
struct OnlyFoodComposeTests {

    private func freshKeypair() -> Keypair {
        let priv = Schnorr.randomPrivkey()
        let pub = try! Schnorr.xonlyPubkey(privkey32: priv)
        return Keypair(privkey: Hex.encode(priv), pubkey: Hex.encode(pub))
    }

    private func autosaveKey(_ kp: Keypair) -> String { "compose_autosave_new_\(kp.pubkey)" }

    /// A fresh OnlyFood composer: no draft, the pills, no seed.
    private func onlyFoodComposer() -> ComposeViewModel {
        let kp = freshKeypair()
        UserDefaults.standard.removeObject(forKey: autosaveKey(kp))
        return ComposeViewModel(keypair: kp, suggestedHashtags: OnlyFoodCompose.suggestedTags)
    }

    private func kind1(content: String, tTags: [String]) -> NostrEvent {
        NostrEvent(
            id: "e1", pubkey: String(repeating: "a", count: 64), kind: 1, createdAt: 1,
            tags: tTags.map { ["t", $0] }, content: content,
            sig: String(repeating: "0", count: 128)
        )
    }

    /// `n` typed tags that are not in the food set, so the cap can be
    /// reached (and passed) from the keyboard: since #84 the cap (20) is
    /// above the pill count (8), so the pills alone can never fill it.
    private func nonFoodTags(_ n: Int) -> String {
        (0..<n).map { "#zc\($0)" }.joined(separator: " ")
    }

    // MARK: - The set

    /// #84: the same eight in the same order on web, iOS and Android.
    @Test func suggestedTags_matchTheCrossPlatformSetAndOrder() {
        #expect(OnlyFoodCompose.suggestedTags == [
            "foodstr", "coffee", "cooking", "breakfast", "dinner", "lunch", "cookstr", "food",
        ])
    }

    @Test func suggestedTags_allReachOnlyFood_noDuplicates_foodstrFirst() {
        let tags = OnlyFoodCompose.suggestedTags
        #expect(tags.first == OnlyFoodCompose.defaultTag)
        #expect(Set(tags).count == tags.count)
        for tag in tags {
            #expect(FoodHashtags.allSet.contains(tag), "\(tag) is not a food tag — a note with only it dead-ends")
            #expect(tag == tag.lowercased(), Comment(rawValue: tag))
        }
        // Proposed and deliberately absent: not in the food set.
        #expect(!tags.contains("gratitude"))
        #expect(!FoodHashtags.allSet.contains("gratitude"))
        // #84: the whole row fits under the cap, so tapping every pill never
        // makes a note the filter would hide.
        #expect(OnlyFoodCompose.maxTags == 20)
        #expect(tags.count <= OnlyFoodCompose.maxTags, "every pill must be tappable together")
    }

    // MARK: - No seed

    @Test func onlyFoodComposer_opensEmpty_nothingAutoAdded() {
        let vm = onlyFoodComposer()
        #expect(vm.content.isEmpty)
        #expect(vm.hashtags.isEmpty)
        #expect(vm.suggestedHashtags == OnlyFoodCompose.suggestedTags)
        #expect(!vm.canPublish)
        #expect(FeedTabRouting.composeSuggestions(for: .onlyFood) == OnlyFoodCompose.suggestedTags)
        for kind in [FeedKind.follows, .extendedNetwork, .relay(url: "wss://nos.lol")] {
            #expect(FeedTabRouting.composeSuggestions(for: kind).isEmpty, "\(kind)")
        }
    }

    @Test func generalComposer_hasNoPills_noConfirm() {
        let kp = freshKeypair()
        UserDefaults.standard.removeObject(forKey: autosaveKey(kp))
        let vm = ComposeViewModel(keypair: kp)
        #expect(vm.suggestedHashtags.isEmpty)
        vm.updateContent("just a thought")
        #expect(!vm.needsFoodTagConfirm)
    }

    // MARK: - Toggle

    @Test func pill_tapAppends_secondTapRemoves_bodyIsTruth() {
        let vm = onlyFoodComposer()
        vm.toggleSuggestedHashtag("foodstr")
        #expect(vm.content == "#foodstr")
        #expect(vm.hashtags == ["foodstr"])
        #expect(vm.isSuggestedHashtagSelected("foodstr"))
        #expect(vm.canPublish)

        vm.toggleSuggestedHashtag("foodstr")
        #expect(vm.content.isEmpty)
        #expect(vm.hashtags.isEmpty)
        #expect(!vm.isSuggestedHashtagSelected("foodstr"))
    }

    @Test func pill_afterProse_startsATagLine_thenJoinsIt() {
        let vm = onlyFoodComposer()
        vm.updateContent("ramen night ")
        vm.toggleSuggestedHashtag("foodstr")
        #expect(vm.content == "ramen night\n\n#foodstr")
        vm.toggleSuggestedHashtag("dinner")
        #expect(vm.content == "ramen night\n\n#foodstr #dinner")
        #expect(vm.hashtags == ["foodstr", "dinner"])
        // Removing the middle one closes the gap.
        vm.toggleSuggestedHashtag("foodstr")
        #expect(vm.content == "ramen night\n\n#dinner")
        vm.toggleSuggestedHashtag("dinner")
        #expect(vm.content == "ramen night")
    }

    /// A typed tag selects its pill; the pill then removes the typed token
    /// wherever it sits and tidies the space.
    @Test func typedTag_selectsPill_andPillRemovesIt() {
        let vm = onlyFoodComposer()
        vm.updateContent("Sunday #breakfast at home #Breakfast")
        #expect(vm.isSuggestedHashtagSelected("breakfast"))
        vm.toggleSuggestedHashtag("breakfast")
        #expect(vm.content == "Sunday at home")
        #expect(!vm.isSuggestedHashtagSelected("breakfast"))
        // A longer tag sharing the prefix is left alone.
        vm.updateContent("#breakfastclub #lunch")
        vm.toggleSuggestedHashtag("lunch")
        #expect(vm.content == "#breakfastclub")
    }

    // MARK: - The cap

    /// The whole row fits under the cap (#84), so the row alone never
    /// disables anything — taps every pill, then reaches the cap by typing.
    @Test func cap_countsLikeTheFilter_disablesFurtherPills_reenablesOnRemove() {
        let vm = onlyFoodComposer()
        let pills = OnlyFoodCompose.suggestedTags
        let cap = OnlyFoodCompose.maxTags
        for tag in pills { vm.toggleSuggestedHashtag(tag) }
        #expect(vm.hashtags.count == pills.count)
        #expect(!vm.suggestedTagsAtCap, "all eight pills together stay under the cap")
        #expect(!OnlyFoodFilter.isStructuralSpam(kind1(content: vm.content, tTags: vm.hashtags)))

        // Typed filler up to one short of the cap, then one pill lands on it.
        vm.updateContent(nonFoodTags(cap - 1))
        #expect(vm.suggestedTagCount == cap - 1)
        #expect(!vm.suggestedTagsAtCap)
        vm.toggleSuggestedHashtag(pills[0])
        #expect(vm.hashtags.count == cap)
        #expect(vm.suggestedTagCount == cap)
        #expect(vm.suggestedTagsAtCap)
        #expect(!vm.suggestedTagsOverCap)
        // The next pill is a no-op (the row disables it; this is the guard behind it).
        let next = pills[1]
        #expect(vm.toggleSuggestedHashtag(next) == false)
        #expect(vm.hashtags.count == cap)
        #expect(!vm.isSuggestedHashtagSelected(next))
        // What would be published passes the filter's own rule.
        #expect(!OnlyFoodFilter.isStructuralSpam(kind1(content: vm.content, tTags: vm.hashtags)))
        // Free a slot: the next pill becomes addable.
        vm.toggleSuggestedHashtag(pills[0])
        #expect(!vm.suggestedTagsAtCap)
        vm.toggleSuggestedHashtag(next)
        #expect(vm.isSuggestedHashtagSelected(next))
        #expect(vm.suggestedTagsAtCap)
    }

    /// Typing past the cap is flagged, not prevented — the pills can't push
    /// a note over, but the keyboard can, and a duplicate typed tag counts
    /// on the content side (`max(content #tags, t-tags)`).
    @Test func typedOverflow_isFlagged_andMatchesTheFilter() {
        let vm = onlyFoodComposer()
        let cap = OnlyFoodCompose.maxTags
        vm.updateContent(nonFoodTags(cap) + " #foodstr")
        #expect(vm.hashtags.count == cap + 1)
        #expect(vm.suggestedTagsOverCap)
        #expect(OnlyFoodFilter.isStructuralSpam(kind1(content: vm.content, tTags: vm.hashtags)))
        // A duplicate typed tag counts on the content side.
        vm.updateContent("#foodstr #foodstr " + nonFoodTags(cap - 1))
        #expect(vm.hashtags.count == cap)
        #expect(vm.suggestedTagCount == cap + 1)
        #expect(vm.suggestedTagsOverCap)
        #expect(OnlyFoodFilter.isStructuralSpam(kind1(content: vm.content, tTags: vm.hashtags)))
        // Exactly at the cap is fine — the 6–20 band is what #84 let back in.
        vm.updateContent(nonFoodTags(cap - 1) + " #foodstr")
        #expect(vm.suggestedTagsAtCap)
        #expect(!vm.suggestedTagsOverCap)
        #expect(!OnlyFoodFilter.isStructuralSpam(kind1(content: vm.content, tTags: vm.hashtags)))
    }

    // MARK: - The dead end

    @Test func publishConfirm_onlyWhenNoFoodTag_fromOnlyFood() {
        let vm = onlyFoodComposer()
        vm.updateContent("made a thing")
        #expect(vm.needsFoodTagConfirm)
        vm.updateContent("made a thing #nostr")
        #expect(vm.needsFoodTagConfirm, "a non-food tag does not reach OnlyFood")
        vm.toggleSuggestedHashtag("cooking")
        #expect(!vm.needsFoodTagConfirm)
        vm.toggleSuggestedHashtag("cooking")
        vm.updateContent("made a thing #sourdough #baking")
        #expect(!vm.needsFoodTagConfirm, "a typed food-set tag counts too")
    }

    /// The confirm's "Add #foodstr" is the pill toggle — a tap, and it
    /// leaves the note reachable and under the cap.
    @Test func confirmAddFoodstr_isTheToggle() {
        let vm = onlyFoodComposer()
        vm.updateContent("made a thing")
        vm.toggleSuggestedHashtag(OnlyFoodCompose.defaultTag)
        #expect(vm.content == "made a thing\n\n#foodstr")
        #expect(!vm.needsFoodTagConfirm)
        #expect(FoodHashtags.hasFoodTag(kind1(content: vm.content, tTags: vm.hashtags)))
    }

    /// At the cap with no food tag (twenty non-food tags typed) the one-tap
    /// fix cannot work: the toggle reports the no-op and leaves the body
    /// alone, so the composer must not publish on its behalf (the alert
    /// hides the button in that state).
    @Test func confirmAddFoodstr_atCapWithNoFoodTag_isRefused() {
        let vm = onlyFoodComposer()
        let cap = OnlyFoodCompose.maxTags
        vm.updateContent("a " + nonFoodTags(cap))
        #expect(vm.suggestedTagsAtCap)
        #expect(vm.needsFoodTagConfirm)
        let before = vm.content
        #expect(vm.toggleSuggestedHashtag(OnlyFoodCompose.defaultTag) == false)
        #expect(vm.content == before)
        #expect(vm.needsFoodTagConfirm)
        // Off the cap, the same tap works and returns true.
        vm.updateContent("a " + nonFoodTags(cap - 1))
        #expect(vm.toggleSuggestedHashtag(OnlyFoodCompose.defaultTag))
        #expect(!vm.needsFoodTagConfirm)
    }

    // MARK: - The row (rendered; PNGs via the git-ignored `wispTests/.zc_snapshot_dir`)

    /// The row in the three states the by-hand gate screenshots: no pill
    /// tapped, one tapped, at the cap (typed filler plus two pills, the
    /// other six dimmed). Measured: the selected pills are filled with the
    /// theme primary, the count reads as the filter counts.
    @Test func suggestionRow_renders_none_one_cap() throws {
        let vm = onlyFoodComposer()
        let cap = OnlyFoodCompose.maxTags
        let pills = OnlyFoodCompose.suggestedTags
        let states: [(String, Int, () -> Void)] = [
            ("none", 0, {}),
            ("one", 1, { vm.toggleSuggestedHashtag(pills[0]) }),
            ("cap", cap, {
                vm.updateContent(nonFoodTags(cap - 2))
                vm.toggleSuggestedHashtag(pills[0])
                vm.toggleSuggestedHashtag(pills[1])
            }),
        ]
        for (name, taps, arrange) in states {
            arrange()
            let renderer = ImageRenderer(content:
                HashtagSuggestionRow(viewModel: vm)
                    .frame(width: 390)
                    .background(Color.wispBackground)
            )
            renderer.scale = 2
            let image = try #require(renderer.uiImage)
            #expect(image.size.width >= 390, Comment(rawValue: name))
            #expect(vm.suggestedTagCount == taps, Comment(rawValue: name))
            #expect(vm.suggestedTagsAtCap == (taps == cap), Comment(rawValue: name))
            if taps == cap {
                #expect(vm.isSuggestedHashtagSelected(pills[0]) && vm.isSuggestedHashtagSelected(pills[1]))
                #expect(pills.dropFirst(2).allSatisfy { !vm.isSuggestedHashtagSelected($0) }, "six pills dimmed")
            }
            if let dir = Self.snapshotDirectory, let data = image.pngData() {
                try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                try? data.write(to: URL(fileURLWithPath: dir).appendingPathComponent("tag-pills-\(name).png"))
            }
        }
    }

    nonisolated private static var snapshotDirectory: String? {
        let fileURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent(".zc_snapshot_dir")
        guard let raw = try? String(contentsOf: fileURL, encoding: .utf8) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Routing

    @Test func presenter_newNoteRequest_carriesPillsAndNoSeed() {
        let presenter = ComposePresenter()
        presenter.openNewNote(suggestedHashtags: OnlyFoodCompose.suggestedTags)
        guard case .newNote(let text, let tags)? = presenter.request else {
            Issue.record("expected .newNote, got \(String(describing: presenter.request))")
            return
        }
        #expect(text.isEmpty)
        #expect(tags == OnlyFoodCompose.suggestedTags)
        #expect(presenter.request?.id == "new-note")
    }
}
