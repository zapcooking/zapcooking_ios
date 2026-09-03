#!/bin/sh
# Hermetic gate for the MacinCloud box (`~/gate.sh <branch>`). This file is the
# versioned copy — `cp ci_scripts/gate.sh ~/gate.sh` on the box after a change.
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
set -eu

BRANCH="${1:?usage: gate.sh <branch>}"
REPO="${GATE_REPO:-$HOME/Development/zapcooking_ios}"
DEST="${GATE_DEST:-platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5}"
LOG="${GATE_LOG:-$HOME/gate-$(echo "$BRANCH" | tr '/' '-').log}"

cd "$REPO"
git fetch origin
git checkout "$BRANCH"
git pull --ff-only
git status --short | grep -q . && { echo "gate: working tree not clean"; exit 2; }

# Gate 6 — no project-file changes on the branch (three-dot form).
if git diff --stat origin/main...HEAD -- wisp.xcodeproj | grep -q .; then
  echo "gate: pbxproj diff on $BRANCH vs merge-base with origin/main — stop"
  git diff --stat origin/main...HEAD -- wisp.xcodeproj
  exit 3
fi

# Gate 1 — hermetic wispTests, serial. Live suites stay skipped (no sentinel).
xcodebuild test -project wisp.xcodeproj -scheme wisp \
  -destination "$DEST" \
  -skipPackagePluginValidation \
  -parallel-testing-enabled NO \
  -only-testing:wispTests \
  2>&1 | tee "$LOG" | grep -E "Test Suite|Executed|passed|failed|error:" || true

echo "gate: log at $LOG"
grep -E "Executed [0-9]+ tests" "$LOG" | tail -1
