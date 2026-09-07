#!/usr/bin/env bash
# Run one opt-in XCTest suite as a required, fail-closed CI gate.
#
# SwiftPM/XCTest exits successfully when a test skips and a count-only check can
# miss an equal-count substitution. This runner therefore binds discovery,
# started tests, and passed tests to a reviewed inventory and rejects skips.

set -euo pipefail

readonly INVENTORY_MODULE="QVACClientIntegrationTests"
readonly EXPECTED_INVENTORY_COUNT=19
# Intentional integration-test additions, removals, or renames must update both
# the reviewed inventory and this digest in the same review.
readonly EXPECTED_INVENTORY_SHA256="36fd43ce30aa0d22e278cb7fd3f5ba6835f44cafba08112f576f0acad811e134"
readonly SWIFTC_FLAGS=(
    -Xswiftc -warnings-as-errors
    -Xswiftc -strict-concurrency=complete
)

QVAC_CI_TEMP_DIR=""

cleanup() {
    local status="$?"
    if [[ -n "$QVAC_CI_TEMP_DIR" ]]; then
        rm -rf -- "$QVAC_CI_TEMP_DIR"
    fi
    trap - EXIT
    exit "$status"
}
trap cleanup EXIT

reject() {
    printf '[required-suite] error: %s\n' "$*" >&2
    return 1
}

is_identifier() {
    [[ "${1:-}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]
}

suite_filter() {
    local module="$1" suite="$2"
    printf '^%s\\.%s/' "$module" "$suite"
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

validate_inventory() {
    local inventory_path="$1"
    local expected_count="$2"
    local expected_sha256="$3"
    local invalid duplicate actual_count actual_sha256

    if [[ ! -f "$inventory_path" || -L "$inventory_path" ]]; then
        reject "reviewed integration-test inventory must be a regular non-symlink file: $inventory_path"
        return 1
    fi
    if [[ ! "$expected_count" =~ ^[1-9][0-9]*$ ||
          ! "$expected_sha256" =~ ^[0-9a-f]{64}$ ]]; then
        reject "invalid reviewed-inventory metadata"
        return 1
    fi

    invalid="$(awk '
        $0 !~ /^[A-Za-z_][A-Za-z0-9_]*\.[A-Za-z_][A-Za-z0-9_]*\/[A-Za-z_][A-Za-z0-9_]*$/ {
            print
            exit
        }
    ' "$inventory_path")"
    if [[ -n "$invalid" ]]; then
        reject "invalid identifier in reviewed integration-test inventory: $invalid"
        return 1
    fi

    actual_count="$(line_count "$inventory_path")"
    if [[ "$actual_count" != "$expected_count" ]]; then
        reject "reviewed integration-test inventory has $actual_count entries; expected $expected_count"
        return 1
    fi
    if ! LC_ALL=C sort -c "$inventory_path" >/dev/null 2>&1; then
        reject "reviewed integration-test inventory is not in canonical bytewise order"
        return 1
    fi
    duplicate="$(LC_ALL=C uniq -d "$inventory_path" | sed -n '1p')"
    if [[ -n "$duplicate" ]]; then
        reject "reviewed integration-test inventory contains a duplicate identifier: $duplicate"
        return 1
    fi

    actual_sha256="$(sha256_file "$inventory_path")"
    if [[ "$actual_sha256" != "$expected_sha256" ]]; then
        reject "reviewed integration-test inventory SHA-256 is $actual_sha256; expected $expected_sha256"
        return 1
    fi
}

extract_reviewed_suite() {
    local inventory_path="$1"
    local module="$2"
    local suite="$3"
    local destination="$4"
    local prefix="$module.$suite/"

    awk -v prefix="$prefix" 'index($0, prefix) == 1 { print }' \
        "$inventory_path" > "$destination"
}

build_discovered_suite() {
    local listing_path="$1"
    local module="$2"
    local suite="$3"
    local expected_count="$4"
    local destination="$5"
    local prefix="$module.$suite/"
    local invalid duplicate discovered

    awk -v prefix="$prefix" 'index($0, prefix) == 1 { print }' \
        "$listing_path" | LC_ALL=C sort > "$destination"

    invalid="$(awk -v module="$module" -v suite="$suite" '
        BEGIN {
            pattern = "^" module "\\." suite "/[A-Za-z_][A-Za-z0-9_]*$"
        }
        $0 !~ pattern { print; exit }
    ' "$destination")"
    if [[ -n "$invalid" ]]; then
        reject "unrecognized test identifier in $module.$suite discovery: $invalid"
        return 1
    fi

    discovered="$(line_count "$destination")"
    if [[ "$discovered" == "0" ]]; then
        reject "swift test list discovered zero tests under $prefix"
        return 1
    fi
    if [[ "$discovered" != "$expected_count" ]]; then
        reject "swift test list discovered $discovered tests under $prefix; expected $expected_count"
        return 1
    fi
    duplicate="$(LC_ALL=C uniq -d "$destination" | sed -n '1p')"
    if [[ -n "$duplicate" ]]; then
        reject "swift test list emitted a duplicate identifier: $duplicate"
        return 1
    fi
}

compare_inventories() {
    local actual_inventory="$1"
    local reviewed_inventory="$2"
    local context="$3"

    if ! diff -u "$reviewed_inventory" "$actual_inventory" >&2; then
        reject "$context identities differ from the committed reviewed inventory"
        return 1
    fi
}

build_inventory_suite_counts() {
    local inventory_path="$1"
    local destination="$2"

    awk -F '[./]' '{ counts[$2]++ } END {
        for (suite in counts) print suite, counts[suite]
    }' "$inventory_path" | LC_ALL=C sort > "$destination"
}

extract_ci_suite_counts() {
    local workflow_path="$1"
    local destination="$2"

    sed -nE \
        's@^.*tools/ci/run-required-suite\.sh ([A-Za-z_][A-Za-z0-9_]*) ([1-9][0-9]*)( QVACClientIntegrationTests)?[[:space:]]*$@\1 \2@p' \
        "$workflow_path" | LC_ALL=C sort > "$destination"
}

extract_started_inventory() {
    local output_path="$1"
    local module="$2"
    local suite="$3"
    sed -nE \
        "s/^Test Case '-\\[(${module}\\.${suite}) ([A-Za-z_][A-Za-z0-9_]*)\\]' started\\.$/\\1\\/\\2/p" \
        "$output_path" | LC_ALL=C sort
}

extract_passed_inventory() {
    local output_path="$1"
    local module="$2"
    local suite="$3"
    sed -nE \
        "s/^Test Case '-\\[(${module}\\.${suite}) ([A-Za-z_][A-Za-z0-9_]*)\\]' passed \\([0-9]+([.][0-9]+)? seconds\\)\\.$/\\1\\/\\2/p" \
        "$output_path" | LC_ALL=C sort
}

verify_execution() {
    local output_path="$1"
    local module="$2"
    local suite="$3"
    local expected_count="$4"
    local reviewed_inventory="$5"
    local started_inventory="$6"
    local passed_inventory="$7"
    local all_started started passed

    extract_started_inventory "$output_path" "$module" "$suite" > "$started_inventory"
    extract_passed_inventory "$output_path" "$module" "$suite" > "$passed_inventory"
    all_started="$(grep -Ec "^Test Case '-\\[[^]]+\\]' started\\.$" "$output_path" || true)"
    started="$(line_count "$started_inventory")"
    passed="$(line_count "$passed_inventory")"

    if grep -Eq '^Test Case .* skipped([ (]|$)|Executed [0-9]+ tests?, with [1-9][0-9]* tests? skipped' "$output_path"; then
        reject "$module.$suite reported one or more skipped tests"
        return 1
    fi
    if grep -Eq '^[[:space:]]*Executed 0 tests?([, ]|$)' "$output_path"; then
        reject "XCTest reported zero executed tests"
        return 1
    fi
    if [[ "$all_started" != "$expected_count" ]]; then
        reject "XCTest started $all_started total tests after the suite filter; expected exactly $expected_count"
        return 1
    fi
    if [[ "$started" != "$expected_count" || "$passed" != "$expected_count" ]]; then
        reject "$module.$suite started $started and passed $passed tests; expected exactly $expected_count of each"
        return 1
    fi
    if ! grep -Eq "^[[:space:]]*Executed ${expected_count} tests?, with 0 failures \\(0 unexpected\\)" "$output_path"; then
        reject "XCTest did not report an exact $expected_count-test, zero-failure aggregate"
        return 1
    fi
    compare_inventories "$started_inventory" "$reviewed_inventory" "executed test"
    compare_inventories "$passed_inventory" "$reviewed_inventory" "passing test"
}

self_test() {
    local inventory_path="$1"
    local workflow_path="$2"
    local listing reviewed discovered substituted_listing substituted_discovered
    local output substituted_output started passed inventory inventory_sha256
    local bad_inventory unsorted_inventory duplicate_inventory invalid_inventory
    local symlink_inventory candidate_sha256 inventory_suite_counts ci_suite_counts

    QVAC_CI_TEMP_DIR="$(mktemp -d)"
    listing="$QVAC_CI_TEMP_DIR/listing"
    reviewed="$QVAC_CI_TEMP_DIR/reviewed"
    discovered="$QVAC_CI_TEMP_DIR/discovered"
    substituted_listing="$QVAC_CI_TEMP_DIR/substituted-listing"
    substituted_discovered="$QVAC_CI_TEMP_DIR/substituted-discovered"
    output="$QVAC_CI_TEMP_DIR/output"
    started="$QVAC_CI_TEMP_DIR/started"
    passed="$QVAC_CI_TEMP_DIR/passed"
    inventory="$QVAC_CI_TEMP_DIR/inventory"
    bad_inventory="$QVAC_CI_TEMP_DIR/bad-inventory"
    unsorted_inventory="$QVAC_CI_TEMP_DIR/unsorted-inventory"
    duplicate_inventory="$QVAC_CI_TEMP_DIR/duplicate-inventory"
    invalid_inventory="$QVAC_CI_TEMP_DIR/invalid-inventory"
    symlink_inventory="$QVAC_CI_TEMP_DIR/symlink-inventory"
    substituted_output="$QVAC_CI_TEMP_DIR/substituted-output"
    inventory_suite_counts="$QVAC_CI_TEMP_DIR/inventory-suite-counts"
    ci_suite_counts="$QVAC_CI_TEMP_DIR/ci-suite-counts"

    validate_inventory \
        "$inventory_path" "$EXPECTED_INVENTORY_COUNT" "$EXPECTED_INVENTORY_SHA256"
    if [[ ! -f "$workflow_path" || -L "$workflow_path" ]]; then
        reject "CI workflow must be a regular non-symlink file: $workflow_path"
        return 1
    fi
    build_inventory_suite_counts "$inventory_path" "$inventory_suite_counts"
    extract_ci_suite_counts "$workflow_path" "$ci_suite_counts"
    compare_inventories \
        "$ci_suite_counts" "$inventory_suite_counts" "required CI suite/count invocation"
    [[ "${SWIFTC_FLAGS[0]}" == "-Xswiftc" ]]
    [[ "${SWIFTC_FLAGS[1]}" == "-warnings-as-errors" ]]
    [[ "${SWIFTC_FLAGS[2]}" == "-Xswiftc" ]]
    [[ "${SWIFTC_FLAGS[3]}" == "-strict-concurrency=complete" ]]
    [[ "$(suite_filter QVACClientIntegrationTests TargetSuite)" == '^QVACClientIntegrationTests\.TargetSuite/' ]]
    if is_identifier 'Bad.*'; then
        reject "self-test accepted an unsafe suite identifier"
        return 1
    fi

    printf '%s\n' \
        'OtherTests.NoiseTests/test_noise' \
        'QVACClientIntegrationTests.OtherSuite/test_noise' \
        'QVACClientIntegrationTests.TargetSuite/test_one' \
        'QVACClientIntegrationTests.TargetSuite/test_two' > "$listing"
    printf '%s\n' \
        'QVACClientIntegrationTests.TargetSuite/test_one' \
        'QVACClientIntegrationTests.TargetSuite/test_two' > "$inventory"
    inventory_sha256="$(sha256_file "$inventory")"
    validate_inventory "$inventory" 2 "$inventory_sha256"
    extract_reviewed_suite \
        "$inventory" QVACClientIntegrationTests TargetSuite "$reviewed"
    build_discovered_suite \
        "$listing" QVACClientIntegrationTests TargetSuite 2 "$discovered"
    compare_inventories "$discovered" "$reviewed" "discovered test"

    printf '%s\n' \
        "Test Case '-[QVACClientIntegrationTests.TargetSuite test_one]' started." \
        "Test Case '-[QVACClientIntegrationTests.TargetSuite test_one]' passed (0.001 seconds)." \
        "Test Case '-[QVACClientIntegrationTests.TargetSuite test_two]' started." \
        "Test Case '-[QVACClientIntegrationTests.TargetSuite test_two]' passed (0.002 seconds)." \
        'Executed 2 tests, with 0 failures (0 unexpected) in 0.003 (0.003) seconds' > "$output"
    verify_execution \
        "$output" QVACClientIntegrationTests TargetSuite 2 \
        "$reviewed" "$started" "$passed"

    printf '%s\n' \
        'OtherTests.NoiseTests/test_noise' \
        'QVACClientIntegrationTests.TargetSuite/test_one' \
        'QVACClientIntegrationTests.TargetSuite/test_three' > "$substituted_listing"
    build_discovered_suite \
        "$substituted_listing" QVACClientIntegrationTests TargetSuite 2 \
        "$substituted_discovered"
    if compare_inventories \
        "$substituted_discovered" "$reviewed" "discovered test" >/dev/null 2>&1; then
        reject "self-test accepted an equal-count test substitution"
        return 1
    fi

    cp "$inventory" "$bad_inventory"
    printf '%s\n' 'QVACClientIntegrationTests.TargetSuite/test_three' >> "$bad_inventory"
    if validate_inventory "$bad_inventory" 3 "$inventory_sha256" >/dev/null 2>&1; then
        reject "self-test accepted reviewed-inventory hash drift"
        return 1
    fi

    printf '%s\n' \
        'QVACClientIntegrationTests.TargetSuite/test_two' \
        'QVACClientIntegrationTests.TargetSuite/test_one' > "$unsorted_inventory"
    candidate_sha256="$(sha256_file "$unsorted_inventory")"
    if validate_inventory "$unsorted_inventory" 2 "$candidate_sha256" >/dev/null 2>&1; then
        reject "self-test accepted a non-canonical inventory order"
        return 1
    fi

    printf '%s\n' \
        'QVACClientIntegrationTests.TargetSuite/test_one' \
        'QVACClientIntegrationTests.TargetSuite/test_one' > "$duplicate_inventory"
    candidate_sha256="$(sha256_file "$duplicate_inventory")"
    if validate_inventory "$duplicate_inventory" 2 "$candidate_sha256" >/dev/null 2>&1; then
        reject "self-test accepted a duplicate reviewed identifier"
        return 1
    fi

    printf '%s\n' 'QVACClientIntegrationTests.TargetSuite/not-a-test' > "$invalid_inventory"
    candidate_sha256="$(sha256_file "$invalid_inventory")"
    if validate_inventory "$invalid_inventory" 1 "$candidate_sha256" >/dev/null 2>&1; then
        reject "self-test accepted an invalid reviewed identifier"
        return 1
    fi

    ln -s "$inventory" "$symlink_inventory"
    if validate_inventory "$symlink_inventory" 2 "$inventory_sha256" >/dev/null 2>&1; then
        reject "self-test accepted a symlink as the reviewed inventory"
        return 1
    fi

    if build_discovered_suite \
        "$listing" QVACClientIntegrationTests TargetSuite 3 "$discovered" >/dev/null 2>&1; then
        reject "self-test accepted discovery-count drift"
        return 1
    fi
    if build_discovered_suite \
        /dev/null QVACClientIntegrationTests TargetSuite 2 "$discovered" >/dev/null 2>&1; then
        reject "self-test accepted zero discovery"
        return 1
    fi

    printf '%s\n' \
        'Executed 0 tests, with 0 failures (0 unexpected) in 0.000 (0.000) seconds' > "$output"
    if verify_execution \
        "$output" QVACClientIntegrationTests TargetSuite 2 \
        "$reviewed" "$started" "$passed" >/dev/null 2>&1; then
        reject "self-test accepted zero execution"
        return 1
    fi

    printf '%s\n' \
        "Test Case '-[QVACClientIntegrationTests.TargetSuite test_one]' started." \
        "Test Case '-[QVACClientIntegrationTests.TargetSuite test_one]' passed (0.001 seconds)." \
        "Test Case '-[QVACClientIntegrationTests.TargetSuite test_two]' started." \
        "Test Case '-[QVACClientIntegrationTests.TargetSuite test_two]' skipped (0.002 seconds)." \
        'Executed 2 tests, with 1 test skipped and 0 failures (0 unexpected)' > "$output"
    if verify_execution \
        "$output" QVACClientIntegrationTests TargetSuite 2 \
        "$reviewed" "$started" "$passed" >/dev/null 2>&1; then
        reject "self-test accepted a skipped required test"
        return 1
    fi

    printf '%s\n' \
        "Test Case '-[QVACClientIntegrationTests.TargetSuite test_one]' started." \
        "Test Case '-[QVACClientIntegrationTests.TargetSuite test_one]' passed (0.001 seconds)." \
        "Test Case '-[QVACClientIntegrationTests.TargetSuite test_one]' started." \
        "Test Case '-[QVACClientIntegrationTests.TargetSuite test_one]' passed (0.001 seconds)." \
        'Executed 2 tests, with 0 failures (0 unexpected)' > "$output"
    if verify_execution \
        "$output" QVACClientIntegrationTests TargetSuite 2 \
        "$reviewed" "$started" "$passed" >/dev/null 2>&1; then
        reject "self-test accepted duplicate execution with a missing inventory member"
        return 1
    fi

    printf '%s\n' \
        "Test Case '-[QVACClientIntegrationTests.TargetSuite test_one]' started." \
        "Test Case '-[QVACClientIntegrationTests.TargetSuite test_one]' passed (0.001 seconds)." \
        "Test Case '-[QVACClientIntegrationTests.TargetSuite test_three]' started." \
        "Test Case '-[QVACClientIntegrationTests.TargetSuite test_three]' passed (0.001 seconds)." \
        'Executed 2 tests, with 0 failures (0 unexpected)' > "$substituted_output"
    if verify_execution \
        "$substituted_output" QVACClientIntegrationTests TargetSuite 2 \
        "$reviewed" "$started" "$passed" >/dev/null 2>&1; then
        reject "self-test accepted equal-count execution identity substitution"
        return 1
    fi

    printf '[required-suite-self-test] strict flags, CI suite mapping, inventory integrity, identity drift, count drift, zero execution, skips, and execution substitution are verified\n'
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REVIEWED_INVENTORY="$SCRIPT_DIR/required-suite-inventory.txt"
CI_WORKFLOW="$REPOSITORY_ROOT/.github/workflows/ci.yml"

if [[ "${1:-}" == "--self-test" ]]; then
    if [[ "$#" != "1" ]]; then
        reject "usage: $0 <XCTestSuite> <expected-test-count> [test-module] | --self-test" || exit 2
    fi
    self_test "$REVIEWED_INVENTORY" "$CI_WORKFLOW"
    exit 0
fi

SUITE="${1:-}"
EXPECTED="${2:-}"
MODULE="${3:-$INVENTORY_MODULE}"
if [[ "$#" -lt 2 || "$#" -gt 3 ]] ||
   ! is_identifier "$SUITE" ||
   ! is_identifier "$MODULE" ||
   [[ ! "$EXPECTED" =~ ^[1-9][0-9]*$ ]]; then
    reject "usage: $0 <XCTestSuite> <expected-test-count> [test-module] | --self-test" || exit 2
fi

QVAC_CI_TEMP_DIR="$(mktemp -d)"
LISTING="$QVAC_CI_TEMP_DIR/swift-test-list.txt"
REVIEWED_SUITE="$QVAC_CI_TEMP_DIR/reviewed-suite.txt"
DISCOVERED_SUITE="$QVAC_CI_TEMP_DIR/discovered-suite.txt"
OUTPUT="$QVAC_CI_TEMP_DIR/swift-test-output.txt"
STARTED="$QVAC_CI_TEMP_DIR/started-suite.txt"
PASSED="$QVAC_CI_TEMP_DIR/passed-suite.txt"

cd "$REPOSITORY_ROOT"
validate_inventory \
    "$REVIEWED_INVENTORY" "$EXPECTED_INVENTORY_COUNT" "$EXPECTED_INVENTORY_SHA256"
extract_reviewed_suite \
    "$REVIEWED_INVENTORY" "$MODULE" "$SUITE" "$REVIEWED_SUITE"
if [[ "$(line_count "$REVIEWED_SUITE")" != "$EXPECTED" ]]; then
    reject "reviewed inventory does not contain exactly $EXPECTED tests under $MODULE.$SUITE/"
    exit 3
fi

swift test "${SWIFTC_FLAGS[@]}" list > "$LISTING"
build_discovered_suite \
    "$LISTING" "$MODULE" "$SUITE" "$EXPECTED" "$DISCOVERED_SUITE"
compare_inventories "$DISCOVERED_SUITE" "$REVIEWED_SUITE" "swift test list"
printf '[required-suite] verified committed inventory: suite=%s.%s tests=%s strict-concurrency=complete warnings-as-errors\n' \
    "$MODULE" "$SUITE" "$EXPECTED"

FILTER="$(suite_filter "$MODULE" "$SUITE")"
swift test "${SWIFTC_FLAGS[@]}" --filter "$FILTER" 2>&1 | tee "$OUTPUT"
verify_execution \
    "$OUTPUT" "$MODULE" "$SUITE" "$EXPECTED" \
    "$REVIEWED_SUITE" "$STARTED" "$PASSED"
printf '[required-suite] %s.%s/ executed exactly %s reviewed tests with zero failures and zero skips\n' \
    "$MODULE" "$SUITE" "$EXPECTED"
