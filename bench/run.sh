#!/usr/bin/env bash
# Compare Swift and Node heartbeat latency on the same exact SDK-0.17 runtime
# graph. The grant threshold remains 5%; bootstrap uncertainty is reported and
# an interval that straddles 1.05 is treated as inconclusive (non-zero), not pass.

set -euo pipefail

ITERATIONS="${1:-1000}"
WARMUP="${QVAC_BENCH_WARMUP:-50}"
MAX_OVERHEAD="${QVAC_BENCH_MAX_OVERHEAD:-1.05}"
PROCESS_TIMEOUT_SECONDS="${QVAC_BENCH_PROCESS_TIMEOUT_SECONDS:-120}"
if [[ ! "$ITERATIONS" =~ ^[0-9]+$ || "$ITERATIONS" -lt 100 ]]; then
    echo "[bench] error: iterations must be an integer >= 100" >&2
    exit 2
fi
if [[ ! "$WARMUP" =~ ^[0-9]+$ || "$WARMUP" -lt 1 ]]; then
    echo "[bench] error: QVAC_BENCH_WARMUP must be a positive integer" >&2
    exit 2
fi
if [[ "$MAX_OVERHEAD" != "1.05" ]]; then
    echo "[bench] error: KR-2 is fixed at 1.05; refusing QVAC_BENCH_MAX_OVERHEAD=$MAX_OVERHEAD" >&2
    exit 2
fi
if [[ ! "$PROCESS_TIMEOUT_SECONDS" =~ ^[0-9]+$ \
    || "$PROCESS_TIMEOUT_SECONDS" -lt 30 \
    || "$PROCESS_TIMEOUT_SECONDS" -gt 300 ]]; then
    echo "[bench] error: QVAC_BENCH_PROCESS_TIMEOUT_SECONDS must be 30...300" >&2
    exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
RUNTIME_DIR="$REPO_ROOT/tools/runtime"
NODE_MODULES="$RUNTIME_DIR/node_modules"
BARE_BIN="$NODE_MODULES/bare-runtime/bin/bare"
RESULT_FILE="$SCRIPT_DIR/result.json"
WORK_DIR="$(mktemp -d)"
STAGED="$RUNTIME_DIR/_qvac_heartbeat_bench.mjs"
ACTIVE_PID=""
WATCHDOG_PID=""

terminate_owned_tree() {
    local pid="${1:-}"
    [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 0
    local child
    while IFS= read -r child; do
        [[ -n "$child" ]] || continue
        terminate_owned_tree "$child"
    done < <(pgrep -P "$pid" 2>/dev/null || true)
    kill -TERM "$pid" 2>/dev/null || true
}

cleanup() {
    terminate_owned_tree "$WATCHDOG_PID"
    terminate_owned_tree "$ACTIVE_PID"
    rm -f "$STAGED"
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if [[ -e "$STAGED" ]]; then
    echo "[bench] error: generated staging path already exists: $STAGED" >&2
    exit 2
fi

bash "$RUNTIME_DIR/bootstrap.sh"
node "$RUNTIME_DIR/verify-runtime-lock.mjs"
if [[ ! -x "$BARE_BIN" ]]; then
    echo "[bench] error: exact locked Bare executable missing at $BARE_BIN" >&2
    exit 2
fi

# Sixteen mirrored, position-balanced process runs provide eight independent
# process-level replicates per implementation. The second half inverts the first
# half so first/last and local thermal-order effects are balanced across clients.
RUN_ORDER=(swift node node swift node swift swift node node swift swift node swift node node swift)

NODE_VERSION="$(node --version)"
BARE_VERSION="$("$BARE_BIN" --version)"
SWIFT_VERSION="$(swift --version | awk 'NR == 1 { print; exit }')"
HOST_DESCRIPTION="$(uname -s)-$(uname -r)-$(uname -m)"
for value in "$NODE_VERSION" "$BARE_VERSION" "$SWIFT_VERSION" "$HOST_DESCRIPTION"; do
    if [[ -z "$value" ]]; then
        echo "[bench] error: failed to capture exact benchmark toolchain metadata" >&2
        exit 2
    fi
done

echo "[bench] SDK=0.17.0 iterations=$ITERATIONS warmup=$WARMUP threshold=$MAX_OVERHEAD"
echo "[bench] identical owned-process watchdog=${PROCESS_TIMEOUT_SECONDS}s; no per-call heartbeat timeout"
echo "[bench] node=$NODE_VERSION bare=$BARE_VERSION swift=$SWIFT_VERSION host=$HOST_DESCRIPTION"
cp "$SCRIPT_DIR/js/heartbeat-bench.mjs" "$STAGED"

# Build once outside every measured process. The actual benchmark invocations
# use the release binary and never include compilation in their samples.
echo "[bench] prebuilding Swift benchmark in release configuration"
# Running the filtered test without its opt-in flag compiles the complete test
# bundle with testability enabled, records one intentional skip, and starts no
# worker. Measured repetitions below use --skip-build.
(cd "$REPO_ROOT" && swift test -c release --filter BenchmarkTests)

run_swift() {
    local label="$1" result="$2" home="$3" log="$WORK_DIR/$1.log"
    local timeout_marker="$WORK_DIR/$1.timed-out"
    echo "[bench] $label (public QVACClient.heartbeat)"
    (
        BENCH_CHILD_PID=""
        trap 'terminate_owned_tree "$BENCH_CHILD_PID"; exit 124' TERM INT
        (
            cd "$REPO_ROOT"
            QVAC_RUN_BENCH=1 QVAC_BENCH_ITERS="$ITERATIONS" QVAC_BENCH_WARMUP="$WARMUP" \
            QVAC_BENCH_RESULT="$result" QVAC_BENCH_HOME="$home" \
            QVAC_BARE_BIN="$BARE_BIN" QVAC_NODE_MODULES="$NODE_MODULES" \
            QVAC_BENCH_NODE_VERSION="$NODE_VERSION" QVAC_BENCH_BARE_VERSION="$BARE_VERSION" \
            QVAC_BENCH_SWIFT_VERSION="$SWIFT_VERSION" QVAC_BENCH_HOST="$HOST_DESCRIPTION" \
            QVAC_BENCH_PROCESS_TIMEOUT_SECONDS="$PROCESS_TIMEOUT_SECONDS" \
            swift test -c release --skip-build --filter BenchmarkTests
        ) &
        BENCH_CHILD_PID=$!
        wait "$BENCH_CHILD_PID"
    ) >"$log" 2>&1 &
    ACTIVE_PID=$!
    (
        sleep "$PROCESS_TIMEOUT_SECONDS"
        if kill -0 "$ACTIVE_PID" 2>/dev/null; then
            touch "$timeout_marker"
            kill -TERM "$ACTIVE_PID" 2>/dev/null || true
        fi
    ) &
    WATCHDOG_PID=$!
    if ! wait "$ACTIVE_PID" || [[ ! -f "$result" ]] || [[ -f "$timeout_marker" ]]; then
        kill -TERM "$WATCHDOG_PID" 2>/dev/null || true
        wait "$WATCHDOG_PID" 2>/dev/null || true
        ACTIVE_PID=""; WATCHDOG_PID=""; tail -50 "$log" >&2
        if [[ -f "$timeout_marker" ]]; then
            echo "[bench] error: $label exceeded the identical ${PROCESS_TIMEOUT_SECONDS}s process watchdog" >&2
        else
            echo "[bench] error: $label failed or skipped" >&2
        fi
        exit 3
    fi
    ACTIVE_PID=""
    kill -TERM "$WATCHDOG_PID" 2>/dev/null || true
    wait "$WATCHDOG_PID" 2>/dev/null || true
    WATCHDOG_PID=""
}

run_node() {
    local label="$1" result="$2" home="$3" log="$WORK_DIR/$1.log"
    local timeout_marker="$WORK_DIR/$1.timed-out"
    echo "[bench] $label (public @qvac/sdk.heartbeat)"
    (
        BENCH_CHILD_PID=""
        trap 'terminate_owned_tree "$BENCH_CHILD_PID"; exit 124' TERM INT
        (
            cd "$RUNTIME_DIR"
            env "PATH=$NODE_MODULES/.bin:$PATH" "SNAP_USER_COMMON=$home" \
                "QVAC_BENCH_NODE_VERSION=$NODE_VERSION" \
                "QVAC_BENCH_BARE_VERSION=$BARE_VERSION" \
                "QVAC_BENCH_SWIFT_VERSION=$SWIFT_VERSION" \
                "QVAC_BENCH_HOST=$HOST_DESCRIPTION" \
                "QVAC_BENCH_PROCESS_TIMEOUT_SECONDS=$PROCESS_TIMEOUT_SECONDS" \
                node "$(basename "$STAGED")" "$ITERATIONS" "$WARMUP" "$result"
        ) &
        BENCH_CHILD_PID=$!
        wait "$BENCH_CHILD_PID"
    ) >"$log" 2>&1 &
    ACTIVE_PID=$!
    (
        sleep "$PROCESS_TIMEOUT_SECONDS"
        if kill -0 "$ACTIVE_PID" 2>/dev/null; then
            touch "$timeout_marker"
            kill -TERM "$ACTIVE_PID" 2>/dev/null || true
        fi
    ) &
    WATCHDOG_PID=$!
    if ! wait "$ACTIVE_PID" || [[ ! -f "$result" ]] || [[ -f "$timeout_marker" ]]; then
        kill -TERM "$WATCHDOG_PID" 2>/dev/null || true
        wait "$WATCHDOG_PID" 2>/dev/null || true
        ACTIVE_PID=""; WATCHDOG_PID=""; tail -50 "$log" >&2
        if [[ -f "$timeout_marker" ]]; then
            echo "[bench] error: $label exceeded the identical ${PROCESS_TIMEOUT_SECONDS}s process watchdog" >&2
        else
            echo "[bench] error: $label failed" >&2
        fi
        exit 4
    fi
    ACTIVE_PID=""
    kill -TERM "$WATCHDOG_PID" 2>/dev/null || true
    wait "$WATCHDOG_PID" 2>/dev/null || true
    WATCHDOG_PID=""
}

SWIFT_RUN=0
NODE_RUN=0
RESULTS=()
for client_kind in "${RUN_ORDER[@]}"; do
    if [[ "$client_kind" == "swift" ]]; then
        SWIFT_RUN=$((SWIFT_RUN + 1))
        label="swift-$SWIFT_RUN"
    else
        NODE_RUN=$((NODE_RUN + 1))
        label="node-$NODE_RUN"
    fi
    result="$WORK_DIR/$label.json"
    home="$WORK_DIR/$label-home"
    mkdir -p "$home"
    RESULTS+=("$result")
    if [[ "$client_kind" == "swift" ]]; then
        run_swift "$label" "$result" "$home"
    else
        run_node "$label" "$result" "$home"
    fi
done

node "$SCRIPT_DIR/analyze.mjs" "$RESULT_FILE" "$MAX_OVERHEAD" "${RESULTS[@]}"
echo "[bench] wrote $RESULT_FILE"
