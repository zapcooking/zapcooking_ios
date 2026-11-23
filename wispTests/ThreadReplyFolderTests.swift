//
//  ThreadReplyFolderTests.swift
//  wispTests
//
//  Coverage for the depth-cap folding algorithm behind collapsible reply
//  threads (closes wisp-ios#402). Extracted from ThreadView specifically
//  so this logic has real test coverage.
//

import Testing
@testable import wisp

struct ThreadReplyFolderTests {

    private func event(_ id: String) -> NostrEvent {
        NostrEvent(id: id, pubkey: "pub-\(id)", kind: 1, createdAt: 0, tags: [], content: "", sig: "")
    }

    private func row(_ id: String, depth: Int, wotHidden: Bool = false) -> NestedReplyRow {
        NestedReplyRow(row: ThreadRow(event: event(id), isWotHidden: wotHidden), depth: depth)
    }

    private func singleIds(_ result: [ThreadReplyFolder.DisplayItem]) -> [String] {
        result.compactMap { item in
            if case .single(let r, _) = item { return r.id }
            return nil
        }
    }

    @Test func emptyThreadProducesEmptyResult() {
        #expect(ThreadReplyFolder.fold(items: [], expandedBranchIds: [], exemptTargetId: nil).isEmpty)
    }

    @Test func directParentEventsResolvesStructuralParentNotGrandparent() {
        // r1(0) -> r2(1) -> [c1(2), c2(2)] two depth-2 siblings under r2.
        let items = [row("r1", depth: 0), row("r2", depth: 1), row("c1", depth: 2), row("c2", depth: 2)]
        let focal = event("root")
        let parents = ThreadReplyFolder.directParentEvents(in: items, focal: focal)

        #expect(parents["r1"]?.id == "root")
        #expect(parents["r2"]?.id == "r1")
        #expect(parents["c1"]?.id == "r2")
        #expect(parents["c2"]?.id == "r2")
    }

    @Test func shallowThreadUnderCapNeverFolds() {
        let items = [row("r1", depth: 0), row("r2", depth: 1)]
        let result = ThreadReplyFolder.fold(items: items, expandedBranchIds: [], exemptTargetId: nil)
        #expect(result.count == 2)
        for item in result {
            if case .collapsedReplies = item { Issue.record("shallow thread should never fold") }
        }
    }

    @Test func depthCapFoldsRepliesBeyondCap() {
        // root -> r2(1) -> r3(2) -> r4(3) -> r5(4) -> r6(5)
        let items = [
            row("r1", depth: 0), row("r2", depth: 1), row("r3", depth: 2),
            row("r4", depth: 3), row("r5", depth: 4), row("r6", depth: 5),
        ]
        let result = ThreadReplyFolder.fold(items: items, expandedBranchIds: [], exemptTargetId: nil)

        // Depths 0..3 render as posts (root + DEPTH_CAP levels); r4's
        // subtree (r5, r6) folds behind one marker anchored at r4.
        #expect(singleIds(result) == ["r1", "r2", "r3", "r4"])
        guard case .collapsedReplies(let anchor, let depth, let hiddenCount) = result.last else {
            Issue.record("expected a trailing collapsedReplies marker")
            return
        }
        #expect(anchor.id == "r4")
        #expect(depth == 4)
        #expect(hiddenCount == 2)
    }

    @Test func expandingRevealsWholeSubtreeUncapped() {
        let items = [
            row("r1", depth: 0), row("r2", depth: 1), row("r3", depth: 2),
            row("r4", depth: 3), row("r5", depth: 4), row("r6", depth: 5), row("r7", depth: 6),
        ]
        let result = ThreadReplyFolder.fold(items: items, expandedBranchIds: ["r4"], exemptTargetId: nil)

        // Expanding r4 reveals everything below it in one shot — the cap
        // does NOT reapply one level deeper.
        #expect(singleIds(result) == ["r1", "r2", "r3", "r4", "r5", "r6", "r7"])
        for item in result {
            if case .collapsedReplies = item { Issue.record("expanded branch should not re-fold") }
        }
    }

    @Test func exemptTargetPathIsNeverFoldedButSiblingsStillFold() {
        // Two branches off r3(depth 2): branch A has no target and folds at
        // a4; branch B leads to the exempt target and must render fully.
        let items = [
            row("r1", depth: 0), row("r2", depth: 1), row("r3", depth: 2),
            row("a4", depth: 3), row("a5", depth: 4), row("a6", depth: 5),
            row("b4", depth: 3), row("b5", depth: 4), row("target", depth: 5),
        ]
        let result = ThreadReplyFolder.fold(items: items, expandedBranchIds: [], exemptTargetId: "target")
        let ids = Set(singleIds(result))

        #expect(ids.contains("a4"))
        #expect(!ids.contains("a5"))
        #expect(!ids.contains("a6"))
        #expect(ids.contains("b4"))
        #expect(ids.contains("b5"))
        #expect(ids.contains("target"))
    }

    @Test func midAirOnlyOnDepthTransitionsNotBetweenSiblings() {
        // r1 -> three depth-1 siblings under the same parent.
        let items = [row("r1", depth: 0), row("c1", depth: 1), row("c2", depth: 1), row("c3", depth: 1)]
        let result = ThreadReplyFolder.fold(items: items, expandedBranchIds: [], exemptTargetId: nil)

        let flags = result.compactMap { item -> (String, Bool)? in
            if case .single(let r, let midAir) = item { return (r.id, midAir) }
            return nil
        }
        // r1 is depth 0 (no rail at all). c1 is the first reply of a
        // branch — its rail can't align with r1's, so it's dashed. c2/c3
        // are same-depth siblings directly below a same-depth row, so
        // their rail continues the one above without a break.
        #expect(flags.map(\.0) == ["r1", "c1", "c2", "c3"])
        #expect(flags.map(\.1) == [false, true, false, false])
    }

    @Test func wotGroupPreservesReachabilityOfFoldedDescendants() {
        // r1->r2->r3, then two same-depth WoT-hidden siblings at depth 3;
        // only the second (w2) has its own deep children past the cap.
        let items = [
            row("r1", depth: 0), row("r2", depth: 1), row("r3", depth: 2),
            row("w1", depth: 3, wotHidden: true),
            row("w2", depth: 3, wotHidden: true),
            row("d4", depth: 4), row("d5", depth: 5),
        ]
        let result = ThreadReplyFolder.fold(items: items, expandedBranchIds: [], exemptTargetId: nil)

        guard case .wotGroup(let count, let depth, _) = result[3] else {
            Issue.record("expected a wotGroup absorbing both hidden siblings")
            return
        }
        #expect(count == 2)
        #expect(depth == 3)
        guard case .collapsedReplies(let anchor, let foldDepth, let hiddenCount) = result[safe: 4] else {
            Issue.record("expected a collapsedReplies marker right after the wotGroup, not dropped")
            return
        }
        #expect(anchor.id == "w2")
        #expect(foldDepth == 4)
        #expect(hiddenCount == 2)
    }

    // MARK: - Adjacency with orphan grafting (#220 follow-up)

    private func reply(
        _ id: String, parent: String? = nil, root: String? = nil,
        kind: Int = 1, pubkey: String? = nil
    ) -> NostrEvent {
        var tags: [[String]] = []
        if let root { tags.append(["e", root, "", "root"]) }
        if let parent { tags.append(["e", parent, "", "reply"]) }
        return NostrEvent(id: id, pubkey: pubkey ?? "pk-\(id)", kind: kind,
                          createdAt: 0, tags: tags, content: "", sig: "")
    }

    private func adjacency(_ events: [NostrEvent], hidden: Set<String> = []) -> [String: [NostrEvent]] {
        let parentOf: (NostrEvent) -> String? = { event in
            let es = event.tags.filter { $0.first == "e" && $0.count >= 2 }
            return (es.first { $0.count >= 4 && $0[3] == "reply" } ?? es.first)?[1]
        }
        var hiddenParents: [String: String] = [:]
        for event in events where hidden.contains(event.id) { hiddenParents[event.id] = parentOf(event) ?? "" }
        return ThreadReplyFolder.adjacency(
            events.filter { !hidden.contains($0.id) },
            knownIds: Set(events.map(\.id)).subtracting(hidden),
            hiddenParents: hiddenParents,
            parentOf: { event in
                let es = event.tags.filter { $0.first == "e" && $0.count >= 2 }
                return (es.first { $0.count >= 4 && $0[3] == "reply" } ?? es.first)?[1]
            },
            rootAnchorOf: { event in
                event.tags.first { $0.first == "e" && $0.count >= 2 }?[1]
            }
        )
    }

    /// The #220 follow-up: a reply whose parent (a muted author's note no
    /// relay returned) never arrived grafts to its root anchor, so the
    /// user's own reply stays findable in the thread a notification
    /// deep-linked to.
    @Test func orphanedReply_graftsToKnownRootAnchor() {
        let root = reply("root")
        let orphan = reply("mine", parent: "missing", root: "root")
        let byParent = adjacency([root, orphan])
        #expect(byParent["root"]?.map { $0.id } == ["mine"])
        #expect(byParent["missing"] == nil)
    }

    @Test func replyWithKnownParent_staysNested() {
        let root = reply("root")
        let a = reply("a", parent: "root", root: "root")
        let b = reply("b", parent: "a", root: "root")
        let byParent = adjacency([root, a, b])
        #expect(byParent["root"]?.map { $0.id } == ["a"])
        #expect(byParent["a"]?.map { $0.id } == ["b"])
    }

    /// No known parent AND no known anchor: nothing to graft to — dropped,
    /// same as the pre-graft behavior.
    @Test func orphanWithoutKnownAnchor_isDropped() {
        let root = reply("root")
        let orphan = reply("mine", parent: "missing", root: "also-missing")
        let byParent = adjacency([root, orphan])
        #expect(byParent["root"]?.isEmpty ?? true)
        #expect(byParent["missing"] == nil)
    }

    /// A forged or malformed root tag naming the reply itself must not
    /// self-graft into a cycle.
    @Test func graftNeverTargetsTheEventItself() {
        let root = reply("root")
        let orphan = reply("mine", parent: "missing", root: "mine")
        let byParent = adjacency([root, orphan])
        #expect(byParent["mine"] == nil)
        #expect(byParent["root"]?.isEmpty ?? true)
    }

    /// The notification-tap bug: a stray kind-1 on a comment is hidden, and
    /// the user's own comment chain hangs BELOW it. The chain must re-parent
    /// to the stray's own parent, not be severed with it.
    @Test func repliesBelowAHiddenStray_reparentToItsParent() {
        let root = reply("root")
        let comment = reply("muted-comment", parent: "root", root: "root", kind: 1111)
        let stray = reply("stray", parent: "muted-comment", root: "root")      // kind-1 on a comment
        let mine = reply("mine", parent: "stray", root: "root")
        let deeper = reply("deeper", parent: "mine", root: "root", kind: 1111)
        let byParent = adjacency([root, comment, stray, mine, deeper], hidden: ["stray"])
        #expect(byParent["muted-comment"]?.map { $0.id } == ["mine"])
        #expect(byParent["mine"]?.map { $0.id } == ["deeper"])
        #expect(byParent["stray"] == nil)
    }

    @Test func chainOfHiddenStrays_resolvesToNearestVisibleAncestor() {
        let root = reply("root")
        let s1 = reply("s1", parent: "root", root: "root")
        let s2 = reply("s2", parent: "s1", root: "root")
        let mine = reply("mine", parent: "s2", root: "root")
        let byParent = adjacency([root, s1, s2, mine], hidden: ["s1", "s2"])
        #expect(byParent["root"]?.map { $0.id } == ["mine"])
    }

    /// A forged parent cycle among hidden notes must terminate.
    @Test func hiddenParentCycle_terminates() {
        let root = reply("root")
        let s1 = reply("s1", parent: "s2", root: "root")
        let s2 = reply("s2", parent: "s1", root: "root")
        let mine = reply("mine", parent: "s1", root: "root")
        let byParent = adjacency([root, s1, s2, mine], hidden: ["s1", "s2"])
        // Unresolvable parent → falls back to graft on the root anchor.
        #expect(byParent["root"]?.map { $0.id } == ["mine"])
    }

    /// Kind-1111 orphans graft the same way — their uppercase `E` names the
    /// conversation anchor (resolved by the caller's `rootAnchorOf`).
    @Test func orphanedComment_graftsViaRootAnchor() {
        let root = reply("root")
        let comment = reply("c1", parent: "missing", root: "root", kind: 1111)
        let byParent = adjacency([root, comment])
        #expect(byParent["root"]?.map { $0.id } == ["c1"])
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
