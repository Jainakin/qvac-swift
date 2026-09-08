#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPOSITORY_ROOT="$(cd -P "$SCRIPT_DIR/../.." && pwd -P)"
VERIFIER="$SCRIPT_DIR/verify-ios-physical-lifecycle-evidence.mjs"
BUILD_INPUT_VERIFIER="$SCRIPT_DIR/verify-ios-build-inputs.mjs"
BARE_KIT_VERIFIER="$REPOSITORY_ROOT/tools/native/bare-kit/verify.mjs"
ARTIFACT_MANIFEST="$REPOSITORY_ROOT/tools/release/artifacts.development.json"
STAGED_ARTIFACTS="$REPOSITORY_ROOT/tools/runtime/.build/artifacts"
INVENTORY="$SCRIPT_DIR/ios-physical-lifecycle-test-inventory.txt"
REQUIRED_XCODEGEN_VERSION="2.46.0"

usage() {
    cat >&2 <<'USAGE'
usage:
  run-ios-physical-lifecycle.sh \
    --source-sha <full-lowercase-commit> \
    --destination 'platform=iOS,id=<physical-device-UDID>' \
    --candidate /absolute/BareKit.xcframework \
    --evidence-dir /absolute/new-directory \
    --development-team <10-character-team-id> \
    [--allow-provisioning-updates] \
    [--allow-provisioning-device-registration]

  run-ios-physical-lifecycle.sh --self-test
USAGE
    exit 2
}

fail() {
    echo "[ios-physical-lifecycle] $*" >&2
    exit 1
}

WORK_ROOT=""
RUN_COMPLETED=false
cleanup() {
    local command_status="$?"
    local cleanup_status=0
    trap - EXIT
    if [[ -n "$WORK_ROOT" ]]; then
        rm -rf "$WORK_ROOT" || cleanup_status=$?
    fi
    if (( command_status != 0 )); then
        exit "$command_status"
    fi
    if (( cleanup_status != 0 )); then
        exit "$cleanup_status"
    fi
    if [[ "$RUN_COMPLETED" != true ]]; then
        # Apple Bash 3.2 may enter EXIT with status zero after an unset empty
        # array expansion. Only this script's explicit success marker may pass.
        exit 1
    fi
    exit 0
}

if [[ "${1:-}" == "--internal-self-test-nounset-cleanup" ]]; then
    [[ "$#" -eq 1 ]] || exit 2
    if ! WORK_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/qvac-physical-cleanup-test.XXXXXX")"; then
        exit 3
    fi
    if [[ ! -d "$WORK_ROOT" || -L "$WORK_ROOT" ]]; then
        exit 3
    fi
    trap cleanup EXIT
    : > "$WORK_ROOT/.qvac-physical-cleanup-test"
    if [[ ! -f "$WORK_ROOT/.qvac-physical-cleanup-test" ||
          -L "$WORK_ROOT/.qvac-physical-cleanup-test" ]]; then
        exit 3
    fi
    printf 'QVAC_PHYSICAL_CLEANUP_ARMED=%s\n' "$WORK_ROOT"
    SELF_TEST_EMPTY_OPTIONS=()
    SELF_TEST_COMMAND=("${SELF_TEST_EMPTY_OPTIONS[@]}")
    exit 0
fi

if [[ "${1:-}" == "--self-test" ]]; then
    [[ "$#" -eq 1 ]] || usage
    node "$VERIFIER" --self-test
    node "$BUILD_INPUT_VERIFIER" --self-test
    bash -n "$0"
    if ! WORK_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/qvac-physical-self-test.XXXXXX")"; then
        fail "could not create cleanup self-test parent"
    fi
    [[ -d "$WORK_ROOT" && ! -L "$WORK_ROOT" ]] \
        || fail "cleanup self-test parent must be a real directory"
    trap cleanup EXIT
    CLEANUP_SELF_TEST_PREFIX="QVAC_PHYSICAL_CLEANUP_ARMED="
    set +e
    CLEANUP_SELF_TEST_OUTPUT="$(
        TMPDIR="$WORK_ROOT" \
            /bin/bash "$0" --internal-self-test-nounset-cleanup 2>/dev/null
    )"
    CLEANUP_SELF_TEST_STATUS=$?
    set -e
    [[ "$CLEANUP_SELF_TEST_STATUS" -eq 1 ]] \
        || fail "cleanup must fail closed after a Bash nounset expansion abort"
    case "$CLEANUP_SELF_TEST_OUTPUT" in
        "$CLEANUP_SELF_TEST_PREFIX"*) ;;
        *) fail "cleanup subprocess did not reach the armed nounset test point" ;;
    esac
    CLEANUP_SELF_TEST_PATH="${CLEANUP_SELF_TEST_OUTPUT#"$CLEANUP_SELF_TEST_PREFIX"}"
    case "$CLEANUP_SELF_TEST_PATH" in
        "$WORK_ROOT"/qvac-physical-cleanup-test.*) ;;
        *) fail "cleanup subprocess reported an unexpected test directory" ;;
    esac
    if [[ "$CLEANUP_SELF_TEST_PATH" == *$'\n'* ||
          -e "$CLEANUP_SELF_TEST_PATH" || -L "$CLEANUP_SELF_TEST_PATH" ]]; then
        fail "cleanup subprocess did not remove its armed test directory"
    fi
    EMPTY_OPTIONS=()
    EMPTY_OPTION_COUNT=0
    TEST_COMMAND=(xcodebuild)
    if (( EMPTY_OPTION_COUNT > 0 )); then
        TEST_COMMAND+=("${EMPTY_OPTIONS[@]}")
    fi
    TEST_COMMAND+=(test)
    [[ "${TEST_COMMAND[*]}" == "xcodebuild test" ]] \
        || fail "empty optional xcodebuild flags were not handled safely"
    INVALID_CANDIDATE="$WORK_ROOT/BareKit.xcframework"
    mkdir "$INVALID_CANDIDATE"
    set +e
    INVALID_REGISTRATION_OUTPUT="$(
        /bin/bash "$0" \
            --source-sha 0000000000000000000000000000000000000000 \
            --destination 'platform=iOS,id=00008130-0000000000000000' \
            --candidate "$INVALID_CANDIDATE" \
            --evidence-dir "$WORK_ROOT/invalid-registration-evidence" \
            --development-team ABCDE12345 \
            --allow-provisioning-device-registration 2>&1
    )"
    INVALID_REGISTRATION_STATUS=$?
    set -e
    [[ "$INVALID_REGISTRATION_STATUS" -eq 1 \
        && "$INVALID_REGISTRATION_OUTPUT" == \
            "[ios-physical-lifecycle] --allow-provisioning-device-registration requires --allow-provisioning-updates" ]] \
        || fail "device-registration dependency did not fail before build setup"
    [[ "$(node -e '
      const value = JSON.parse(require("node:fs").readFileSync(process.argv[1], "utf8"))
      if (!Array.isArray(value.targets) || new Set(value.targets).size !== 38) process.exit(2)
      process.stdout.write(String(value.targets.length))
    ' "$ARTIFACT_MANIFEST")" == "38" ]] \
        || fail "development artifact closure must contain 38 unique targets"
    echo "[ios-physical-lifecycle-self-test] fail-closed argument, evidence, and cleanup gates verified"
    RUN_COMPLETED=true
    exit 0
fi

SOURCE_SHA=""
DESTINATION=""
CANDIDATE=""
EVIDENCE=""
DEVELOPMENT_TEAM=""
ALLOW_PROVISIONING_UPDATES=false
ALLOW_DEVICE_REGISTRATION=false

while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --source-sha|--destination|--candidate|--evidence-dir|--development-team)
            [[ "$#" -ge 2 && -n "$2" ]] || usage
            case "$1" in
                --source-sha) SOURCE_SHA="$2" ;;
                --destination) DESTINATION="$2" ;;
                --candidate) CANDIDATE="$2" ;;
                --evidence-dir) EVIDENCE="$2" ;;
                --development-team) DEVELOPMENT_TEAM="$2" ;;
            esac
            shift 2
            ;;
        --allow-provisioning-updates)
            [[ "$ALLOW_PROVISIONING_UPDATES" == false ]] || usage
            ALLOW_PROVISIONING_UPDATES=true
            shift
            ;;
        --allow-provisioning-device-registration)
            [[ "$ALLOW_DEVICE_REGISTRATION" == false ]] || usage
            ALLOW_DEVICE_REGISTRATION=true
            shift
            ;;
        *)
            usage
            ;;
    esac
done

[[ "$SOURCE_SHA" =~ ^[0-9a-f]{40}$ ]] || usage
[[ "$DESTINATION" =~ ^platform=iOS,id=[A-Za-z0-9-]{8,64}$ ]] || usage
[[ "$DEVELOPMENT_TEAM" =~ ^[A-Z0-9]{10}$ ]] || usage
[[ "$CANDIDATE" == /* && "$EVIDENCE" == /* ]] || usage
if [[ "$ALLOW_DEVICE_REGISTRATION" == true && "$ALLOW_PROVISIONING_UPDATES" != true ]]; then
    fail "--allow-provisioning-device-registration requires --allow-provisioning-updates"
fi
DEVICE_ID="${DESTINATION#platform=iOS,id=}"

[[ -d "$CANDIDATE" && ! -L "$CANDIDATE" ]] \
    || fail "candidate must be an existing, non-symlinked absolute directory"
CANDIDATE="$(cd -P "$CANDIDATE" && pwd -P)"
[[ "$(basename "$CANDIDATE")" == "BareKit.xcframework" ]] \
    || fail "candidate must be named BareKit.xcframework"

[[ ! -e "$EVIDENCE" && ! -L "$EVIDENCE" ]] \
    || fail "evidence directory must be a fresh path that does not exist"
EVIDENCE_PARENT="$(dirname "$EVIDENCE")"
EVIDENCE_NAME="$(basename "$EVIDENCE")"
[[ "$EVIDENCE_NAME" != "." && "$EVIDENCE_NAME" != ".." ]] || usage
[[ -d "$EVIDENCE_PARENT" && ! -L "$EVIDENCE_PARENT" ]] \
    || fail "evidence parent must be an existing, non-symlinked directory"
EVIDENCE_PARENT="$(cd -P "$EVIDENCE_PARENT" && pwd -P)"
EVIDENCE="$EVIDENCE_PARENT/$EVIDENCE_NAME"
case "$EVIDENCE/" in
    "$REPOSITORY_ROOT/"*) fail "evidence directory must be outside the source repository" ;;
esac
mkdir "$EVIDENCE"
EVIDENCE="$(cd -P "$EVIDENCE" && pwd -P)"

REPOSITORY_HEAD="$(git -C "$REPOSITORY_ROOT" rev-parse --verify HEAD)"
[[ "$SOURCE_SHA" == "$REPOSITORY_HEAD" ]] \
    || fail "requested source commit differs from repository HEAD"
SOURCE_STATUS="$(git -C "$REPOSITORY_ROOT" status --porcelain --untracked-files=all)"
[[ -z "$SOURCE_STATUS" ]] || {
    echo "$SOURCE_STATUS" >&2
    fail "final physical evidence requires a clean checkout"
}

XCODEGEN="${QVAC_XCODEGEN:-}"
if [[ -z "$XCODEGEN" ]]; then
    XCODEGEN="$(command -v xcodegen || true)"
fi
[[ -n "$XCODEGEN" && -x "$XCODEGEN" ]] || fail "set QVAC_XCODEGEN to pinned XcodeGen"
[[ "$("$XCODEGEN" --version)" == "Version: $REQUIRED_XCODEGEN_VERSION" ]] \
    || fail "XcodeGen $REQUIRED_XCODEGEN_VERSION is required"
for COMMAND in node swift xcodebuild xcrun ditto tar diff; do
    command -v "$COMMAND" >/dev/null || fail "$COMMAND is required"
done

[[ -d "$STAGED_ARTIFACTS" && ! -L "$STAGED_ARTIFACTS" ]] \
    || fail "run tools/runtime/link-ios-artifacts.sh before physical lifecycle validation"
node "$BUILD_INPUT_VERIFIER" \
    --artifact-root "$STAGED_ARTIFACTS" \
    --allow-unreferenced-root-entries
TARGETS="$(node -e '
  const value = JSON.parse(require("node:fs").readFileSync(process.argv[1], "utf8"))
  if (!Array.isArray(value.targets) || value.targets.length !== 38
      || new Set(value.targets).size !== value.targets.length
      || value.targets.some(target => !/^[A-Za-z0-9_.-]+$/.test(target))) process.exit(2)
  process.stdout.write(value.targets.join("\n"))
' "$ARTIFACT_MANIFEST")" || fail "development artifact manifest is invalid"
TARGET_COUNT=0
while IFS= read -r TARGET; do
    [[ -n "$TARGET" ]] || continue
    TARGET_COUNT=$((TARGET_COUNT + 1))
    ARTIFACT="$STAGED_ARTIFACTS/$TARGET.xcframework"
    [[ -d "$ARTIFACT" && ! -L "$ARTIFACT" ]] \
        || fail "staged artifact closure is missing $TARGET.xcframework"
done <<< "$TARGETS"
[[ "$TARGET_COUNT" -eq 38 ]] || fail "development artifact closure must contain 38 targets"

LOCK_STATE="$EVIDENCE/device-lock-state.json"
[[ ! -e "$LOCK_STATE" ]] || fail "device lock-state evidence unexpectedly exists"
xcrun devicectl device info lockState \
    --device "$DEVICE_ID" \
    --json-output "$LOCK_STATE" \
    --quiet
node "$VERIFIER" \
    --validate-lock-state "$LOCK_STATE" \
    --device-id "$DEVICE_ID" \
    2>&1 | tee "$EVIDENCE/device-lock-state-verification.log"

echo "[ios-physical-lifecycle] non-publishing validation source=$SOURCE_SHA device=$DEVICE_ID" \
    | tee "$EVIDENCE/run-metadata.log"
CANDIDATE_LOG="$EVIDENCE/candidate-verification.log"
node "$BARE_KIT_VERIFIER" --artifact "$CANDIDATE" \
    2>&1 | tee "$CANDIDATE_LOG"

WORK_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/qvac-physical-lifecycle.XXXXXX")"
trap cleanup EXIT
SOURCE_COPY="$WORK_ROOT/qvac-swift"
DERIVED_DATA="$WORK_ROOT/DerivedData"
SOURCE_ARCHIVE="$EVIDENCE/source.tar"
mkdir "$SOURCE_COPY"
git -C "$REPOSITORY_ROOT" archive --format=tar --output="$SOURCE_ARCHIVE" "$SOURCE_SHA"
tar -xf "$SOURCE_ARCHIVE" -C "$SOURCE_COPY"
SOURCE_COPY="$(cd -P "$SOURCE_COPY" && pwd -P)"

mkdir -p "$SOURCE_COPY/tools/runtime/.build/artifacts"
while IFS= read -r TARGET; do
    [[ -n "$TARGET" && "$TARGET" != "BareKit" ]] || continue
    ditto \
        "$STAGED_ARTIFACTS/$TARGET.xcframework" \
        "$SOURCE_COPY/tools/runtime/.build/artifacts/$TARGET.xcframework"
done <<< "$TARGETS"
TEMP_BARE_KIT="$SOURCE_COPY/tools/runtime/.build/artifacts/BareKit.xcframework"
[[ "$TEMP_BARE_KIT" == "$WORK_ROOT/"* ]] \
    || fail "internal BareKit destination escaped the disposable work root"
rm -rf "$TEMP_BARE_KIT"
ditto "$CANDIDATE" "$TEMP_BARE_KIT"
diff --recursive --brief "$CANDIDATE" "$TEMP_BARE_KIT" >/dev/null \
    || fail "isolated BareKit copy differs from selected candidate"
cp "$SOURCE_COPY/Package.swift.dev" "$SOURCE_COPY/Package.swift"
(
    cd "$SOURCE_COPY"
    swift package dump-package >/dev/null
)
SWIFTPM_STATE="$SOURCE_COPY/.swiftpm"
[[ "$SWIFTPM_STATE" == "$WORK_ROOT/"* ]] \
    || fail "internal SwiftPM state path escaped the disposable work root"
rm -rf "$SWIFTPM_STATE"
[[ ! -e "$SWIFTPM_STATE" && ! -L "$SWIFTPM_STATE" ]] \
    || fail "could not remove generated SwiftPM source-tree state"
(
    cd "$SOURCE_COPY/Examples/QVACChat"
    "$XCODEGEN" generate
)
node "$BUILD_INPUT_VERIFIER" \
    --source-archive "$SOURCE_ARCHIVE" \
    --source-root "$SOURCE_COPY" \
    --source-sha "$SOURCE_SHA" \
    --xcodegen "$XCODEGEN"

TEST_IDENTITY="$(sed -n '1p' "$INVENTORY")"
[[ "$TEST_IDENTITY" == "QVACChatPhysicalDeviceTests/testLoadStreamAndUnloadOnPhysicalDevice" \
    && "$(wc -l < "$INVENTORY" | tr -d ' ')" == "1" ]] \
    || fail "physical lifecycle test inventory is not the reviewed singleton"
PROJECT="$SOURCE_COPY/Examples/QVACChat/QVACChat.xcodeproj"
RESULT_BUNDLE="$EVIDENCE/physical-lifecycle.xcresult"
TEST_LOG="$EVIDENCE/physical-lifecycle-xcodebuild.log"
[[ ! -e "$RESULT_BUNDLE" && ! -e "$TEST_LOG" ]] \
    || fail "physical lifecycle evidence outputs unexpectedly exist"

SIGNING_OPTIONS=()
SIGNING_OPTION_COUNT=0
if [[ "$ALLOW_PROVISIONING_UPDATES" == true ]]; then
    SIGNING_OPTIONS+=("-allowProvisioningUpdates")
    SIGNING_OPTION_COUNT=$((SIGNING_OPTION_COUNT + 1))
fi
if [[ "$ALLOW_DEVICE_REGISTRATION" == true ]]; then
    SIGNING_OPTIONS+=("-allowProvisioningDeviceRegistration")
    SIGNING_OPTION_COUNT=$((SIGNING_OPTION_COUNT + 1))
fi

XCODEBUILD=(
    xcodebuild
    -project "$PROJECT"
    -scheme QVACChat-PhysicalDevice
    -destination "$DESTINATION"
    -destination-timeout 180
    -derivedDataPath "$DERIVED_DATA"
    -parallel-testing-enabled NO
    -maximum-concurrent-test-device-destinations 1
    -resultBundlePath "$RESULT_BUNDLE"
    "-only-testing:QVACChatPhysicalDeviceTests/$TEST_IDENTITY"
    CODE_SIGN_STYLE=Automatic
    "DEVELOPMENT_TEAM=$DEVELOPMENT_TEAM"
    SWIFT_SUPPRESS_WARNINGS=NO
    SWIFT_TREAT_WARNINGS_AS_ERRORS=YES
    OTHER_SWIFT_FLAGS=-strict-concurrency=complete
)
if (( SIGNING_OPTION_COUNT > 0 )); then
    XCODEBUILD+=("${SIGNING_OPTIONS[@]}")
fi
XCODEBUILD+=(test)
"${XCODEBUILD[@]}" 2>&1 | tee "$TEST_LOG"

# Xcode resolves the local package during the build and recreates `.swiftpm`
# inside the isolated source archive. It is build state, not source input; remove
# only this already-validated path before the post-build source attestation.
rm -rf "$SWIFTPM_STATE"
[[ ! -e "$SWIFTPM_STATE" && ! -L "$SWIFTPM_STATE" ]] \
    || fail "could not remove post-build SwiftPM source-tree state"

diff --recursive --brief "$CANDIDATE" "$TEMP_BARE_KIT" >/dev/null \
    || fail "selected BareKit candidate changed during physical lifecycle validation"
node "$VERIFIER" \
    --xcresult "$RESULT_BUNDLE" \
    --log "$TEST_LOG" \
    --derived-data "$DERIVED_DATA" \
    --candidate "$CANDIDATE" \
    --candidate-log "$CANDIDATE_LOG" \
    --source-archive "$SOURCE_ARCHIVE" \
    --source-root "$SOURCE_COPY" \
    --source-sha "$SOURCE_SHA" \
    --device-id "$DEVICE_ID" \
    --device-lock-state "$LOCK_STATE" \
    --development-team "$DEVELOPMENT_TEAM" \
    --allow-provisioning-updates "$ALLOW_PROVISIONING_UPDATES" \
    --allow-provisioning-device-registration "$ALLOW_DEVICE_REGISTRATION" \
    --xcodegen "$XCODEGEN" \
    --output "$EVIDENCE/physical-lifecycle-evidence.json"

FINAL_HEAD="$(git -C "$REPOSITORY_ROOT" rev-parse --verify HEAD)"
FINAL_STATUS="$(git -C "$REPOSITORY_ROOT" status --porcelain --untracked-files=all)"
[[ "$FINAL_HEAD" == "$SOURCE_SHA" && -z "$FINAL_STATUS" ]] \
    || fail "source checkout changed during physical lifecycle validation"
echo "[ios-physical-lifecycle] PASS evidence=$EVIDENCE/physical-lifecycle-evidence.json"
RUN_COMPLETED=true
