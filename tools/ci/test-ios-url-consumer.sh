#!/usr/bin/env bash

set -euo pipefail

PACKAGE_URL="${1:-}"
REFERENCE_KIND="${2:-}"
REVISION="${3:-}"
SIMULATOR_UDID="${4:-}"
RESULT_BUNDLE="${5:-}"

usage() {
    echo "usage: $0 <https://github.com/owner/repo.git> --revision <sha> <simulator-udid> <absolute.xcresult>" >&2
    exit 2
}

if [[ ! "$PACKAGE_URL" =~ ^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\.git$ ]]; then
    usage
fi
if [[ "$REFERENCE_KIND" != "--revision" || ! "$REVISION" =~ ^[0-9a-f]{40}$ ]]; then
    usage
fi
if [[ ! "$SIMULATOR_UDID" =~ ^[0-9A-Fa-f-]{36}$ ]]; then
    usage
fi
if [[ "$RESULT_BUNDLE" != /* || "$RESULT_BUNDLE" != *.xcresult ]]; then
    usage
fi
LOG_PATH="${RESULT_BUNDLE%.xcresult}.log"
if [[ -e "$RESULT_BUNDLE" ]]; then
    echo "[ios-url-consumer] result bundle already exists: $RESULT_BUNDLE" >&2
    exit 2
fi
if [[ -e "$LOG_PATH" ]]; then
    echo "[ios-url-consumer] log already exists: $LOG_PATH" >&2
    exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
FIXTURE="$SCRIPT_DIR/external-ios-consumer"
WORK_DIR="$(mktemp -d)"
SOURCE_PACKAGES="$WORK_DIR/SourcePackages"
DERIVED_DATA="$WORK_DIR/DerivedData"
PACKAGE_BASENAME="${PACKAGE_URL##*/}"
PACKAGE_IDENTITY="$(printf '%s' "${PACKAGE_BASENAME%.git}" | tr '[:upper:]' '[:lower:]')"
trap 'rm -rf "$WORK_DIR"' EXIT

mkdir -p "$WORK_DIR/Tests/QVACiOSURLSmokeTests" "$(dirname "$RESULT_BUNDLE")"
: > "$LOG_PATH"

record() {
    printf '[ios-url-consumer] %s\n' "$*" | tee -a "$LOG_PATH"
}

record "requested-url=$PACKAGE_URL"
record "requested-revision=$REVISION"
sed \
    -e "s|__QVAC_PACKAGE_URL__|$PACKAGE_URL|g" \
    -e "s|__QVAC_PACKAGE_REVISION__|$REVISION|g" \
    -e "s|__QVAC_PACKAGE_ID__|$PACKAGE_IDENTITY|g" \
    "$FIXTURE/Package.swift.template" > "$WORK_DIR/Package.swift"
cp "$REPOSITORY_ROOT/Tests/QVACiOSSmokeHarness/Tests/QVACiOSSmokeTests/QVACiOSSmokeTests.swift" \
    "$WORK_DIR/Tests/QVACiOSURLSmokeTests/QVACiOSSmokeTests.swift"

# xcodebuild discovers a standalone Swift package from its current directory.
# Bind every package operation to the isolated consumer rather than whichever
# repository happened to invoke this script.
cd "$WORK_DIR"
swift package dump-package >/dev/null

record "resolving an uncached public package revision"
GIT_TERMINAL_PROMPT=0 \
GIT_CONFIG_COUNT=1 \
GIT_CONFIG_KEY_0=credential.helper \
GIT_CONFIG_VALUE_0= \
xcodebuild -resolvePackageDependencies \
    -scheme QVACiOSURLConsumer-Package \
    -clonedSourcePackagesDirPath "$SOURCE_PACKAGES" \
    -derivedDataPath "$DERIVED_DATA" \
    -disablePackageRepositoryCache 2>&1 | tee -a "$LOG_PATH"

CHECKOUT_COUNT="$(find "$SOURCE_PACKAGES/checkouts" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')"
if [[ "$CHECKOUT_COUNT" != "1" ]]; then
    echo "[ios-url-consumer] expected one source checkout, found $CHECKOUT_COUNT" >&2
    exit 1
fi
CHECKOUT="$(find "$SOURCE_PACKAGES/checkouts" -mindepth 1 -maxdepth 1 -type d -print -quit)"
RESOLVED_REVISION="$(git -C "$CHECKOUT" rev-parse HEAD)"
if [[ "$RESOLVED_REVISION" != "$REVISION" ]]; then
    echo "[ios-url-consumer] resolved $RESOLVED_REVISION, expected $REVISION" >&2
    exit 1
fi
RESOLVED_ORIGIN="$(git -C "$CHECKOUT" remote get-url origin)"
if [[ "$RESOLVED_ORIGIN" == "$SOURCE_PACKAGES"/repositories/* ]]; then
    # Xcode clones a local working checkout from its bare repository cache. The
    # cache retains the actual package URL, so provenance is a deliberate
    # two-hop check rather than an assumption about checkout remote layout.
    RESOLVED_ORIGIN="$(git -C "$RESOLVED_ORIGIN" remote get-url origin)"
fi
if [[ "$RESOLVED_ORIGIN" != "$PACKAGE_URL" ]]; then
    echo "[ios-url-consumer] resolved origin $RESOLVED_ORIGIN, expected $PACKAGE_URL" >&2
    exit 1
fi
record "resolved-revision=$RESOLVED_REVISION"
record "resolved-origin=$RESOLVED_ORIGIN"

MANIFEST_MODE="$(node "$CHECKOUT/tools/ci/package-manifest-mode.mjs" --check)"
if [[ "$MANIFEST_MODE" != *"canonical mode=release tag="* ]]; then
    echo "[ios-url-consumer] public revision is not in canonical release-manifest mode" >&2
    echo "$MANIFEST_MODE" >&2
    exit 1
fi
record "$MANIFEST_MODE"

EXPECTED_TARGETS="$WORK_DIR/expected-targets.txt"
RESOLVED_TARGETS="$WORK_DIR/resolved-targets.txt"
jq -r '.targets[]' "$CHECKOUT/tools/release/artifacts.development.json" | sort -u > "$EXPECTED_TARGETS"
find "$SOURCE_PACKAGES/artifacts" -type d -name '*.xcframework' -prune \
    -exec basename {} .xcframework \; | sort -u > "$RESOLVED_TARGETS"
if [[ "$(wc -l < "$EXPECTED_TARGETS" | tr -d ' ')" != "38" ]]; then
    echo "[ios-url-consumer] pinned closure must contain exactly 38 binary targets" >&2
    exit 1
fi
if ! diff -u "$EXPECTED_TARGETS" "$RESOLVED_TARGETS"; then
    echo "[ios-url-consumer] resolved XCFramework closure differs from the pinned 0.17 graph" >&2
    exit 1
fi
record "resolved-binary-targets=38"

record "running __init_config + heartbeat on simulator=$SIMULATOR_UDID"
xcodebuild \
    -scheme QVACiOSURLConsumer-Package \
    -destination "platform=iOS Simulator,id=$SIMULATOR_UDID" \
    -destination-timeout 180 \
    -clonedSourcePackagesDirPath "$SOURCE_PACKAGES" \
    -derivedDataPath "$DERIVED_DATA" \
    -disableAutomaticPackageResolution \
    -parallel-testing-enabled NO \
    -only-testing:QVACiOSURLSmokeTests/QVACiOSSmokeTests/testBundledWorkerHandshakeHeartbeatAndIdempotentClose \
    -resultBundlePath "$RESULT_BUNDLE" \
    test 2>&1 | tee -a "$LOG_PATH"

"$REPOSITORY_ROOT/tools/ci/assert-ios-smoke-log.sh" \
    "$LOG_PATH" \
    QVACiOSURLSmokeTests | tee -a "$LOG_PATH"

record "exact revision, 38 remote binaries, worker handshake, heartbeat, and close verified"
