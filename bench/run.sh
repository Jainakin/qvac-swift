#!/usr/bin/env bash
# bench/run.sh — runs both the Swift and Node heartbeat benchmarks, prints results
# side-by-side, and exits non-zero if Swift overhead exceeds 5% (grant KR-2).
#
# Usage:
#   ./bench/run.sh [iterations]
#
# Env:
#   QVAC_BENCH_MAX_OVERHEAD  default 1.05 (5% allowance)

set -euo pipefail

ITERATIONS="${1:-1000}"
MAX_OVERHEAD="${QVAC_BENCH_MAX_OVERHEAD:-1.05}"

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
REPO_ROOT="$( cd "$SCRIPT_DIR/.." && pwd )"

echo "[bench] iterations=$ITERATIONS  max-overhead=$MAX_OVERHEAD"

echo "[bench] Building Swift bench..."
swift build --package-path "$SCRIPT_DIR/swift" -c release > /dev/null

echo "[bench] Cleaning any stale workers..."
pkill -9 -f 'bare.*worker.js' 2>/dev/null || true
rm -f "$HOME/.qvac/.worker.lock"
sleep 1

echo "[bench] Swift run..."
SWIFT_RESULT=$(swift run --package-path "$SCRIPT_DIR/swift" -c release QVACBench "$ITERATIONS")
echo "$SWIFT_RESULT"

pkill -9 -f 'bare.*worker.js' 2>/dev/null || true
rm -f "$HOME/.qvac/.worker.lock"
sleep 1

echo "[bench] Node baseline..."
# Copy the script into spike-js so Node's module-resolution finds @qvac/sdk.
cp "$SCRIPT_DIR/js/heartbeat-bench.mjs" "$REPO_ROOT/spike-js/heartbeat-bench.mjs"
NODE_RESULT=$(cd "$REPO_ROOT/spike-js" && node heartbeat-bench.mjs "$ITERATIONS")
echo "$NODE_RESULT"

SWIFT_MEAN=$(echo "$SWIFT_RESULT" | python3 -c 'import json,sys; print(json.load(sys.stdin)["mean_ms"])')
NODE_MEAN=$(echo "$NODE_RESULT" | python3 -c 'import json,sys; print(json.load(sys.stdin)["mean_ms"])')
RATIO=$(python3 -c "print($SWIFT_MEAN / $NODE_MEAN)")

echo
echo "[bench] Swift mean: ${SWIFT_MEAN} ms"
echo "[bench] Node  mean: ${NODE_MEAN} ms"
echo "[bench] Ratio (Swift/Node): ${RATIO}"
echo "[bench] Budget (KR-2 < 1.05): $MAX_OVERHEAD"

OK=$(python3 -c "print(1 if $RATIO <= $MAX_OVERHEAD else 0)")
if [ "$OK" = "1" ]; then
    echo "[bench] ✅ PASS — Swift overhead within budget"
    exit 0
else
    echo "[bench] ❌ FAIL — Swift overhead exceeds budget"
    exit 1
fi
