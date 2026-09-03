#!/bin/sh
# Hermetic gate for the MacinCloud box (`~/gate.sh <branch>`). This file is the
# versioned copy — `cp ci_scripts/gate.sh ~/gate.sh` on the box after a change.
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
# - Serial (`-parallel-testing-enabled NO`); the box's known failure set is
#   #4 FeedRenderableTests plus three SafetyTests (issue #57).
# - The pbxproj guard is THREE-dot: changes on the branch since it forked,
#   not every difference from main's tip (main's #41 touched
#   project.pbxproj / Package.resolved and false-positived the two-dot form).
# - The verdict comes from the .xcresult bundle via xcresulttool, NOT from
#   grepping xcodebuild's text output. The suite is Swift Testing; the
#   "Executed N tests" lines belong to the (empty) XCTest portion and read
#   0/0/0 while the real suite is running (C-J, 2026-09-03). A zero total is
#   a FAILED gate, never a pass.
# - GATE.md must be the LAST commit on the branch. Review fixes are code and
#   re-open the freeze; a gate run against a HEAD that is not the GATE.md
#   commit is refused (#47/#48 shipped a crash through exactly that gap).
set -eu

REPO="${GATE_REPO:-$HOME/Development/zapcooking_ios}"
DEST="${GATE_DEST:-platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5}"
# Known environmental failures on this box (issue #57). Suite/function, no
# parens. Anything else failing belongs to the branch. Override with
# GATE_KNOWN_FAILURES="A/b C/d" when #57 changes.
KNOWN="${GATE_KNOWN_FAILURES:-FeedRenderableTests/mentionTaggedNoteFollowsReplyGate SafetyTests/notificationDropsReplyInBlockedSubThread SafetyTests/notificationIngestZapJudgedByResolvedActor SafetyTests/purgeNonWotQualifiedScrubsInMemoryItems}"

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
    print(f"gate: FAIL — {len(unexpected)} failure(s) outside the known set (issue #57): " + ", ".join(unexpected)); rc = 7
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

# Freeze — GATE.md is the last commit, or this is not a gate.
if [ ! -f GATE.md ]; then
  echo "gate: no GATE.md on $BRANCH — stop"; exit 4
fi
GATE_SHA="$(git log -1 --format=%h -- GATE.md)"
if [ "$GATE_SHA" != "$HEAD_SHA" ]; then
  echo "gate: FREEZE BROKEN — GATE.md last changed in $GATE_SHA but HEAD is $HEAD_SHA."
  echo "gate: commits after the gate file (review fixes count):"
  git log --oneline "$GATE_SHA..HEAD"
  echo "gate: push a fresh GATE.md pinning $HEAD_SHA, then rerun — stop"
  exit 4
fi
echo "gate: $BRANCH @ $HEAD_SHA (GATE.md commit) — freeze intact"

# Gate 6 — no project-file changes on the branch (three-dot form).
if git diff --stat origin/main...HEAD -- wisp.xcodeproj | grep -q .; then
  echo "gate: pbxproj diff on $BRANCH vs merge-base with origin/main — stop"
  git diff --stat origin/main...HEAD -- wisp.xcodeproj
  exit 3
fi

# Gate 1 — hermetic wispTests, serial. Live suites stay skipped (no sentinel).
# xcodebuild exits non-zero whenever any test fails — including the four
# known ones — so its status is recorded but the verdict is the bundle's.
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
