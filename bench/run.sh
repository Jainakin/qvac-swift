#!/usr/bin/env bash
# bench/run.sh — runs both the Swift and Node heartbeat benchmarks, writes
# bench/result.json with the comparison, and exits non-zero if Swift overhead
# exceeds 5% (grant KR-2).
#
# Usage:
#   ./bench/run.sh [iterations]
#
# Env:
#   QVAC_NODE_MODULES        REQUIRED — path to a node_modules dir with @qvac/sdk
#   QVAC_BENCH_MAX_OVERHEAD  default 1.05 (5% allowance)

set -euo pipefail

ITERATIONS="${1:-1000}"
MAX_OVERHEAD="${QVAC_BENCH_MAX_OVERHEAD:-1.05}"

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
REPO_ROOT="$( cd "$SCRIPT_DIR/.." && pwd )"
SWIFT_RESULT_FILE="$SCRIPT_DIR/swift-result.json"
NODE_RESULT_FILE="$SCRIPT_DIR/node-result.json"
RESULT_FILE="$SCRIPT_DIR/result.json"

if [ -z "${QVAC_NODE_MODULES:-}" ]; then
    echo "[bench] error: QVAC_NODE_MODULES must point at a node_modules dir containing @qvac/sdk" >&2
    exit 2
fi
if [ ! -d "$QVAC_NODE_MODULES/@qvac/sdk" ]; then
    echo "[bench] error: $QVAC_NODE_MODULES does not contain @qvac/sdk" >&2
    exit 2
fi

BARE_BIN="${QVAC_BARE_BIN:-/opt/homebrew/bin/bare}"
if [ ! -x "$BARE_BIN" ]; then
    echo "[bench] error: bare runtime not found at $BARE_BIN (set QVAC_BARE_BIN to override)" >&2
    exit 2
fi

echo "[bench] iterations=$ITERATIONS  max-overhead=$MAX_OVERHEAD"
echo "[bench] QVAC_NODE_MODULES=$QVAC_NODE_MODULES"
echo "[bench] QVAC_BARE_BIN=$BARE_BIN"

# Clean up any stale workers.
pkill -9 -f 'bare.*worker.js' 2>/dev/null || true
rm -f "$HOME/.qvac/.worker.lock"
sleep 1

echo "[bench] Swift run (via XCTest)..."
cd "$REPO_ROOT"
QVAC_RUN_BENCH=1 \
  QVAC_BENCH_ITERS="$ITERATIONS" \
  QVAC_BENCH_RESULT="$SWIFT_RESULT_FILE" \
  QVAC_BARE_BIN="$BARE_BIN" \
  QVAC_NODE_MODULES="$QVAC_NODE_MODULES" \
  swift test --filter BenchmarkTests > /tmp/qvac-bench-swift.log 2>&1
if [ ! -f "$SWIFT_RESULT_FILE" ]; then
    echo "[bench] error: Swift bench did not produce $SWIFT_RESULT_FILE" >&2
    tail -30 /tmp/qvac-bench-swift.log >&2
    exit 3
fi
cat "$SWIFT_RESULT_FILE"

pkill -9 -f 'bare.*worker.js' 2>/dev/null || true
rm -f "$HOME/.qvac/.worker.lock"
sleep 1

echo "[bench] Node baseline..."
NODE_MODULES_PARENT="$( cd "$QVAC_NODE_MODULES/.." && pwd )"
STAGED="$NODE_MODULES_PARENT/_qvac_heartbeat_bench.mjs"
cp "$SCRIPT_DIR/js/heartbeat-bench.mjs" "$STAGED"
trap 'rm -f "$STAGED" "$SWIFT_RESULT_FILE" "$NODE_RESULT_FILE"' EXIT
(cd "$NODE_MODULES_PARENT" && node _qvac_heartbeat_bench.mjs "$ITERATIONS" "$NODE_RESULT_FILE" > /tmp/qvac-bench-node.log 2>&1) || {
    echo "[bench] node bench failed" >&2; tail -30 /tmp/qvac-bench-node.log >&2; exit 4
}
if [ ! -f "$NODE_RESULT_FILE" ]; then
    echo "[bench] error: Node bench did not produce $NODE_RESULT_FILE" >&2
    exit 4
fi
cat "$NODE_RESULT_FILE"

# Compute ratio + write final result.
SWIFT_MEAN=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["mean_ms"])' "$SWIFT_RESULT_FILE")
NODE_MEAN=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["mean_ms"])' "$NODE_RESULT_FILE")
RATIO=$(python3 -c "print($SWIFT_MEAN / $NODE_MEAN)")
OK=$(python3 -c "print(1 if $RATIO <= $MAX_OVERHEAD else 0)")
STATUS=$([ "$OK" = "1" ] && echo "pass" || echo "fail")

python3 <<PY > "$RESULT_FILE"
import json
swift = json.load(open("$SWIFT_RESULT_FILE"))
node  = json.load(open("$NODE_RESULT_FILE"))
out = {
    "iterations":           $ITERATIONS,
    "max_overhead_budget":  $MAX_OVERHEAD,
    "ratio_swift_over_node": $RATIO,
    "status":               "$STATUS",
    "swift":                swift,
    "node":                 node,
    "host_platform":        "macos-arm64",
}
print(json.dumps(out, indent=2, sort_keys=True))
PY

echo
echo "[bench] Swift mean: ${SWIFT_MEAN} ms"
echo "[bench] Node  mean: ${NODE_MEAN} ms"
echo "[bench] Ratio (Swift/Node): ${RATIO}"
echo "[bench] Budget (KR-2): $MAX_OVERHEAD"
echo "[bench] Wrote $RESULT_FILE"

if [ "$OK" = "1" ]; then
    echo "[bench] ✅ PASS — Swift overhead within budget"
    exit 0
else
    echo "[bench] ❌ FAIL — Swift overhead exceeds budget"
    exit 1
fi
