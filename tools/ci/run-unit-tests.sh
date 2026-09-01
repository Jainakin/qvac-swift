#!/usr/bin/env bash
# Run the complete XCTest unit-test module as a fail-closed release gate.
# SwiftPM/XCTest treats skipped or accidentally undiscovered tests as success,
# so discovery and execution are both checked against a reviewed inventory.

set -euo pipefail

readonly MODULE="QVACClientUnitTests"
readonly EXPECTED_TEST_COUNT=326
readonly EXPECTED_INVENTORY_SHA256="6b21abc73fec49b52d1b6d57af836ae268fea905a116fae123e5a7effd38da2b"
readonly SWIFTC_FLAGS=(
    -Xswiftc -warnings-as-errors
    -Xswiftc -strict-concurrency=complete
)
QVAC_CI_TEMP_DIR=""

cleanup() {
    if [[ -n "$QVAC_CI_TEMP_DIR" ]]; then
        rm -rf -- "$QVAC_CI_TEMP_DIR"
    fi
}
trap cleanup EXIT

reject() {
    printf '[unit-tests] error: %s\n' "$*" >&2
    return 1
}

line_count() {
    awk 'END { print NR + 0 }' "$1"
}

sha256_file() {
    local path="$1"
    if command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$path" | awk '{ print $1 }'
    elif command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$path" | awk '{ print $1 }'
    else
        reject "neither shasum nor sha256sum is available"
        return 1
    fi
}

validate_reviewed_inventory() {
    local inventory_path="$1"
    local module="$2"
    local expected_count="$3"
    local expected_sha256="$4"
    local invalid duplicate actual_count actual_sha256

    if [[ ! -f "$inventory_path" || -L "$inventory_path" ]]; then
        reject "reviewed unit-test inventory must be a regular non-symlink file: $inventory_path"
        return 1
    fi
    if [[ ! "$module" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ||
          ! "$expected_count" =~ ^[1-9][0-9]*$ ||
          ! "$expected_sha256" =~ ^[0-9a-f]{64}$ ]]; then
        reject "invalid reviewed-inventory metadata"
        return 1
    fi

    invalid="$(awk -v module="$module" '
        BEGIN {
            pattern = "^" module "\\.[A-Za-z_][A-Za-z0-9_]*/[A-Za-z_][A-Za-z0-9_]*$"
        }
        $0 !~ pattern { print; exit }
    ' "$inventory_path")"
    if [[ -n "$invalid" ]]; then
        reject "invalid identifier in reviewed unit-test inventory: $invalid"
        return 1
    fi

    actual_count="$(line_count "$inventory_path")"
    if [[ "$actual_count" != "$expected_count" ]]; then
        reject "reviewed unit-test inventory has $actual_count entries; expected $expected_count"
        return 1
    fi
    if ! LC_ALL=C sort -c "$inventory_path" >/dev/null 2>&1; then
        reject "reviewed unit-test inventory is not in canonical bytewise order"
        return 1
    fi
    duplicate="$(LC_ALL=C uniq -d "$inventory_path" | sed -n '1p')"
    if [[ -n "$duplicate" ]]; then
        reject "reviewed unit-test inventory contains a duplicate identifier: $duplicate"
        return 1
    fi

    actual_sha256="$(sha256_file "$inventory_path")"
    if [[ "$actual_sha256" != "$expected_sha256" ]]; then
        reject "reviewed unit-test inventory SHA-256 is $actual_sha256; expected $expected_sha256"
        return 1
    fi
}

compare_to_reviewed_inventory() {
    local actual_inventory="$1"
    local reviewed_inventory="$2"
    local context="$3"

    if ! diff -u "$reviewed_inventory" "$actual_inventory" >&2; then
        reject "$context identities differ from the committed reviewed inventory"
        return 1
    fi
}

build_expected_inventory() {
    local listing_path="$1"
    local module="$2"
    local expected_count="$3"
    local inventory_path="$4"
    local invalid duplicate discovered

    if [[ ! "$module" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ||
          ! "$expected_count" =~ ^[1-9][0-9]*$ ]]; then
        reject "invalid module name or expected inventory count"
        return 1
    fi

    invalid="$(awk -v module="$module" '
        BEGIN {
            prefix = module "."
            pattern = "^" module "\\.[A-Za-z_][A-Za-z0-9_]*/[A-Za-z_][A-Za-z0-9_]*$"
        }
        index($0, prefix) == 1 && $0 !~ pattern { print; exit }
    ' "$listing_path")"
    if [[ -n "$invalid" ]]; then
        reject "unrecognized test identifier in $module discovery: $invalid"
        return 1
    fi

    awk -v prefix="$module." 'index($0, prefix) == 1 { print }' "$listing_path" |
        LC_ALL=C sort > "$inventory_path"
    discovered="$(line_count "$inventory_path")"
    if [[ "$discovered" == "0" ]]; then
        reject "swift test list discovered zero tests in $module"
        return 1
    fi
    if [[ "$discovered" != "$expected_count" ]]; then
        reject "swift test list discovered $discovered tests in $module; expected $expected_count"
        return 1
    fi

    duplicate="$(LC_ALL=C uniq -d "$inventory_path" | sed -n '1p')"
    if [[ -n "$duplicate" ]]; then
        reject "swift test list emitted a duplicate identifier: $duplicate"
        return 1
    fi
}

extract_started_inventory() {
    local output_path="$1"
    local module="$2"
    sed -nE \
        "s/^Test Case '-\\[(${module}\\.[A-Za-z_][A-Za-z0-9_]*) ([A-Za-z_][A-Za-z0-9_]*)\\]' started\\.$/\\1\\/\\2/p" \
        "$output_path" | LC_ALL=C sort
}

extract_passed_inventory() {
    local output_path="$1"
    local module="$2"
    sed -nE \
        "s/^Test Case '-\\[(${module}\\.[A-Za-z_][A-Za-z0-9_]*) ([A-Za-z_][A-Za-z0-9_]*)\\]' passed \\([0-9]+([.][0-9]+)? seconds\\)\\.$/\\1\\/\\2/p" \
        "$output_path" | LC_ALL=C sort
}

verify_execution() {
    local output_path="$1"
    local module="$2"
    local expected_count="$3"
    local expected_inventory="$4"
    local started_inventory="$5"
    local passed_inventory="$6"
    local all_started started passed

    extract_started_inventory "$output_path" "$module" > "$started_inventory"
    extract_passed_inventory "$output_path" "$module" > "$passed_inventory"
    all_started="$(grep -Ec "^Test Case '-\\[[^]]+\\]' started\\.$" "$output_path" || true)"
    started="$(line_count "$started_inventory")"
    passed="$(line_count "$passed_inventory")"

    if grep -Eq '^Test Case .* skipped([ (]|$)|Executed [0-9]+ tests?, with [1-9][0-9]* tests? skipped' "$output_path"; then
        reject "$module reported one or more skipped tests"
        return 1
    fi
    if grep -Eq '^[[:space:]]*Executed 0 tests?([, ]|$)' "$output_path"; then
        reject "XCTest reported zero executed tests"
        return 1
    fi
    if [[ "$all_started" != "$expected_count" ]]; then
        reject "XCTest started $all_started total tests after the module filter; expected exactly $expected_count"
        return 1
    fi
    if [[ "$started" != "$expected_count" || "$passed" != "$expected_count" ]]; then
        reject "$module started $started and passed $passed tests; expected exactly $expected_count of each"
        return 1
    fi
    if ! grep -Eq "^[[:space:]]*Executed ${expected_count} tests?, with 0 failures \\(0 unexpected\\)" "$output_path"; then
        reject "XCTest did not report an exact $expected_count-test, zero-failure aggregate"
        return 1
    fi
    compare_to_reviewed_inventory "$started_inventory" "$expected_inventory" "executed test"
    compare_to_reviewed_inventory "$passed_inventory" "$expected_inventory" "passing test"
}

self_test() {
    local listing inventory rejected_inventory substituted_listing substituted_inventory
    local output started passed inventory_sha256
    QVAC_CI_TEMP_DIR="$(mktemp -d)"
    listing="$QVAC_CI_TEMP_DIR/listing"
    inventory="$QVAC_CI_TEMP_DIR/inventory"
    rejected_inventory="$QVAC_CI_TEMP_DIR/rejected-inventory"
    substituted_listing="$QVAC_CI_TEMP_DIR/substituted-listing"
    substituted_inventory="$QVAC_CI_TEMP_DIR/substituted-inventory"
    output="$QVAC_CI_TEMP_DIR/output"
    started="$QVAC_CI_TEMP_DIR/started"
    passed="$QVAC_CI_TEMP_DIR/passed"

    printf '%s\n' \
        'OtherTests.NoiseTests/test_noise' \
        'QVACClientUnitTests.AlphaTests/test_one' \
        'QVACClientUnitTests.BetaTests/test_two' > "$listing"
    printf '%s\n' \
        "Test Case '-[QVACClientUnitTests.AlphaTests test_one]' started." \
        "Test Case '-[QVACClientUnitTests.AlphaTests test_one]' passed (0.001 seconds)." \
        "Test Case '-[QVACClientUnitTests.BetaTests test_two]' started." \
        "Test Case '-[QVACClientUnitTests.BetaTests test_two]' passed (0.002 seconds)." \
        'Executed 2 tests, with 0 failures (0 unexpected) in 0.003 (0.003) seconds' > "$output"

    build_expected_inventory "$listing" QVACClientUnitTests 2 "$inventory"
    inventory_sha256="$(sha256_file "$inventory")"
    validate_reviewed_inventory \
        "$inventory" QVACClientUnitTests 2 "$inventory_sha256"
    verify_execution "$output" QVACClientUnitTests 2 "$inventory" "$started" "$passed"

    printf '%s\n' \
        'OtherTests.NoiseTests/test_noise' \
        'QVACClientUnitTests.AlphaTests/test_one' \
        'QVACClientUnitTests.GammaTests/test_three' > "$substituted_listing"
    build_expected_inventory \
        "$substituted_listing" QVACClientUnitTests 2 "$substituted_inventory"
    if compare_to_reviewed_inventory \
        "$substituted_inventory" "$inventory" "discovered test" >/dev/null 2>&1; then
        reject "self-test accepted equal-count test substitution"
        return 1
    fi
    if validate_reviewed_inventory \
        "$inventory" QVACClientUnitTests 2 "$(printf '0%.0s' {1..64})" >/dev/null 2>&1; then
        reject "self-test accepted a reviewed-inventory hash mismatch"
        return 1
    fi

    if build_expected_inventory "$listing" QVACClientUnitTests 3 "$rejected_inventory" >/dev/null 2>&1; then
        reject "self-test accepted discovery-count drift"
        return 1
    fi
    if build_expected_inventory /dev/null QVACClientUnitTests 2 "$rejected_inventory" >/dev/null 2>&1; then
        reject "self-test accepted zero discovery"
        return 1
    fi

    printf '%s\n' \
        'Executed 0 tests, with 0 failures (0 unexpected) in 0.000 (0.000) seconds' > "$output"
    if verify_execution "$output" QVACClientUnitTests 2 "$inventory" "$started" "$passed" >/dev/null 2>&1; then
        reject "self-test accepted zero execution"
        return 1
    fi

    printf '%s\n' \
        "Test Case '-[QVACClientUnitTests.AlphaTests test_one]' started." \
        "Test Case '-[QVACClientUnitTests.AlphaTests test_one]' passed (0.001 seconds)." \
        "Test Case '-[QVACClientUnitTests.BetaTests test_two]' started." \
        "Test Case '-[QVACClientUnitTests.BetaTests test_two]' skipped (0.002 seconds)." \
        'Executed 2 tests, with 1 test skipped and 0 failures (0 unexpected)' > "$output"
    if verify_execution "$output" QVACClientUnitTests 2 "$inventory" "$started" "$passed" >/dev/null 2>&1; then
        reject "self-test accepted a skipped required test"
        return 1
    fi

    printf '%s\n' \
        "Test Case '-[QVACClientUnitTests.AlphaTests test_one]' started." \
        "Test Case '-[QVACClientUnitTests.AlphaTests test_one]' passed (0.001 seconds)." \
        "Test Case '-[QVACClientUnitTests.AlphaTests test_one]' started." \
        "Test Case '-[QVACClientUnitTests.AlphaTests test_one]' passed (0.001 seconds)." \
        'Executed 2 tests, with 0 failures (0 unexpected)' > "$output"
    if verify_execution "$output" QVACClientUnitTests 2 "$inventory" "$started" "$passed" >/dev/null 2>&1; then
        reject "self-test accepted duplicate execution with a missing inventory member"
        return 1
    fi

    printf '[unit-tests-self-test] count drift, equal-count substitution, hash drift, zero execution, skips, and execution identity mismatch are rejected\n'
}

if [[ "${1:-}" == "--self-test" ]]; then
    if [[ "$#" != "1" ]]; then
        reject "usage: $0 [--self-test]"
        exit 2
    fi
    self_test
    exit 0
fi
if [[ "$#" != "0" ]]; then
    reject "usage: $0 [--self-test]"
    exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
QVAC_CI_TEMP_DIR="$(mktemp -d)"
LISTING="$QVAC_CI_TEMP_DIR/swift-test-list.txt"
DISCOVERED_INVENTORY="$QVAC_CI_TEMP_DIR/discovered-unit-inventory.txt"
REVIEWED_INVENTORY="$SCRIPT_DIR/unit-test-inventory.txt"
OUTPUT="$QVAC_CI_TEMP_DIR/swift-test-output.txt"
STARTED="$QVAC_CI_TEMP_DIR/unit-started.txt"
PASSED="$QVAC_CI_TEMP_DIR/unit-passed.txt"

cd "$REPOSITORY_ROOT"
validate_reviewed_inventory \
    "$REVIEWED_INVENTORY" "$MODULE" "$EXPECTED_TEST_COUNT" "$EXPECTED_INVENTORY_SHA256"
swift test "${SWIFTC_FLAGS[@]}" list > "$LISTING"
build_expected_inventory \
    "$LISTING" "$MODULE" "$EXPECTED_TEST_COUNT" "$DISCOVERED_INVENTORY"
compare_to_reviewed_inventory \
    "$DISCOVERED_INVENTORY" "$REVIEWED_INVENTORY" "swift test list"
printf '[unit-tests] verified committed inventory: module=%s tests=%s sha256=%s\n' \
    "$MODULE" "$EXPECTED_TEST_COUNT" "$EXPECTED_INVENTORY_SHA256"

swift test "${SWIFTC_FLAGS[@]}" --filter "^${MODULE}\\." 2>&1 | tee "$OUTPUT"
verify_execution \
    "$OUTPUT" "$MODULE" "$EXPECTED_TEST_COUNT" "$REVIEWED_INVENTORY" "$STARTED" "$PASSED"
printf '[unit-tests] verified %s: exactly %s executed, zero failures, zero skips\n' \
    "$MODULE" "$EXPECTED_TEST_COUNT"
