#!/bin/sh
# Hermetic gate for the gate machine (`~/gate.sh <branch>`). This file is the
# versioned copy — `cp ci_scripts/gate.sh ~/gate.sh` on the machine after a
# change. Written for the MacinCloud box (now gone); the Mac Studio takes the
# same form, the MacBook Air uses `--parse` on its own bundle.
#
#   ~/gate.sh <branch>            run the gate on <branch>
#   ~/gate.sh --parse <bundle>    re-read an existing .xcresult and judge it
#
# Invocation notes (each one cost a gate cycle):
# - Xcode 26.6 on the box; the only iOS runtime is 26.5 on an iPhone 17 Pro.
#   `OS=26.2` is the MacBook Air (Xcode 26.3) form and does not exist here.
# - Do NOT pass CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=YES here: on the box
#   they invalidate the cached breez_sdk_sparkFFI .pcm and the build fails
#   with a stale-module error (C-E, 2026-09-02). They are Air-only flags.
# - `-skipPackagePluginValidation` is required headless (swift-secp256k1's
#   SharedSourcesPlugin cannot show its trust prompt).
# - Serial (`-parallel-testing-enabled NO`); the known failure set is
#   KNOWN_FAILURES below, and every entry names the issue that owns it.
# - The gate file lives at gates/<pr>-<slug>.md (one per branch). Nine root
#   GATE.md files collided on merge in the 2026-09-20 wave; a root GATE.md is
#   still accepted for branches cut before that.
# - The pbxproj guard is THREE-dot: changes on the branch since it forked,
#   not every difference from main's tip (main's #41 touched
#   project.pbxproj / Package.resolved and false-positived the two-dot form).
# - The verdict comes from the .xcresult bundle via xcresulttool, NOT from
#   grepping xcodebuild's text output. The suite is Swift Testing; the
#   "Executed N tests" lines belong to the (empty) XCTest portion and read
#   0/0/0 while the real suite is running (C-J, 2026-09-03). A zero total is
#   a FAILED gate, never a pass.
# - The gate file must be the LAST commit on the branch. Review fixes are
#   code and re-open the freeze; a gate run against a HEAD that is not the
#   gate-file commit is refused (#47/#48 shipped a crash through exactly
#   that gap).
set -eu

REPO="${GATE_REPO:-$HOME/Development/zapcooking_ios}"
DEST="${GATE_DEST:-platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5}"
# KNOWN_FAILURES — tests that fail on main and are therefore not the branch's.
# Suite/function, no parens, one appended line per entry, each with the issue
# that owns it and why it is still here. Anything else failing belongs to the
# branch. A gate that always says FAIL is a gate nobody reads (the old
# SafetyTests trio printed FAIL on all nine runs of the 2026-09-20 wave), so an
# entry is added only with an issue and removed the moment the issue closes.
# Override for a one-off run with GATE_KNOWN_FAILURES="A/b C/d".
KNOWN_FAILURES=""
# issue #4 — mention e-tags treated as roots; fails identically on every
# machine since the C-E baseline (2026-09-02). Remove when #4 closes.
KNOWN_FAILURES="$KNOWN_FAILURES FeedRenderableTests/mentionTaggedNoteFollowsReplyGate"
# issue #117 — the raw dark surfaceVariant (#374151, Android/web parity) hosts
# rich content only in the group-chat bubble, where the tiers measure 2.88 /
# 2.53. Deliberately failing: the fix is on the bubble, and only if group chat
# ships in v1. Remove when #117 closes.
KNOWN_FAILURES="$KNOWN_FAILURES ColorHierarchyTests/textTiers_keepTheirContrastFloors_onTheRawToken_groupChatBubble"
# issue #134 — the 60% surfaceVariant chip wash (Show more pill, hashtag chips)
# measures 3.59 interactive over the background and 2.88 link over a surface.
# Deliberately failing until the chip recipe changes. Remove when #134 closes.
KNOWN_FAILURES="$KNOWN_FAILURES ColorHierarchyTests/textTiers_keepTheirContrastFloors_onTheSixtyPercentWashes"
# Retired 2026-09-20: SafetyTests/notificationDropsReplyInBlockedSubThread,
# SafetyTests/notificationIngestZapJudgedByResolvedActor and
# SafetyTests/purgeNonWotQualifiedScrubsInMemoryItems (issue #57) only ever
# failed on the decommissioned MacinCloud box; they pass on every serial run
# since. ColorHierarchyTests/textTiers_keepTheirContrastFloors_onEveryDarkGround
# (issue #117) failed from #94 and was never listed; PR #132 split it into
# the rendered-ground case (passes) and the two entries above.
KNOWN="${GATE_KNOWN_FAILURES:-$KNOWN_FAILURES}"

# --- judge a result bundle -------------------------------------------------
# Prints "<passed> passed / <failed> failed / <skipped> skipped / <total> total",
# lists every failure, and exits non-zero unless: total > 0 AND every failure
# is in KNOWN. A known failure that happens to pass is reported, not fatal.
judge() {
  bundle="$1"
  if [ ! -d "$bundle" ]; then
    echo "gate: FAIL — no result bundle at $bundle (the run never reached the tests; build failure?)"
    return 5
  fi
  summary="$(xcrun xcresulttool get test-results summary --path "$bundle" 2>&1)" || {
    echo "gate: FAIL — xcresulttool could not read $bundle:"
    echo "$summary" | head -5
    return 5
  }
  printf '%s' "$summary" | GATE_KNOWN="$KNOWN" GATE_RAN="${GATE_RAN:-}" python3 -c '
import json, os, re, sys
try:
    s = json.load(sys.stdin)
except Exception as e:
    print(f"gate: FAIL — result summary is not JSON ({e})"); sys.exit(5)
total   = int(s.get("totalTestCount") or 0)
passed  = int(s.get("passedTests") or 0)
failed  = int(s.get("failedTests") or 0)
skipped = int(s.get("skippedTests") or 0)
result = s.get("result")
print(f"gate: {passed} passed / {failed} failed / {skipped} skipped / {total} total  (bundle result: {result})")
known = {k.strip() for k in os.environ.get("GATE_KNOWN", "").split() if k.strip()}
known_funcs = {k.split("/")[-1] for k in known}
seen_known, unexpected = set(), []
for f in s.get("testFailures", []) or []:
    blob = " ".join(str(v) for v in f.values())
    name = str(f.get("testName") or f.get("testIdentifierString") or f.get("testIdentifier") or "?")
    func = re.sub(r"\(.*$", "", name.split("/")[-1])
    hit = next((k for k in known if k.split("/")[-1] == func and (k.split("/")[0] in blob)), None)
    if hit is None and func in known_funcs:
        hit = next(k for k in known if k.split("/")[-1] == func)
    if hit:
        seen_known.add(hit)
        print(f"gate:   known   {hit}")
    else:
        unexpected.append(name)
        text = str(f.get("failureText") or "?")[:160]
        print(f"gate:   NEW     {name}  ({text})")
rc = 0
if total == 0:
    print("gate: FAIL — zero tests in the bundle. A gate that runs nothing is not green."); rc = 6
if unexpected:
    print(f"gate: FAIL — {len(unexpected)} failure(s) outside the known set (KNOWN_FAILURES in gate.sh): " + ", ".join(unexpected)); rc = 7
for k in sorted(known - seen_known):
    print(f"gate:   note    known failure did not fail this run: {k}")
ran = os.environ.get("GATE_RAN") or "(--parse: tree not recorded)"
if rc == 0:
    print(f"gate: PASS — failure set is exactly the known set ({len(seen_known)}/{len(known)}); {total} tests ran on {ran}.")
else:
    print(f"gate: FAILED on {ran}.")
sys.exit(rc)
'
}

if [ "${1:-}" = "--parse" ]; then
  judge "${2:?usage: gate.sh --parse <bundle.xcresult>}"
  exit $?
fi

BRANCH="${1:?usage: gate.sh <branch> | gate.sh --parse <bundle>}"
SAFE="$(echo "$BRANCH" | tr '/' '-')"
STAMP="$(date +%Y%m%d-%H%M%S)"
LOG="${GATE_LOG:-$HOME/gate-$SAFE-$STAMP.log}"
BUNDLE="${GATE_BUNDLE:-$HOME/gate-$SAFE-$STAMP.xcresult}"

cd "$REPO"
git fetch origin
git checkout "$BRANCH"
git pull --ff-only
git status --short | grep -q . && { echo "gate: working tree not clean"; exit 2; }
HEAD_SHA="$(git rev-parse --short HEAD)"
ON="$(git rev-parse --abbrev-ref HEAD)"
if [ "$ON" != "$BRANCH" ]; then
  echo "gate: checkout is on '$ON' @ $HEAD_SHA, not '$BRANCH' — the run would test the wrong tree. Stop."
  exit 2
fi

# The gate file — the one file under gates/ (or a root GATE.md) that this
# branch adds or changes relative to its merge-base with main. Exactly one.
GATE_FILE="$(git diff --name-only origin/main...HEAD -- 'gates/*.md' GATE.md | tr '\n' ' ' | sed 's/ *$//')"
case "$GATE_FILE" in
  "")  echo "gate: no gate file on $BRANCH (expected gates/<pr>-<slug>.md) — stop"; exit 4 ;;
  *" "*) echo "gate: more than one gate file on $BRANCH ($GATE_FILE) — keep one — stop"; exit 4 ;;
esac

# Freeze — the gate file is the last commit, or this is not a gate.
GATE_SHA="$(git log -1 --format=%h -- "$GATE_FILE")"
if [ "$GATE_SHA" != "$HEAD_SHA" ]; then
  echo "gate: FREEZE BROKEN — $GATE_FILE last changed in $GATE_SHA but HEAD is $HEAD_SHA."
  echo "gate: commits after the gate file (review fixes count):"
  git log --oneline "$GATE_SHA..HEAD"
  echo "gate: push a fresh $GATE_FILE pinning $HEAD_SHA, then rerun — stop"
  exit 4
fi
echo "gate: $BRANCH @ $HEAD_SHA ($GATE_FILE commit) — freeze intact"

# Gate 6 — no project-file changes on the branch (three-dot form).
if git diff --stat origin/main...HEAD -- wisp.xcodeproj | grep -q .; then
  echo "gate: pbxproj diff on $BRANCH vs merge-base with origin/main — stop"
  git diff --stat origin/main...HEAD -- wisp.xcodeproj
  exit 3
fi

# Gate 1 — hermetic wispTests, serial. Live suites stay skipped (no sentinel).
# xcodebuild exits non-zero whenever any test fails — including the known
# ones — so its status is recorded but the verdict is the bundle's.
rm -rf "$BUNDLE"
set +e
xcodebuild test -project wisp.xcodeproj -scheme wisp \
  -destination "$DEST" \
  -skipPackagePluginValidation \
  -parallel-testing-enabled NO \
  -only-testing:wispTests \
  -resultBundlePath "$BUNDLE" \
  > "$LOG" 2>&1
XC=$?
set -e
grep -E "error:|Test run|Test Suite 'wispTests" "$LOG" | tail -n 20 || true
echo "gate: xcodebuild exit $XC; log $LOG; bundle $BUNDLE"

GATE_RAN="$BRANCH @ $HEAD_SHA" judge "$BUNDLE"
