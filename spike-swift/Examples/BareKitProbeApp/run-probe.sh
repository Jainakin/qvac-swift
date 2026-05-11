#!/usr/bin/env bash
# run-probe.sh — build the iOS app, install it on a booted simulator, launch it,
# wait for result.json, then exit 0 on PASS, 1 on FAIL.
# Designed to run in CI (or locally) as a single command.
#
# Usage:
#   ./run-probe.sh                        # default sim: iPhone 17, deriveddata in /tmp/bkp-dd
#   SIM_NAME='iPhone 17 Pro' ./run-probe.sh
#   DERIVED_DATA=/path/to/dd ./run-probe.sh

set -euo pipefail

SIM_NAME="${SIM_NAME:-iPhone 17}"
DERIVED_DATA="${DERIVED_DATA:-/tmp/bkp-dd}"
BUNDLE_ID="com.qvac.spike.barekitprobe"
TIMEOUT_S="${TIMEOUT_S:-30}"

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$SCRIPT_DIR"

log() { echo "[run-probe] $*"; }

log "Regenerating Xcode project via xcodegen"
xcodegen generate >/dev/null

log "Building app for '$SIM_NAME' simulator"
xcodebuild \
  -project BareKitProbeApp.xcodeproj \
  -scheme BareKitProbeApp \
  -destination "platform=iOS Simulator,name=$SIM_NAME" \
  -derivedDataPath "$DERIVED_DATA" \
  -configuration Debug \
  build > /tmp/build.log 2>&1 || {
    log "Build failed. Tail of build log:"
    tail -40 /tmp/build.log
    exit 2
}

APP_PATH="$DERIVED_DATA/Build/Products/Debug-iphonesimulator/BareKitProbeApp.app"
[ -d "$APP_PATH" ] || { log "Built app not found at $APP_PATH"; exit 2; }

log "Booting simulator (idempotent)"
xcrun simctl boot "$SIM_NAME" 2>/dev/null || true
sleep 2

log "Uninstalling any prior copy"
xcrun simctl uninstall booted "$BUNDLE_ID" 2>/dev/null || true

log "Installing app"
xcrun simctl install booted "$APP_PATH"

log "Launching app"
xcrun simctl launch booted "$BUNDLE_ID"

log "Waiting up to ${TIMEOUT_S}s for result.json"
CONTAINER=""
RESULT=""
for i in $(seq 1 "$TIMEOUT_S"); do
    CONTAINER=$(xcrun simctl get_app_container booted "$BUNDLE_ID" data 2>/dev/null || true)
    if [ -n "$CONTAINER" ] && [ -f "$CONTAINER/Documents/result.json" ]; then
        RESULT="$CONTAINER/Documents/result.json"
        break
    fi
    sleep 1
done

if [ -z "$RESULT" ]; then
    log "Timed out waiting for result.json"
    exit 3
fi

log "Probe result:"
cat "$RESULT"
echo

PASSED=$(python3 -c "import json,sys; print(json.load(open('$RESULT')).get('passed'))")
SUMMARY=$(python3 -c "import json,sys; print(json.load(open('$RESULT')).get('summary'))")
if [ "$PASSED" = "True" ]; then
    log "✅ PROBE PASSED — $SUMMARY"
    exit 0
else
    log "❌ PROBE FAILED — $SUMMARY"
    exit 1
fi
