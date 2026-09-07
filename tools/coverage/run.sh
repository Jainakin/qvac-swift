#!/usr/bin/env bash
# Execute the reviewed XCTest unit inventory with LLVM coverage enabled, then
# gate handwritten production source without conflating generated SDK code.

set -euo pipefail

readonly SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
readonly REPOSITORY_ROOT="$(cd -P "$SCRIPT_DIR/../.." && pwd -P)"
readonly ANALYZER="$SCRIPT_DIR/analyze-coverage.mjs"
readonly POLICY="$SCRIPT_DIR/policy.json"
readonly SCRATCH_ROOT="$REPOSITORY_ROOT/.build"
readonly SCRATCH_PARENT="$SCRATCH_ROOT/coverage-swiftpm"
readonly SCRATCH_MARKER=".qvac-coverage-scratch"
readonly OUTPUT_MARKER=".qvac-coverage-output"
readonly OUTPUT_MARKER_CONTENT="qvac-coverage-output-v1"
readonly SWIFTC_FLAGS=(
    -Xswiftc -warnings-as-errors
    -Xswiftc -strict-concurrency=complete
)
QVAC_COVERAGE_SELF_TEST_DIR=""
QVAC_COVERAGE_SCRATCH_DIR=""

cleanup_self_test() {
    if [[ -n "$QVAC_COVERAGE_SELF_TEST_DIR" ]]; then
        rm -rf -- "$QVAC_COVERAGE_SELF_TEST_DIR"
        QVAC_COVERAGE_SELF_TEST_DIR=""
    fi
}

cleanup_scratch() {
    if [[ -z "$QVAC_COVERAGE_SCRATCH_DIR" ]]; then
        return
    fi
    case "$QVAC_COVERAGE_SCRATCH_DIR/" in
        "$SCRATCH_PARENT/"*) ;;
        *)
            printf '[coverage] refusing to clean unexpected scratch path: %s\n' \
                "$QVAC_COVERAGE_SCRATCH_DIR" >&2
            return
            ;;
    esac
    if [[ ! -d "$QVAC_COVERAGE_SCRATCH_DIR" ||
          -L "$QVAC_COVERAGE_SCRATCH_DIR" ||
          ! -f "$QVAC_COVERAGE_SCRATCH_DIR/$SCRATCH_MARKER" ||
          -L "$QVAC_COVERAGE_SCRATCH_DIR/$SCRATCH_MARKER" ]]; then
        printf '[coverage] refusing to clean unverified scratch path: %s\n' \
            "$QVAC_COVERAGE_SCRATCH_DIR" >&2
        return
    fi
    rm -rf -- "$QVAC_COVERAGE_SCRATCH_DIR"
    QVAC_COVERAGE_SCRATCH_DIR=""
}

cleanup() {
    cleanup_self_test
    cleanup_scratch
}

reject() {
    printf '[coverage] error: %s\n' "$*" >&2
    return 1
}

require_regular_file() {
    local path="$1"
    local label="$2"
    if [[ ! -f "$path" || -L "$path" ]]; then
        reject "$label must be a regular, non-symlink file: $path"
        return 1
    fi
}

prepare_output_directory() {
    local requested="$1"
    local parent basename_value canonical_parent candidate marker_value
    if [[ "$requested" != /* ]]; then
        requested="$REPOSITORY_ROOT/$requested"
    fi
    parent="$(dirname "$requested")"
    basename_value="$(basename "$requested")"
    if [[ "$basename_value" == "." || "$basename_value" == ".." || -z "$basename_value" ||
          ! -d "$parent" || -L "$parent" ]]; then
        reject "coverage output parent must be a real directory and output must name a strict child: $requested"
        return 1
    fi
    canonical_parent="$(cd -P "$parent" && pwd -P)"
    candidate="$canonical_parent/$basename_value"
    case "$candidate/" in
        "$REPOSITORY_ROOT/.build/"*) ;;
        "$REPOSITORY_ROOT/"*)
            reject "repository-local coverage output must be below $REPOSITORY_ROOT/.build"
            return 1
            ;;
    esac
    if [[ -e "$candidate" || -L "$candidate" ]]; then
        if [[ ! -d "$candidate" || -L "$candidate" ]]; then
            reject "coverage output must be a real directory: $candidate"
            return 1
        fi
        require_regular_file "$candidate/$OUTPUT_MARKER" "coverage output ownership marker"
        marker_value="$(<"$candidate/$OUTPUT_MARKER")"
        if [[ "$marker_value" != "$OUTPUT_MARKER_CONTENT" ]]; then
            reject "coverage output ownership marker is invalid: $candidate/$OUTPUT_MARKER"
            return 1
        fi
    else
        mkdir "$candidate"
        printf '%s\n' "$OUTPUT_MARKER_CONTENT" > "$candidate/$OUTPUT_MARKER"
    fi
    printf '%s\n' "$candidate"
}

discover_profile() {
    local binary_directory="$1"
    local -a candidates
    shopt -s nullglob
    candidates=("$binary_directory"/codecov/*.profdata)
    shopt -u nullglob
    if [[ "${#candidates[@]}" != "1" ]]; then
        reject "expected exactly one merged coverage profile under $binary_directory/codecov; found ${#candidates[@]}"
        return 1
    fi
    require_regular_file "${candidates[0]}" "merged LLVM coverage profile"
    if [[ ! -s "${candidates[0]}" ]]; then
        reject "merged LLVM coverage profile is empty: ${candidates[0]}"
        return 1
    fi
    printf '%s\n' "${candidates[0]}"
}

discover_test_binary() {
    local binary_directory="$1"
    local product="$2"
    local selected=""
    local candidate
    local -a candidates=(
        "$binary_directory/$product.xctest/Contents/MacOS/$product"
        "$binary_directory/$product.xctest"
    )
    for candidate in "${candidates[@]}"; do
        if [[ -f "$candidate" && ! -L "$candidate" && -x "$candidate" ]]; then
            if [[ -n "$selected" ]]; then
                reject "found multiple executable test products for $product"
                return 1
            fi
            selected="$candidate"
        fi
    done
    if [[ -z "$selected" ]]; then
        reject "cannot locate executable test product $product below $binary_directory"
        return 1
    fi
    printf '%s\n' "$selected"
}

runner_self_test() {
    local fixture product darwin_root linux_root duplicate_root
    local darwin_binary linux_binary profile new_output reused_output unowned_output invalid_output symlink_output
    local failed_summary passed_summary malformed_summary publish_source publish_destination
    product="PackageTests"
    fixture="$(mktemp -d)"
    QVAC_COVERAGE_SELF_TEST_DIR="$fixture"
    darwin_root="$fixture/darwin"
    linux_root="$fixture/linux"
    duplicate_root="$fixture/duplicate"
    mkdir -p \
        "$darwin_root/codecov" \
        "$darwin_root/$product.xctest/Contents/MacOS" \
        "$linux_root/codecov" \
        "$duplicate_root/codecov"
    printf 'profile\n' > "$darwin_root/codecov/default.profdata"
    printf '#!/bin/sh\n' > "$darwin_root/$product.xctest/Contents/MacOS/$product"
    chmod +x "$darwin_root/$product.xctest/Contents/MacOS/$product"
    printf 'profile\n' > "$linux_root/codecov/default.profdata"
    printf '#!/bin/sh\n' > "$linux_root/$product.xctest"
    chmod +x "$linux_root/$product.xctest"
    printf 'profile-a\n' > "$duplicate_root/codecov/a.profdata"
    printf 'profile-b\n' > "$duplicate_root/codecov/b.profdata"

    profile="$(discover_profile "$darwin_root")"
    darwin_binary="$(discover_test_binary "$darwin_root" "$product")"
    linux_binary="$(discover_test_binary "$linux_root" "$product")"
    if [[ "$profile" != "$darwin_root/codecov/default.profdata" ||
          "$darwin_binary" != "$darwin_root/$product.xctest/Contents/MacOS/$product" ||
          "$linux_binary" != "$linux_root/$product.xctest" ]]; then
        reject "runner self-test resolved an unexpected profile or binary path"
        return 1
    fi
    if discover_profile "$duplicate_root" >/dev/null 2>&1; then
        reject "runner self-test accepted ambiguous coverage profiles"
        return 1
    fi
    if discover_test_binary "$duplicate_root" "$product" >/dev/null 2>&1; then
        reject "runner self-test accepted a missing test binary"
        return 1
    fi
    new_output="$(prepare_output_directory "$fixture/new-output")"
    reused_output="$(prepare_output_directory "$fixture/new-output")"
    mkdir "$fixture/unowned-output"
    unowned_output="$fixture/unowned-output"
    mkdir "$fixture/invalid-output"
    printf 'not-owned\n' > "$fixture/invalid-output/$OUTPUT_MARKER"
    invalid_output="$fixture/invalid-output"
    ln -s "$fixture/new-output" "$fixture/symlink-output"
    symlink_output="$fixture/symlink-output"
    if [[ "$new_output" != "$reused_output" ||
          "$(<"$new_output/$OUTPUT_MARKER")" != "$OUTPUT_MARKER_CONTENT" ]]; then
        reject "runner self-test failed to create or reuse owned output"
        return 1
    fi
    if prepare_output_directory "$unowned_output" >/dev/null 2>&1; then
        reject "runner self-test accepted an unowned existing output directory"
        return 1
    fi
    if prepare_output_directory "$invalid_output" >/dev/null 2>&1; then
        reject "runner self-test accepted an invalid output ownership marker"
        return 1
    fi
    if prepare_output_directory "$symlink_output" >/dev/null 2>&1; then
        reject "runner self-test accepted a symlinked output directory"
        return 1
    fi

    failed_summary="$fixture/failed-summary.json"
    passed_summary="$fixture/passed-summary.json"
    malformed_summary="$fixture/malformed-summary.json"
    printf '%s\n' '{"gate":{"result":"fail"}}' > "$failed_summary"
    printf '%s\n' '{"gate":{"result":"pass"}}' > "$passed_summary"
    printf '%s\n' 'not-json' > "$malformed_summary"
    if ! is_policy_failure_summary "$failed_summary" ||
       is_policy_failure_summary "$passed_summary" ||
       is_policy_failure_summary "$malformed_summary"; then
        reject "runner self-test failed policy-failure summary classification"
        return 1
    fi
    publish_source="$fixture/publish-source"
    publish_destination="$fixture/publish-destination"
    mkdir "$publish_source" "$publish_destination"
    printf '%s\n' 'diagnostic evidence' > "$publish_source/evidence.json"
    publish_evidence "$publish_source" "$publish_destination" evidence.json
    if [[ -e "$publish_source/evidence.json" ||
          "$(<"$publish_destination/evidence.json")" != "diagnostic evidence" ]]; then
        reject "runner self-test failed atomic evidence publication"
        return 1
    fi
    if publish_evidence "$publish_source" "$publish_destination" missing.json \
        >/dev/null 2>&1; then
        reject "runner self-test accepted missing staged evidence"
        return 1
    fi
    cleanup_self_test
    printf '[coverage-runner-self-test] discovery, output ownership, and failure-report classification passed\n'
}

is_policy_failure_summary() {
    local path="$1"
    [[ -f "$path" && ! -L "$path" ]] || return 1
    node -e '
        const fs = require("node:fs")
        try {
          const summary = JSON.parse(fs.readFileSync(process.argv[1], "utf8"))
          process.exit(summary?.gate?.result === "fail" ? 0 : 1)
        } catch {
          process.exit(1)
        }
    ' "$path"
}

publish_evidence() {
    local source_directory="$1"
    local destination_directory="$2"
    shift 2
    local output_name source_path destination_path
    for output_name in "$@"; do
        source_path="$source_directory/$output_name"
        destination_path="$destination_directory/$output_name"
        require_regular_file "$source_path" "staged coverage evidence"
        if [[ -L "$destination_path" || -d "$destination_path" ]]; then
            reject "refusing unsafe coverage output path: $destination_path"
            return 1
        fi
        mv -f -- "$source_path" "$destination_path"
    done
}

if [[ "${1:-}" == "--self-test" ]]; then
    if [[ "$#" != "1" ]]; then
        reject "usage: $0 [--self-test | output-directory]"
        exit 2
    fi
    trap cleanup EXIT
    node "$ANALYZER" --self-test
    runner_self_test
    trap - EXIT
    exit 0
fi
if [[ "$#" -gt 1 ]]; then
    reject "usage: $0 [--self-test | output-directory]"
    exit 2
fi

require_regular_file "$ANALYZER" "coverage analyzer"
require_regular_file "$POLICY" "coverage policy"

if [[ -L "$SCRATCH_ROOT" || ( -e "$SCRATCH_ROOT" && ! -d "$SCRATCH_ROOT" ) ]]; then
    reject "SwiftPM scratch root must be a real directory: $SCRATCH_ROOT"
    exit 2
fi
mkdir -p "$SCRATCH_PARENT"
if [[ ! -d "$SCRATCH_PARENT" || -L "$SCRATCH_PARENT" ]]; then
    reject "SwiftPM coverage scratch parent must be a real directory: $SCRATCH_PARENT"
    exit 2
fi
QVAC_COVERAGE_SCRATCH_DIR="$(mktemp -d "$SCRATCH_PARENT/run.XXXXXX")"
QVAC_COVERAGE_SCRATCH_DIR="$(cd -P "$QVAC_COVERAGE_SCRATCH_DIR" && pwd -P)"
: > "$QVAC_COVERAGE_SCRATCH_DIR/$SCRATCH_MARKER"
trap cleanup EXIT

OUTPUT_DIRECTORY="$(prepare_output_directory "${1:-$REPOSITORY_ROOT/.build/coverage-gate}")"

# Remove only this runner's known evidence files before any operation that may
# fail, so a reused local output directory can never retain a stale PASS report.
for output_name in \
    swift-test-list.txt swift-test-output.log llvm-coverage-summary.json \
    llvm-coverage.raw.lcov coverage-summary.json coverage-summary.md \
    handwritten-production.lcov all-production-source.lcov toolchain.txt \
    toolchain.json input-manifest.json coverage-complete.json; do
    output_path="$OUTPUT_DIRECTORY/$output_name"
    if [[ -L "$output_path" || -d "$output_path" ]]; then
        reject "refusing unsafe coverage output path: $output_path"
        exit 2
    fi
    rm -f -- "$output_path"
done

readonly EVIDENCE_STAGE="$QVAC_COVERAGE_SCRATCH_DIR/evidence"
mkdir "$EVIDENCE_STAGE"

MODULE="$(node "$ANALYZER" policy-value --policy "$POLICY" --key test.module)"
PRODUCT="$(node "$ANALYZER" policy-value --policy "$POLICY" --key test.product)"
INVENTORY_RELATIVE="$(node "$ANALYZER" policy-value --policy "$POLICY" --key test.inventoryPath)"
if [[ ! "$MODULE" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ||
      ! "$PRODUCT" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ||
      "$INVENTORY_RELATIVE" == /* || "$INVENTORY_RELATIVE" == *".."* ]]; then
    reject "coverage policy emitted unsafe test metadata"
    exit 2
fi

cd "$REPOSITORY_ROOT"
SOURCE_REVISION="$(git rev-parse --verify HEAD)"
readonly PRE_STATUS="$QVAC_COVERAGE_SCRATCH_DIR/status-before"
if ! git status --porcelain=v1 -z --untracked-files=all --ignore-submodules=none > "$PRE_STATUS"; then
    reject "cannot determine repository state"
    exit 1
fi
REPOSITORY_STATE="clean"
if [[ -s "$PRE_STATUS" ]]; then
    REPOSITORY_STATE="dirty"
fi
REPOSITORY_STATUS_SHA256="$(shasum -a 256 "$PRE_STATUS" | awk '{print $1}')"
readonly INPUT_MANIFEST="$EVIDENCE_STAGE/input-manifest.json"
node "$ANALYZER" capture-inputs \
    --policy "$POLICY" \
    --repository-root "$REPOSITORY_ROOT" \
    --source-revision "$SOURCE_REVISION" \
    --repository-state "$REPOSITORY_STATE" \
    --repository-status-sha256 "$REPOSITORY_STATUS_SHA256" \
    --output "$INPUT_MANIFEST"
node "$ANALYZER" verify-inventory \
    --policy "$POLICY" \
    --repository-root "$REPOSITORY_ROOT"

readonly LISTING="$EVIDENCE_STAGE/swift-test-list.txt"
readonly TEST_OUTPUT="$EVIDENCE_STAGE/swift-test-output.log"
readonly LLVM_SUMMARY="$EVIDENCE_STAGE/llvm-coverage-summary.json"
readonly LLVM_LCOV="$EVIDENCE_STAGE/llvm-coverage.raw.lcov"
readonly SUMMARY_JSON="$EVIDENCE_STAGE/coverage-summary.json"
readonly SUMMARY_MARKDOWN="$EVIDENCE_STAGE/coverage-summary.md"
readonly HANDWRITTEN_LCOV="$EVIDENCE_STAGE/handwritten-production.lcov"
readonly ALL_SOURCE_LCOV="$EVIDENCE_STAGE/all-production-source.lcov"
readonly TOOLCHAIN="$EVIDENCE_STAGE/toolchain.json"
for output_path in \
    "$LISTING" "$TEST_OUTPUT" "$LLVM_SUMMARY" "$LLVM_LCOV" \
    "$SUMMARY_JSON" "$SUMMARY_MARKDOWN" "$HANDWRITTEN_LCOV" \
    "$ALL_SOURCE_LCOV" "$TOOLCHAIN" "$INPUT_MANIFEST"; do
    if [[ -L "$output_path" || -d "$output_path" ]]; then
        reject "refusing unsafe coverage output path: $output_path"
        exit 2
    fi
done

DEVELOPER_DIRECTORY="${DEVELOPER_DIR:-$(xcode-select -p)}"
DEVELOPER_DIRECTORY="$(cd -P "$DEVELOPER_DIRECTORY" && pwd -P)"
SWIFT="$(xcrun --find swift)"
SWIFT_CANONICAL="$(node -e 'process.stdout.write(require("node:fs").realpathSync(process.argv[1]))' "$SWIFT")"
LLVM_COV="$(node -e 'process.stdout.write(require("node:fs").realpathSync(process.argv[1]))' "$(xcrun --find llvm-cov)")"
XCODEBUILD="$(node -e 'process.stdout.write(require("node:fs").realpathSync(process.argv[1]))' "$(xcrun --find xcodebuild)")"
case "$SWIFT" in "$DEVELOPER_DIRECTORY/"*) ;; *) reject "xcrun Swift is outside selected developer directory"; exit 1 ;; esac
case "$SWIFT_CANONICAL" in "$DEVELOPER_DIRECTORY/"*) ;; *) reject "canonical Swift target is outside selected developer directory"; exit 1 ;; esac
case "$LLVM_COV" in "$DEVELOPER_DIRECTORY/"*) ;; *) reject "xcrun LLVM is outside selected developer directory"; exit 1 ;; esac
case "$XCODEBUILD" in "$DEVELOPER_DIRECTORY/"*) ;; *) reject "xcrun xcodebuild is outside selected developer directory"; exit 1 ;; esac

"$SWIFT" test --scratch-path "$QVAC_COVERAGE_SCRATCH_DIR" \
    --enable-code-coverage --no-parallel "${SWIFTC_FLAGS[@]}" list > "$LISTING"
node "$ANALYZER" verify-discovery \
    --policy "$POLICY" \
    --repository-root "$REPOSITORY_ROOT" \
    --listing "$LISTING"

"$SWIFT" test --scratch-path "$QVAC_COVERAGE_SCRATCH_DIR" \
    --enable-code-coverage --no-parallel "${SWIFTC_FLAGS[@]}" \
    --filter "^${MODULE}\\." 2>&1 | tee "$TEST_OUTPUT"
node "$ANALYZER" verify-execution \
    --policy "$POLICY" \
    --repository-root "$REPOSITORY_ROOT" \
    --output "$TEST_OUTPUT"

BIN_DIRECTORY="$("$SWIFT" build --scratch-path "$QVAC_COVERAGE_SCRATCH_DIR" \
    "${SWIFTC_FLAGS[@]}" --show-bin-path)"
if [[ ! -d "$BIN_DIRECTORY" || -L "$BIN_DIRECTORY" ]]; then
    reject "SwiftPM binary directory is not a real directory: $BIN_DIRECTORY"
    exit 1
fi
BIN_DIRECTORY="$(cd -P "$BIN_DIRECTORY" && pwd -P)"

PROFILE="$(discover_profile "$BIN_DIRECTORY")"
TEST_BINARY="$(discover_test_binary "$BIN_DIRECTORY" "$PRODUCT")"

if [[ ! -f "$LLVM_COV" || ! -x "$LLVM_COV" ]]; then
    reject "xcrun-selected llvm-cov is not an executable file: $LLVM_COV"
    exit 1
fi

ARCHITECTURE="$(uname -m)"
SWIFT_VERSION="$("$SWIFT" --version | sed -n '1p')"
XCODE_VERSION="$("$XCODEBUILD" -version | sed -n '1p')"
XCODE_BUILD_VERSION="$("$XCODEBUILD" -version | sed -n '2p')"
LLVM_VERSION="$("$LLVM_COV" --version | sed -n '1p')"
NODE_PATH="$(node -e 'process.stdout.write(require("node:fs").realpathSync(process.execPath))')"
BASH_PATH="$(node -e 'process.stdout.write(require("node:fs").realpathSync(process.argv[1]))' "$(command -v bash)")"
node "$ANALYZER" capture-toolchain \
    --architecture "$ARCHITECTURE" \
    --developer-directory "$DEVELOPER_DIRECTORY" \
    --swift-version "$SWIFT_VERSION" \
    --swift-path "$SWIFT" \
    --xcode-version "$XCODE_VERSION" \
    --xcode-build-version "$XCODE_BUILD_VERSION" \
    --xcode-path "$XCODEBUILD" \
    --llvm-version "$LLVM_VERSION" \
    --llvm-path "$LLVM_COV" \
    --node-version "$(node --version)" \
    --node-path "$NODE_PATH" \
    --bash-version "$(bash --version | sed -n '1p')" \
    --bash-path "$BASH_PATH" \
    --output "$TOOLCHAIN"

"$LLVM_COV" export "$TEST_BINARY" -instr-profile="$PROFILE" -summary-only > "$LLVM_SUMMARY"
"$LLVM_COV" export "$TEST_BINARY" -instr-profile="$PROFILE" -format=lcov > "$LLVM_LCOV"

POST_SOURCE_REVISION="$(git rev-parse --verify HEAD)"
readonly POST_STATUS="$QVAC_COVERAGE_SCRATCH_DIR/status-after"
git status --porcelain=v1 -z --untracked-files=all --ignore-submodules=none > "$POST_STATUS"
POST_REPOSITORY_STATE="clean"
if [[ -s "$POST_STATUS" ]]; then POST_REPOSITORY_STATE="dirty"; fi
POST_REPOSITORY_STATUS_SHA256="$(shasum -a 256 "$POST_STATUS" | awk '{print $1}')"

SUMMARY_STATUS=0
node "$ANALYZER" summarize \
    --policy "$POLICY" \
    --repository-root "$REPOSITORY_ROOT" \
    --llvm-summary "$LLVM_SUMMARY" \
    --llvm-lcov "$LLVM_LCOV" \
    --test-listing "$LISTING" \
    --test-output "$TEST_OUTPUT" \
    --source-revision "$SOURCE_REVISION" \
    --repository-state "$REPOSITORY_STATE" \
    --repository-status-sha256 "$REPOSITORY_STATUS_SHA256" \
    --post-source-revision "$POST_SOURCE_REVISION" \
    --post-repository-state "$POST_REPOSITORY_STATE" \
    --post-repository-status-sha256 "$POST_REPOSITORY_STATUS_SHA256" \
    --input-manifest "$INPUT_MANIFEST" \
    --toolchain "$TOOLCHAIN" \
    --output-json "$SUMMARY_JSON" \
    --output-markdown "$SUMMARY_MARKDOWN" \
    --output-handwritten-lcov "$HANDWRITTEN_LCOV" \
    --output-all-source-lcov "$ALL_SOURCE_LCOV" || SUMMARY_STATUS="$?"

readonly -a EVIDENCE_NAMES=(
    swift-test-list.txt swift-test-output.log llvm-coverage-summary.json
    llvm-coverage.raw.lcov coverage-summary.json coverage-summary.md
    handwritten-production.lcov all-production-source.lcov toolchain.json
    input-manifest.json
)

if [[ "$SUMMARY_STATUS" -ne 0 ]]; then
    # A structurally valid policy failure is useful diagnostic evidence, but it
    # intentionally has no completion attestation and therefore cannot be
    # consumed as a passing result. Analyzer/integrity failures keep all staged
    # evidence private because its structure has not been validated.
    if is_policy_failure_summary "$SUMMARY_JSON"; then
        publish_evidence "$EVIDENCE_STAGE" "$OUTPUT_DIRECTORY" "${EVIDENCE_NAMES[@]}"
        printf '[coverage] failed policy evidence written without completion attestation to %s\n' \
            "$OUTPUT_DIRECTORY" >&2
    fi
    exit "$SUMMARY_STATUS"
fi

readonly COMPLETION="$EVIDENCE_STAGE/coverage-complete.json"
node "$ANALYZER" attest --directory "$EVIDENCE_STAGE" --output "$COMPLETION"
publish_evidence "$EVIDENCE_STAGE" "$OUTPUT_DIRECTORY" "${EVIDENCE_NAMES[@]}"
# The attestation is the commit record and is intentionally published last.
mv -f -- "$COMPLETION" "$OUTPUT_DIRECTORY/coverage-complete.json"
node "$ANALYZER" verify-attestation \
    --directory "$OUTPUT_DIRECTORY" \
    --attestation "$OUTPUT_DIRECTORY/coverage-complete.json"

printf '[coverage] evidence written to %s\n' "$OUTPUT_DIRECTORY"
