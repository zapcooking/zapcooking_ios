# GATE — concern/parser-blank-lines (#119: blank lines around block cards, surplus blank lines)
Renderer only (`ContentParser` passes 5 and 6): nothing published, no
network change, so §7.13's live-write protocol does not apply. Rebased
onto main at 4d89593 (#120, Unicode hashtags — the last thing to touch
`ContentParser`). The MacBook Air is the gate machine until the Mac
Studio lands; the box block below is the standard form for the Studio.

**Frozen at this commit.** App code is frozen at **44ee02e**. This GATE.md
is the only commit after it and is the HEAD commit — `gate.sh` refuses to
run otherwise. A review fix re-opens the freeze: push a fresh GATE.md last.

## What changed since the last gate run (PR body's "Verification")
- Rebased onto main 4d89593 (was gated against pre-#116 main). No
  conflicts.
- Copilot review fix (44ee02e): pass 5 trims block-adjacent blank lines
  with the same whitespace-aware regexes pass 6 uses, so an indented blank
  line (`text\n   \n<card>`) or a CRLF terminator no longer leaves a text
  row behind; the trailing regex also swallows the CR before the final
  newline. +3 tests (indented blank line, CRLF both sides of a card, CRLF
  padding at the end of a post).

## Local (MacBook Air, Xcode 27.0, iOS 26.2 sim, -derivedDataPath shared)
- Full serial `-only-testing:wispTests` at 44ee02e: **1100 passed / 2 failed / 21 skipped / 1123** — the two are exactly the Air's clean-main set under Xcode 27 (#4 `FeedRenderableTests/mentionTaggedNoteFollowsReplyGate` and #117 `ColorHierarchyTests/textTiers…`; main at 4d89593 ran 1077/3/21 of 1101 the same morning, its third failure a load flake that passes alone). +22 tests over main. Zero warnings on lines this branch adds. Machine: Seth's MacBook Air, Xcode 27.0, iOS 26.2 simulator, serial.
- pbxproj: no diff (three-dot). New test files are under `wispTests/`.
- Gate 4 (by hand) is Seth's device pass: a note with an invoice / quote /
  image card after a paragraph shows no gap above the card; a post padded
  with trailing newlines ends at its last line; a stanza with single
  newlines keeps every break.

## Gate 1 — hermetic, serial (Mac Studio / box form)
```
xcodebuild test -project wisp.xcodeproj -scheme wisp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' \
  -skipPackagePluginValidation \
  -parallel-testing-enabled NO \
  -only-testing:wispTests
```
Pass = main's failure set on that machine and nothing else; judge the
`.xcresult` via `sh ci_scripts/gate.sh --parse <bundle>`. Expect +25
tests over main (22 from the concern, 3 from the review fix).

## Gate 2 — the parser suites alone
```
xcodebuild test -project wisp.xcodeproj -scheme wisp \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' \
  -skipPackagePluginValidation \
  -parallel-testing-enabled NO \
  -only-testing:wispTests/ContentParserBlankLineTests \
  -only-testing:wispTests/ContentParserBlockSpacingTests \
  -only-testing:wispTests/ContentParserDedupTests \
  -only-testing:wispTests/ImageUrlsTests
```

## Gate 6 — project file
```
git diff origin/main...HEAD --stat -- wisp.xcodeproj
```
Must print nothing.
