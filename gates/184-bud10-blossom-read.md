# GATE — feat/bud10-blossom-read (PR #184: render BUD-10 blossom: URIs)

main 4631b6a (#212, #213) merged in as 75cfb13. **Code frozen at 75cfb13.** This
file is the only commit after it, and it is the HEAD commit. A review fix
breaks the freeze: push a fresh gate file last. This file replaces the gate
at 8b5da18 (code 1ec4498 on main 66bd7a2). That gate failed only on main's
`FollowsSinceTests` test, which #212 has since fixed.

## What is on the branch
dmnyc's two commits (e0aa90a, 0995f40), the merge of main (cb0634d), and
1ec4498. 1ec4498 caps the verify download at 20 MB
(`BlossomUriResolver.defaultMaxBlobBytes`). The body is streamed into an
incremental SHA-256 and never buffered. The transfer is cancelled as soon as
it passes the cap. A `Content-Length` over the cap is rejected from the
header, and a URI whose `sz` is over the cap is never fetched. Each of these
counts as a miss, and the next server is tried. Test seam:
`init(session:maxBlobBytes:)`.

## Gate 1: build green, no new warnings in touched files
Rebuilt incrementally at 75cfb13 after the main merge, which touched no branch file (only `wispTests/FollowsSinceTests.swift` and `gates/`). The warning scan below is from the build of the branch code, which is unchanged since.

Mac Studio, Xcode 27.2 (27B52), `wisp-pr184`: **TEST BUILD SUCCEEDED**,
with every touched file recompiled (touched, then rebuilt). Zero warnings in
`ContentParser.swift`, `wisp/BlossomUri.swift`,
`wisp/InlineMediaLoader.swift` and both test files.
`wisp/BlossomUriResolver.swift` has four main-actor warnings in `probe()`:
`BlossomUri.parse`, `NostrKey.load()`, `BlossomServerList.cached(for:)`
and `candidateUrls`. All four are on the PR head 0995f40 before this commit
(stash-build: same four, lines 54/56/57/60), and 1ec4498 adds none. They are
dmnyc's, and fixing them is outside this commit.

## Gate 2: hermetic at the known set, serial
After `sh ci_scripts/preboot-sim.sh 90B23E20-BA47-4AD0-98EF-175513626A4B`:
```
xcodebuild test-without-building -project wisp.xcodeproj -scheme wisp \
  -destination 'platform=iOS Simulator,id=90B23E20-BA47-4AD0-98EF-175513626A4B' \
  -derivedDataPath ~/Library/Developer/Xcode/DerivedData/wisp-pr184 \
  -parallel-testing-enabled NO -only-testing:wispTests \
  -collect-test-diagnostics never -resultBundlePath rg184.xcresult
sh ci_scripts/gate.sh --parse rg184.xcresult
```
```
gate: 1857 passed / 3 failed / 23 skipped / 1883 total  (bundle result: Failed)
gate:   known   FeedRenderableTests/mentionTaggedNoteFollowsReplyGate
gate:   known   ColorHierarchyTests/textTiers_keepTheirContrastFloors_onTheRawToken_groupChatBubble
gate:   known   ColorHierarchyTests/textTiers_keepTheirContrastFloors_onTheSixtyPercentWashes
gate: PASS — failure set is exactly the known set (3/3); 1883 tests ran
```
Oversized blob, from the run above: `BlossomUriResolverCapTests` 8/8 and
`BlossomUriTests` 6/6. All 8 run through an in-process URLProtocol stub on
the resolver's own session, which answers 404 for any unknown host, so
nothing reaches the network.
- Accepted: a blob under the cap, and one exactly at it.
- Rejected: a body one byte over with no `Content-Length`; an endless
  body over a 1 MB cap (the stub sees the transfer stopped before its
  64 MB bound); an over-cap `Content-Length` on a small, correctly hashed
  body; an over-cap `sz` (zero requests).
- An oversized first server falls through to the second.
- Mutation check: with the streaming cap removed, the one-byte-over and
  endless-body tests fail.
- The suite alone passed 3 runs out of 3.

First full run at 75cfb13. No local patch. No `project.pbxproj` diff
(`git diff origin/main...HEAD --stat -- wisp.xcodeproj` is empty). No test
opens a socket, publishes an event or sends AUTH.

## Not gated
- No device pass and no live Blossom server. The cap is proven against the
  stub only.
- The four pre-existing warnings above.
