#!/usr/bin/env bash

set -euo pipefail

LOG_PATH="${1:-}"
TEST_MODULE="${2:-}"
TEST_CLASS="${3:-QVACiOSSmokeTests}"
TEST_METHOD="${4:-testBundledWorkerHandshakeHeartbeatAndIdempotentClose}"

if [[ -z "$LOG_PATH" || ! -f "$LOG_PATH" || \
      ! "$TEST_MODULE" =~ ^[A-Za-z_][A-Za-z0-9_]*$ || \
      ! "$TEST_CLASS" =~ ^[A-Za-z_][A-Za-z0-9_]*$ || \
      ! "$TEST_METHOD" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
    echo "usage: $0 <xcodebuild-test.log> <test-module> [test-class] [test-method]" >&2
    exit 2
fi

CASE_PATTERN="^Test Case '-\\[$TEST_MODULE\\.$TEST_CLASS $TEST_METHOD\\]' passed \\([0-9.]+ seconds\\)\\.$"
PASSED_CASES="$(grep -Ec "$CASE_PATTERN" "$LOG_PATH" || true)"
if [[ "$PASSED_CASES" != "1" ]]; then
    echo "[ios-smoke] expected exactly one passing $TEST_MODULE/$TEST_CLASS/$TEST_METHOD case; found $PASSED_CASES" >&2
    exit 1
fi

if ! grep -Eq '^[[:space:]]*Executed 1 test, with 0 failures \(0 unexpected\)' "$LOG_PATH"; then
    echo "[ios-smoke] XCTest did not report one executed test with zero failures" >&2
    exit 1
fi
if grep -Eq '^[[:space:]]*Executed [0-9]+ tests?, with [1-9][0-9]* tests? skipped' "$LOG_PATH" || \
   grep -Eq '^Test Case .* skipped ' "$LOG_PATH"; then
    echo "[ios-smoke] XCTest reported a skipped test" >&2
    exit 1
fi
if grep -Eq '^[[:space:]]*Executed 0 tests?' "$LOG_PATH"; then
    echo "[ios-smoke] XCTest reported an empty test run" >&2
    exit 1
fi

echo "[ios-smoke] verified one executed $TEST_CLASS/$TEST_METHOD test, zero failures, zero skips"
