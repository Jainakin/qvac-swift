#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPOSITORY_ROOT="$(cd -P "$SCRIPT_DIR/../.." && pwd -P)"
VERIFIER="$SCRIPT_DIR/verify-ios-native-stress-evidence.mjs"
BUILD_INPUT_VERIFIER="$SCRIPT_DIR/verify-ios-build-inputs.mjs"
BARE_KIT_VERIFIER="$REPOSITORY_ROOT/tools/native/bare-kit/verify.mjs"
STAGED_ARTIFACTS="$REPOSITORY_ROOT/tools/runtime/.build/artifacts"
REQUIRED_XCODEGEN_VERSION="2.46.0"

usage() {
    cat >&2 <<'USAGE'
usage:
  run-ios-native-stress.sh \
    --mode regular \
    --platform <simulator|device> \
    --destination 'platform=iOS...,id=...' \
    --candidate /absolute/BareKit.xcframework \
    --evidence-dir /absolute/new-or-empty-directory \
    [--development-team <10-character-team-id>] \
    [--allow-provisioning-updates] \
    [--allow-provisioning-device-registration]

  run-ios-native-stress.sh \
    --mode thread-sanitizer \
    --platform simulator \
    --destination 'platform=iOS Simulator,id=...' \
    --candidate /absolute/BareKit.xcframework \
    --compile-commands /absolute/compile_commands.json \
    --source-root /absolute/patched-native-source \
    --evidence-dir /absolute/new-or-empty-directory

  run-ios-native-stress.sh --self-test
USAGE
    exit 2
}

fail() {
    echo "[ios-native-stress] $*" >&2
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
        # Apple Bash 3.2 enters EXIT with status zero after some expansion
        # failures (including an unset empty-array expansion under `set -u`).
        # Only the explicit success marker may therefore produce a zero exit.
        exit 1
    fi
    exit 0
}

# Private subprocess mode used by --self-test. On Apple Bash 3.2 the empty
# array expansion aborts with an EXIT-trap status of zero; newer Bash versions
# reach the explicit zero exit. Both paths must be converted to failure because
# RUN_COMPLETED was never set.
if [[ "${1:-}" == "--internal-self-test-nounset-cleanup" ]]; then
    [[ "$#" -eq 1 ]] || exit 2
    if ! WORK_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/qvac-native-stress-cleanup-test.XXXXXX")"; then
        exit 3
    fi
    if [[ ! -d "$WORK_ROOT" || -L "$WORK_ROOT" ]]; then
        exit 3
    fi
    trap cleanup EXIT
    : > "$WORK_ROOT/.qvac-native-stress-cleanup-test"
    if [[ ! -f "$WORK_ROOT/.qvac-native-stress-cleanup-test" ||
          -L "$WORK_ROOT/.qvac-native-stress-cleanup-test" ]]; then
        exit 3
    fi
    printf 'QVAC_NATIVE_STRESS_CLEANUP_ARMED=%s\n' "$WORK_ROOT"
    SELF_TEST_EMPTY_OPTIONS=()
    SELF_TEST_COMMAND=("${SELF_TEST_EMPTY_OPTIONS[@]}")
    exit 0
fi

if [[ "${1:-}" == "--self-test" ]]; then
    [[ "$#" -eq 1 ]] || usage
    node "$VERIFIER" --self-test
    node "$BUILD_INPUT_VERIFIER" --self-test
    bash -n "$0"
    if ! WORK_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/qvac-native-stress-self-test.XXXXXX")"; then
        fail "could not create cleanup self-test parent"
    fi
    [[ -d "$WORK_ROOT" && ! -L "$WORK_ROOT" ]] \
        || fail "cleanup self-test parent must be a real directory"
    trap cleanup EXIT
    CLEANUP_SELF_TEST_PREFIX="QVAC_NATIVE_STRESS_CLEANUP_ARMED="
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
        "$WORK_ROOT"/qvac-native-stress-cleanup-test.*) ;;
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
        || fail "empty optional signing flags were not handled safely"
    echo "[ios-native-stress-self-test] fixed-argument and cleanup gates verified"
    RUN_COMPLETED=true
    exit 0
fi

MODE=""
PLATFORM=""
DESTINATION=""
CANDIDATE=""
EVIDENCE=""
COMPILE_COMMANDS=""
SOURCE_ROOT=""
DEVELOPMENT_TEAM=""
ALLOW_PROVISIONING_UPDATES=false
ALLOW_DEVICE_REGISTRATION=false

while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --mode|--platform|--destination|--candidate|--evidence-dir|--compile-commands|--source-root|--development-team)
            [[ "$#" -ge 2 && -n "$2" ]] || usage
            case "$1" in
                --mode) MODE="$2" ;;
                --platform) PLATFORM="$2" ;;
                --destination) DESTINATION="$2" ;;
                --candidate) CANDIDATE="$2" ;;
                --evidence-dir) EVIDENCE="$2" ;;
                --compile-commands) COMPILE_COMMANDS="$2" ;;
                --source-root) SOURCE_ROOT="$2" ;;
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

[[ "$MODE" == "regular" || "$MODE" == "thread-sanitizer" ]] || usage
[[ "$PLATFORM" == "simulator" || "$PLATFORM" == "device" ]] || usage
[[ "$CANDIDATE" == /* && "$EVIDENCE" == /* ]] || usage
[[ -d "$CANDIDATE" && ! -L "$CANDIDATE" ]] \
    || fail "candidate must be an existing, non-symlinked absolute directory"
CANDIDATE="$(cd -P "$CANDIDATE" && pwd -P)"
[[ "$(basename "$CANDIDATE")" == "BareKit.xcframework" ]] \
    || fail "candidate must be named BareKit.xcframework"

if [[ "$PLATFORM" == "simulator" ]]; then
    [[ "$DESTINATION" =~ ^platform=iOS\ Simulator,id=[A-Za-z0-9-]{8,64}$ ]] || usage
    [[ -z "$DEVELOPMENT_TEAM" && "$ALLOW_PROVISIONING_UPDATES" == false \
        && "$ALLOW_DEVICE_REGISTRATION" == false ]] \
        || fail "device signing options are not accepted for Simulator evidence"
else
    [[ "$DESTINATION" =~ ^platform=iOS,id=[A-Za-z0-9-]{8,64}$ ]] || usage
    [[ "$DEVELOPMENT_TEAM" =~ ^[A-Z0-9]{10}$ ]] \
        || fail "physical-device evidence requires a 10-character development team"
    if [[ "$ALLOW_DEVICE_REGISTRATION" == true && "$ALLOW_PROVISIONING_UPDATES" != true ]]; then
        fail "device registration requires --allow-provisioning-updates"
    fi
fi
DEVICE_ID="${DESTINATION##*,id=}"
if [[ "$MODE" == "thread-sanitizer" ]]; then
    [[ "$PLATFORM" == "simulator" ]] || fail "Thread Sanitizer is Simulator-only"
    [[ "$COMPILE_COMMANDS" == /* && -f "$COMPILE_COMMANDS" && ! -L "$COMPILE_COMMANDS" ]] \
        || fail "Thread Sanitizer compile_commands.json must be an absolute regular file"
    [[ "$SOURCE_ROOT" == /* && -d "$SOURCE_ROOT" && ! -L "$SOURCE_ROOT" ]] \
        || fail "Thread Sanitizer source root must be an absolute real directory"
    COMPILE_COMMANDS="$(cd -P "$(dirname "$COMPILE_COMMANDS")" && pwd -P)/$(basename "$COMPILE_COMMANDS")"
    SOURCE_ROOT="$(cd -P "$SOURCE_ROOT" && pwd -P)"
else
    [[ -z "$COMPILE_COMMANDS" && -z "$SOURCE_ROOT" ]] \
        || fail "native compile evidence is accepted only in Thread Sanitizer mode"
fi

if [[ -e "$EVIDENCE" ]]; then
    [[ -d "$EVIDENCE" && ! -L "$EVIDENCE" ]] \
        || fail "evidence path must be a real directory"
    EVIDENCE="$(cd -P "$EVIDENCE" && pwd -P)"
    [[ -z "$(find "$EVIDENCE" -mindepth 1 -print -quit)" ]] \
        || fail "evidence directory must be empty"
else
    EVIDENCE_PARENT="$(dirname "$EVIDENCE")"
    EVIDENCE_NAME="$(basename "$EVIDENCE")"
    [[ "$EVIDENCE_NAME" != "." && "$EVIDENCE_NAME" != ".." ]] || usage
    [[ -d "$EVIDENCE_PARENT" && ! -L "$EVIDENCE_PARENT" ]] \
        || fail "evidence parent must be an existing real directory"
    EVIDENCE_PARENT="$(cd -P "$EVIDENCE_PARENT" && pwd -P)"
    EVIDENCE="$EVIDENCE_PARENT/$EVIDENCE_NAME"
    mkdir "$EVIDENCE"
fi
case "$EVIDENCE/" in
    "$REPOSITORY_ROOT/"*) fail "evidence directory must be outside the source repository" ;;
esac

SOURCE_SHA="$(git -C "$REPOSITORY_ROOT" rev-parse --verify HEAD)"
[[ "$SOURCE_SHA" =~ ^[0-9a-f]{40}$ ]] || fail "could not resolve a full source commit"
SOURCE_STATUS="$(git -C "$REPOSITORY_ROOT" status --porcelain --untracked-files=all)"
[[ -z "$SOURCE_STATUS" ]] || {
    echo "$SOURCE_STATUS" >&2
    fail "final evidence requires a clean checkout; dirty runs are calibration-only"
}

XCODEGEN="${QVAC_XCODEGEN:-}"
if [[ -z "$XCODEGEN" ]]; then
    XCODEGEN="$(command -v xcodegen || true)"
fi
[[ -n "$XCODEGEN" && -x "$XCODEGEN" ]] || fail "set QVAC_XCODEGEN to pinned XcodeGen"
[[ "$("$XCODEGEN" --version)" == "Version: $REQUIRED_XCODEGEN_VERSION" ]] \
    || fail "XcodeGen $REQUIRED_XCODEGEN_VERSION is required"
command -v xcodebuild >/dev/null || fail "xcodebuild is required"
command -v xcrun >/dev/null || fail "xcrun is required"

[[ -d "$STAGED_ARTIFACTS" && ! -L "$STAGED_ARTIFACTS" ]] \
    || fail "run tools/runtime/link-ios-artifacts.sh before native stress validation"
node "$BUILD_INPUT_VERIFIER" \
    --artifact-root "$STAGED_ARTIFACTS" \
    --allow-unreferenced-root-entries
EXPECTED_TARGET_COUNT="$(
    node -e '
      const value = JSON.parse(require("node:fs").readFileSync(process.argv[1], "utf8"))
      if (!Array.isArray(value.targets)) process.exit(2)
      process.stdout.write(String(value.targets.length))
    ' "$REPOSITORY_ROOT/tools/release/artifacts.development.json"
)"
[[ "$EXPECTED_TARGET_COUNT" == "38" ]] || fail "development artifact closure must contain 38 targets"
while IFS= read -r TARGET; do
    ARTIFACT="$STAGED_ARTIFACTS/$TARGET.xcframework"
    [[ -d "$ARTIFACT" && ! -L "$ARTIFACT" ]] \
        || fail "staged artifact closure is missing $TARGET.xcframework"
done < <(
    node -e '
      const value = JSON.parse(require("node:fs").readFileSync(process.argv[1], "utf8"))
      for (const target of value.targets) process.stdout.write(target + "\n")
    ' "$REPOSITORY_ROOT/tools/release/artifacts.development.json"
)

echo "[ios-native-stress] non-publishing validation source=$SOURCE_SHA mode=$MODE platform=$PLATFORM" \
    | tee "$EVIDENCE/run-metadata.log"
if [[ "$MODE" == "regular" ]]; then
    node "$BARE_KIT_VERIFIER" --artifact "$CANDIDATE" \
        2>&1 | tee "$EVIDENCE/candidate-verification.log"
else
    node "$BARE_KIT_VERIFIER" \
        --thread-sanitizer-artifact "$CANDIDATE" \
        --compile-commands "$COMPILE_COMMANDS" \
        --source-root "$SOURCE_ROOT" \
        2>&1 | tee "$EVIDENCE/candidate-verification.log"
fi

WORK_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/qvac-native-stress.XXXXXX")"
trap cleanup EXIT
WORK_ROOT="$(cd -P "$WORK_ROOT" && pwd -P)"
SOURCE_COPY="$WORK_ROOT/source"
DERIVED_DATA="$WORK_ROOT/DerivedData"
SOURCE_ARCHIVE="$EVIDENCE/source.tar"
mkdir "$SOURCE_COPY"
git -C "$REPOSITORY_ROOT" archive --format=tar --output="$SOURCE_ARCHIVE" "$SOURCE_SHA"
tar -xf "$SOURCE_ARCHIVE" -C "$SOURCE_COPY"

mkdir -p "$SOURCE_COPY/tools/runtime/.build/artifacts"
while IFS= read -r TARGET; do
    [[ -n "$TARGET" && "$TARGET" != "BareKit" ]] || continue
    ditto \
        "$STAGED_ARTIFACTS/$TARGET.xcframework" \
        "$SOURCE_COPY/tools/runtime/.build/artifacts/$TARGET.xcframework"
done < <(
    node -e '
      const value = JSON.parse(require("node:fs").readFileSync(process.argv[1], "utf8"))
      for (const target of value.targets) process.stdout.write(target + "\n")
    ' "$REPOSITORY_ROOT/tools/release/artifacts.development.json"
)
TEMP_BARE_KIT="$SOURCE_COPY/tools/runtime/.build/artifacts/BareKit.xcframework"
[[ "$TEMP_BARE_KIT" == "$WORK_ROOT/"* ]] || fail "internal BareKit destination escaped work root"
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
XCODE_WORKSPACE_STATE="$SOURCE_COPY/Examples/QVACChat/QVACChat.xcodeproj/project.xcworkspace/xcshareddata"
[[ "$SWIFTPM_STATE" == "$WORK_ROOT/"* ]] \
    || fail "internal SwiftPM state path escaped work root"
[[ "$XCODE_WORKSPACE_STATE" == "$WORK_ROOT/"* ]] \
    || fail "internal Xcode workspace state path escaped work root"
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

RESULT_BUNDLE="$EVIDENCE/native-stress.xcresult"
TEST_LOG="$EVIDENCE/native-stress-xcodebuild.log"
[[ ! -e "$RESULT_BUNDLE" && ! -e "$TEST_LOG" ]] \
    || fail "evidence outputs unexpectedly exist"

ONLY_TESTING="-only-testing:QVACChatNativeStressTests"
if [[ "$MODE" == "thread-sanitizer" ]]; then
    ONLY_TESTING+="/QVACNativeIPCStressTests/testPatchedNativeIPCBackpressureOrderingAndConcurrentCloseRace"
fi
XCODEBUILD=(
    xcodebuild
    -project "$SOURCE_COPY/Examples/QVACChat/QVACChat.xcodeproj"
    -scheme QVACChat-NativeStress
    -destination "$DESTINATION"
    -destination-timeout 180
    -derivedDataPath "$DERIVED_DATA"
    -parallel-testing-enabled NO
    SWIFT_SUPPRESS_WARNINGS=NO
    SWIFT_TREAT_WARNINGS_AS_ERRORS=YES
    OTHER_SWIFT_FLAGS=-strict-concurrency=complete
    'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) QVAC_NATIVE_STRESS_TESTING'
    -resultBundlePath "$RESULT_BUNDLE"
    "$ONLY_TESTING"
)
if [[ "$PLATFORM" == "simulator" ]]; then
    XCODEBUILD+=(CODE_SIGNING_ALLOWED=NO)
else
    XCODEBUILD+=(CODE_SIGN_STYLE=Automatic "DEVELOPMENT_TEAM=$DEVELOPMENT_TEAM")
    if [[ "$ALLOW_PROVISIONING_UPDATES" == true ]]; then
        XCODEBUILD+=(-allowProvisioningUpdates)
    fi
    if [[ "$ALLOW_DEVICE_REGISTRATION" == true ]]; then
        XCODEBUILD+=(-allowProvisioningDeviceRegistration)
    fi
fi
if [[ "$MODE" == "thread-sanitizer" ]]; then
    XCODEBUILD+=(-enableThreadSanitizer YES)
fi
XCODEBUILD+=(test)

if [[ "$MODE" == "thread-sanitizer" ]]; then
    TSAN_OPTIONS='halt_on_error=1:exitcode=66' "${XCODEBUILD[@]}" 2>&1 | tee "$TEST_LOG"
else
    "${XCODEBUILD[@]}" 2>&1 | tee "$TEST_LOG"
fi

# Xcode resolves the local package during the build and recreates `.swiftpm`
# plus workspace-shared SwiftPM state inside the isolated source archive. These
# exact paths are build outputs, not source inputs; remove only them before the
# post-build source attestation.
rm -rf "$SWIFTPM_STATE"
rm -rf "$XCODE_WORKSPACE_STATE"
[[ ! -e "$SWIFTPM_STATE" && ! -L "$SWIFTPM_STATE" ]] \
    || fail "could not remove post-build SwiftPM source-tree state"
[[ ! -e "$XCODE_WORKSPACE_STATE" && ! -L "$XCODE_WORKSPACE_STATE" ]] \
    || fail "could not remove post-build Xcode workspace state"

node "$VERIFIER" \
    --mode "$MODE" \
    --platform "$PLATFORM" \
    --xcresult "$RESULT_BUNDLE" \
    --log "$TEST_LOG" \
    --derived-data "$DERIVED_DATA" \
    --candidate "$CANDIDATE" \
    --device-id "$DEVICE_ID" \
    --development-team "${DEVELOPMENT_TEAM:-none}" \
    --allow-provisioning-updates "$ALLOW_PROVISIONING_UPDATES" \
    --allow-provisioning-device-registration "$ALLOW_DEVICE_REGISTRATION" \
    --source-archive "$SOURCE_ARCHIVE" \
    --source-root "$SOURCE_COPY" \
    --source-sha "$SOURCE_SHA" \
    --xcodegen "$XCODEGEN" \
    --output "$EVIDENCE/native-stress-evidence.json"

FINAL_STATUS="$(git -C "$REPOSITORY_ROOT" status --porcelain --untracked-files=all)"
[[ -z "$FINAL_STATUS" ]] || fail "source checkout changed during native stress validation"
echo "[ios-native-stress] PASS evidence=$EVIDENCE/native-stress-evidence.json"
RUN_COMPLETED=true
