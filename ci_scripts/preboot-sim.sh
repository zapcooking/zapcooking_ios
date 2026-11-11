#!/bin/sh
# Boot a simulator and wait until SpringBoard is settled, BEFORE any
# `xcodebuild test` / `test-without-building` against it (issue: render-test
# flake, issue #207).
#
#   sh ci_scripts/preboot-sim.sh <udid>
#
# Why: the iOS 27.2 simulator's SpringBoard sometimes aborts during a cold
# boot (SIGABRT, NSAssertion in -[RBSAssertion dealloc] from
# -[FBScene(PosterUIFoundation) pui_executeSnapshotForDescriptor:...], the
# lock-screen poster snapshot). When xcodebuild boots the simulator itself it
# launches the test host straight away; if the crash lands after that launch,
# the restarted SpringBoard re-bootstraps the already-running host "with
# intent background", and the host has NO connected UIWindowScene for the
# whole run. Every test that attaches a UIWindow to
# `UIApplication.shared.connectedScenes.first` then draws nothing and lays
# out nothing — the 17-test "drew nothing / did not lay out" set.
#
# A simulator that is already booted is left booted by xcodebuild, so after
# this script no run cold-boots at all, and any boot-time SpringBoard crash
# happens here, before the host exists.
set -eu
UDID="${1:?usage: preboot-sim.sh <simulator udid>}"
STABLE_FOR="${PREBOOT_STABLE_SECONDS:-15}"
TIMEOUT="${PREBOOT_TIMEOUT_SECONDS:-120}"

xcrun simctl boot "$UDID" 2>/dev/null || true   # already booted is fine
xcrun simctl bootstatus "$UDID" -b >/dev/null

sb_pid() {
  xcrun simctl spawn "$UDID" launchctl list 2>/dev/null \
    | awk '$3 == "com.apple.SpringBoard" { print $1 }'
}

start=$(date +%s)
last="$(sb_pid)"
since=$start
while :; do
  sleep 1
  now=$(date +%s)
  pid="$(sb_pid)"
  if [ -z "$pid" ] || [ "$pid" = "-" ] || [ "$pid" != "$last" ]; then
    [ -n "$last" ] && [ -n "$pid" ] && [ "$pid" != "$last" ] \
      && echo "preboot: SpringBoard restarted ($last -> $pid); waiting again"
    last="$pid"
    since=$now
  elif [ $((now - since)) -ge "$STABLE_FOR" ]; then
    echo "preboot: $UDID booted, SpringBoard $pid stable for ${STABLE_FOR}s"
    exit 0
  fi
  if [ $((now - start)) -ge "$TIMEOUT" ]; then
    echo "preboot: SpringBoard not stable after ${TIMEOUT}s on $UDID — stop"
    exit 1
  fi
done
