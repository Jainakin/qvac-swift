#!/usr/bin/env bash
# Run an opt-in XCTest suite as a required gate. XCTest skips exit successfully,
# so CI proves the exact class inventory executed with zero skips.

set -euo pipefail

is_identifier() {
    [[ "${1:-}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]
}

suite_filter() {
    local module="$1" suite="$2"
    printf '^%s\.%s/' "$module" "$suite"
}

count_listed_suite() {
    local listing="$1" prefix="$2"
    awk -v prefix="$prefix" 'index($0, prefix) == 1 { count++ } END { print count + 0 }' <<<"$listing"
}

if [[ "${1:-}" == "--self-test" ]]; then
    SAMPLE=$'QVACClientIntegrationTests.TargetSuite/test_one\nQVACClientIntegrationTests.OtherSuite/test_noise\nQVACClientIntegrationTests.TargetSuite/test_two\nAnotherModule.TargetSuite/test_noise'
    FILTER="$(suite_filter QVACClientIntegrationTests TargetSuite)"
    [[ "$FILTER" == '^QVACClientIntegrationTests\.TargetSuite/' ]]
    [[ "$(count_listed_suite "$SAMPLE" 'QVACClientIntegrationTests.TargetSuite/')" == "2" ]]
    [[ "$(printf '%s\n' "$SAMPLE" | grep -Ec "$FILTER")" == "2" ]]
    if is_identifier 'Bad.*'; then
        echo "[required-suite-test] unsafe suite identifier was accepted" >&2
        exit 1
    fi
    echo "[required-suite-test] anchored module/class filter and inventory count verified"
    exit 0
fi

SUITE="${1:-}"
EXPECTED="${2:-}"
MODULE="${3:-QVACClientIntegrationTests}"
if ! is_identifier "$SUITE" || ! is_identifier "$MODULE" || [[ ! "$EXPECTED" =~ ^[1-9][0-9]*$ ]]; then
    echo "usage: $0 <XCTestSuite> <expected-test-count> [test-module]" >&2
    exit 2
fi

LISTING="$(swift test list)"
PREFIX="$MODULE.$SUITE/"
DISCOVERED="$(count_listed_suite "$LISTING" "$PREFIX")"
if [[ "$DISCOVERED" != "$EXPECTED" ]]; then
    echo "[required-suite] error: discovered $DISCOVERED tests under $PREFIX; expected $EXPECTED" >&2
    printf '%s\n' "$LISTING" | awk -v module="$MODULE." 'index($0, module) == 1' >&2
    exit 3
fi

FILTER="$(suite_filter "$MODULE" "$SUITE")"
OUTPUT="$(mktemp)"
trap 'rm -f "$OUTPUT"' EXIT
swift test --filter "$FILTER" 2>&1 | tee "$OUTPUT"

if grep -Eq 'with [1-9][0-9]* tests? skipped' "$OUTPUT"; then
    echo "[required-suite] error: $PREFIX skipped one or more required tests" >&2
    exit 4
fi
if ! grep -Eq "Executed ${EXPECTED} tests?," "$OUTPUT"; then
    echo "[required-suite] error: expected exactly $EXPECTED executed tests in $PREFIX" >&2
    exit 5
fi
echo "[required-suite] $PREFIX executed $EXPECTED tests with zero skips"
