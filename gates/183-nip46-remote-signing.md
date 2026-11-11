# Gate 183 — NIP-46 remote signing (bunker + nostrconnect)

## Remote-signer size limit (Lazarus restores and any large publish)

NIP-46 wraps every `sign_event` inside an encrypted kind-24133 request:
NIP-44 encryption expands the payload ~1.35x and the transport event adds
a few hundred bytes. Signer apps cap what they accept per request —
Primal refuses requests over ~64 KB, which puts the ceiling on the
plaintext event at roughly 48 KB.

Consequence: a kind-3 follow list restores cleanly up to ~650 follows
over a remote signer. Past that (an 867-follow restore serializes to
~64 KB and was refused by Primal in testing), signing fails and the
signer's refusal is easy to misread as a broken session.

What the app does about it:

- `LazarusPublisher.remoteSignerSafeEventBytes` (48,000) is the threshold.
  A restore attempt on a remote account that serializes larger fails
  before any signing round-trip with
  `.tooLargeForRemoteSigner(serializedBytes:)`, and the review screen
  says exactly why, with the size, before the user taps Restore.
- Genuine signing failures carry the signer's own error string through
  `LazarusRestoreFailure.signFailed(String?)` (e.g. an "event too large"
  refusal from the signer).
- The same ceiling applies to any user-signed kind-3 republish (follow /
  unfollow) over a remote signer; trimming an oversized list must happen
  inside the signer app itself, or from a device holding the local key.

Upstream note for the Lazarus spec (feat/lazarus-spec-0.6.2): recovery
over a NIP-46 remote signer is bounded by the signer's request size cap;
restore flows should treat ~48 KB of serialized event as the practical
per-publish limit and surface it before attempting.

## Standing rule: no damus.io in hardcoded relay sets

The AUTH-loop above made the damus relay operator post a public warning
about excessive requests. Standing rule after that incident: never add
`wss://relay.damus.io` to any hardcoded relay set (handshake defaults,
`RelayDefaults.indexers`/`onboarding`/`fallbacks`, DM relays, backup
relays). It lives in `AGENTS.md` ("Never hardcode the damus relay") and
as a comment above `RelayDefaults.indexers`. A user may still keep damus
in their own saved relay settings; we simply never dial it by default.

## Gate run at c2e39ba (2026-11-10)

**Code frozen at c2e39ba** (Seth's one-line `Signer.swift` fix on top of
c15cc3b: the remote-signed event's `created_at` is compared to the resolved
`ts` that was sent, not to the optional `createdAt` parameter, which is nil
for most callers). The gate ran on that tree as checked out, with no local
patch. This file is the only commit after it. A later code commit breaks the
freeze; push a fresh gate file last.

Mac Studio, Xcode 27.2 (27B52), `platform=iOS Simulator,id=90B23E20-BA47-4AD0-98EF-175513626A4B`
(iPhone 18 Pro, iOS 27.2), DerivedData `wisp-183` (cold build).

```
xcodebuild build-for-testing -project wisp.xcodeproj -scheme wisp \
  -destination 'platform=iOS Simulator,id=90B23E20-BA47-4AD0-98EF-175513626A4B' \
  -skipPackagePluginValidation -derivedDataPath <dd>
xcodebuild test-without-building -project wisp.xcodeproj -scheme wisp \
  -destination 'platform=iOS Simulator,id=90B23E20-BA47-4AD0-98EF-175513626A4B' \
  -derivedDataPath <dd> -parallel-testing-enabled NO \
  -collect-test-diagnostics never -only-testing:wispTests -resultBundlePath <bundle>
sh ci_scripts/gate.sh --parse <bundle>
```

| gate | result |
|---|---|
| Build | TEST BUILD SUCCEEDED, no compile errors; 155 unique `file:line` warnings, none in `Signer.swift` |
| Hermetic, serial | **1659 passed / 3 failed / 22 skipped / 1684 total: PASS** |
| Failures | exactly the known set: #4 `FeedRenderableTests/mentionTaggedNoteFollowsReplyGate`, #117 `ColorHierarchyTests/…onTheRawToken_groupChatBubble`, #134 `ColorHierarchyTests/…onTheSixtyPercentWashes` |
| Gate 6 (pbxproj, three-dot) | **does not pass as written**: see below |

The 1684 total matches the earlier 183 gate on this toolchain. No failure
is new on this branch.

**Gate 6.** `git diff origin/main...HEAD -- wisp.xcodeproj` shows +24 lines in
`project.pbxproj`, all from f3495fd. They are the `PBXBuildFile`,
`PBXFileReference`, group and Sources entries for six new root-level files:
`Nip46.swift`, `Nip46Client.swift`, `Nip46Manager.swift`,
`Nip46Session.swift`, `Nip46LoginView.swift` and `Nip46LoginViewModel.swift`.
Root-level sources need these entries to compile (AGENTS.md "Source layout"),
so the diff is needed, but `gate.sh` stops on it. Moving the files under
`wisp/` would remove it. That is a source change and was not made here.

Not covered by this gate: a device pass against a real NIP-46 signer
(Clave / Amber / Primal). Nothing hermetic exercises one.

## Merge and device pass (2026-11-10)

**Gate 6 accepted for this PR.** Seth accepted the `project.pbxproj` diff
for #183: it is the six file registrations above and nothing else. #183 merged
as b680867.

**Device pass, real remote signer, after the `Signer.swift` fix (c2e39ba).**
Seth device-tested on 2026-11-10 against a real NIP-46 remote signer. All of
these passed:

| flow | result |
|---|---|
| Sign-in | pass |
| Post | pass |
| React | pass |
| Save recipe | pass |
| Create list | pass |
| Mute | pass |
| Block | pass |

This closes the "not covered" line above. The hermetic regression cover for
the `created_at` comparison follows in its own PR
(`RemoteSignerCreatedAtTests`).
