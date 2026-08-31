#!/usr/bin/env bash
# Grant KR-2: compare real public streaming completions through the Swift and
# JavaScript clients using one immutable workload, model, and runtime graph.

set -euo pipefail

fail() {
    echo "[bench] error: $*" >&2
    exit 2
}

if [[ "$#" -ne 0 ]]; then
    fail "usage: QVAC_BENCH_MODEL_PATH=/absolute/model.gguf bench/run.sh"
fi

# The checked-in workload is the sole source of sampling, preconditioning, threshold,
# and timeout policy. Reject legacy tuning knobs instead of silently accepting
# evidence produced under a different protocol.
if [[ -n "${QVAC_BENCH_ITERS+x}" \
    || -n "${QVAC_BENCH_ITERATIONS+x}" \
    || -n "${QVAC_BENCH_SAMPLES+x}" \
    || -n "${QVAC_BENCH_WARMUP+x}" \
    || -n "${QVAC_BENCH_PROCESS_PAIRS+x}" \
    || -n "${QVAC_BENCH_BOOTSTRAP_ITERATIONS+x}" \
    || -n "${QVAC_BENCH_MAX_OVERHEAD+x}" \
    || -n "${QVAC_BENCH_PROCESS_TIMEOUT_SECONDS+x}" ]]; then
    fail "sampling, preconditioning, threshold, and timeout overrides are forbidden; edit no benchmark policy at runtime"
fi
if [[ "${QVAC_ALLOW_NODE_VERSION_MISMATCH:-0}" != "0" ]]; then
    fail "QVAC_ALLOW_NODE_VERSION_MISMATCH is diagnostic-only and forbidden for benchmark evidence"
fi
if [[ -z "${QVAC_BENCH_MODEL_PATH:-}" ]]; then
    fail "QVAC_BENCH_MODEL_PATH is required"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
RUNTIME_DIR="$REPO_ROOT/tools/runtime"
NODE_MODULES="$RUNTIME_DIR/node_modules"
BARE_BIN="$NODE_MODULES/bare-runtime/bin/bare"
WORKER_SCRIPT="$NODE_MODULES/@qvac/sdk/dist/server/worker.js"
WORKLOAD="$SCRIPT_DIR/workload.json"
RESULT_FILE="$SCRIPT_DIR/result.json"
EVIDENCE_DIR="$SCRIPT_DIR/evidence"
STAGED_RELATIVE="tools/runtime/_qvac_streaming_completion_bench.mjs"
STAGED="$REPO_ROOT/$STAGED_RELATIVE"
STAGED_SOURCE="$SCRIPT_DIR/js/streaming-completion-bench.mjs"
LOCK_DIR="$SCRIPT_DIR/.streaming-benchmark.lock"

# A benchmark report identifies one Git commit. Refuse tracked edits or
# untracked build inputs so that `source_commit` cannot describe different
# bytes from those actually compiled and executed. Repository-local diagnostic
# files outside the build/release surfaces do not affect the experiment.
verify_source_tree() {
    local tracked_changes=""
    local untracked_inputs=""
    local unexpected_untracked=""
    local input=""
    local allow_ci_manifest_overlay=0
    if ! git -C "$REPO_ROOT" diff --cached --quiet; then
        fail "benchmark evidence requires a clean Git index"
    fi
    tracked_changes="$(git -C "$REPO_ROOT" diff --name-only)"
    if [[ -n "$tracked_changes" ]]; then
        # URL-manifest CI validates the committed release manifest, then activates
        # the byte-exact development manifest as an ephemeral local binary overlay.
        # That single verified rewrite is the only dirty tracked state accepted.
        if [[ "${CI:-false}" == "true" \
            && "$tracked_changes" == "Package.swift" \
            && -f "$REPO_ROOT/Package.swift.dev" ]] \
            && cmp -s "$REPO_ROOT/Package.swift" "$REPO_ROOT/Package.swift.dev"; then
            allow_ci_manifest_overlay=1
        fi
        if [[ "$allow_ci_manifest_overlay" -ne 1 ]]; then
            echo "$tracked_changes" >&2
            fail "benchmark evidence requires a clean tracked Git tree"
        fi
    fi
    # Validate the owned resolver-local stage independently of Git ignore
    # configuration. Global excludes must not be able to bypass this invariant.
    if [[ "${STAGED_CREATED:-0}" == "1" ]]; then
        if [[ ! -f "$STAGED" || -L "$STAGED" \
            || ! -f "$STAGED_SOURCE" || -L "$STAGED_SOURCE" ]] \
            || ! cmp -s "$STAGED_SOURCE" "$STAGED"; then
            fail "owned runtime benchmark stage is missing, unsafe, or byte-modified"
        fi
    fi
    untracked_inputs="$(git -C "$REPO_ROOT" ls-files --others --exclude-standard -- \
        .github Sources Tests bench tools Package.swift Package.swift.dev)"
    if [[ -n "$untracked_inputs" ]]; then
        while IFS= read -r input; do
            [[ -n "$input" ]] || continue
            if [[ "$input" == "$STAGED_RELATIVE" ]]; then
                # The Node harness must live beside the exact runtime graph for
                # package resolution. Permit only the file this invocation
                # created, and only while it remains byte-identical to the
                # committed source harness. A stale/pre-existing path therefore
                # still fails the initial source-tree check.
                [[ "${STAGED_CREATED:-0}" == "1" ]] \
                    || fail "unowned runtime benchmark stage is present"
                continue
            fi
            unexpected_untracked+="${unexpected_untracked:+$'\n'}$input"
        done <<<"$untracked_inputs"
        if [[ -n "$unexpected_untracked" ]]; then
            echo "$unexpected_untracked" >&2
            fail "benchmark evidence refuses untracked build, harness, or workflow inputs"
        fi
    fi
}

verify_source_tree
SOURCE_COMMIT="$(git -C "$REPO_ROOT" rev-parse HEAD)"
[[ "$SOURCE_COMMIT" =~ ^[0-9a-f]{40}$ ]] \
    || fail "benchmark evidence requires an exact 40-hex source commit"

MODEL_PARENT=""
if ! MODEL_PARENT="$(cd "$(dirname "$QVAC_BENCH_MODEL_PATH")" 2>/dev/null && pwd -P)"; then
    fail "QVAC_BENCH_MODEL_PATH has no readable parent directory"
fi
MODEL_PATH="$MODEL_PARENT/$(basename "$QVAC_BENCH_MODEL_PATH")"
if [[ ! -f "$MODEL_PATH" || -L "$MODEL_PATH" ]]; then
    fail "QVAC_BENCH_MODEL_PATH must name a regular, non-symlink file"
fi
if [[ ! -f "$WORKLOAD" || -L "$WORKLOAD" ]]; then
    fail "checked-in workload is missing or is not a regular file: $WORKLOAD"
fi
if [[ ! -f "$STAGED_SOURCE" || -L "$STAGED_SOURCE" ]]; then
    fail "JavaScript benchmark harness is missing or is not a regular file: $STAGED_SOURCE"
fi

NODE_BIN="$(command -v node || true)"
SWIFT_BIN="$(command -v swift || true)"
[[ -n "$NODE_BIN" && -x "$NODE_BIN" ]] || fail "node is required"
[[ -n "$SWIFT_BIN" && -x "$SWIFT_BIN" ]] || fail "swift is required"

WORK_DIR="$(mktemp -d /tmp/qvac-streaming-bench.XXXXXX)"
ACTIVE_PID=""
WATCHDOG_PID=""
STAGED_CREATED=0
LOCK_CREATED=0

terminate_owned_tree() {
    local pid="${1:-}"
    local signal_name="${2:-TERM}"
    local child=""
    [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 0
    while IFS= read -r child; do
        [[ -n "$child" ]] || continue
        terminate_owned_tree "$child" "$signal_name"
    done < <(pgrep -P "$pid" 2>/dev/null || true)
    kill "-$signal_name" "$pid" 2>/dev/null || true
}

cleanup() {
    terminate_owned_tree "$WATCHDOG_PID" TERM
    terminate_owned_tree "$ACTIVE_PID" TERM
    if [[ "$STAGED_CREATED" -eq 1 ]]; then
        rm -f "$STAGED"
    fi
    if [[ "$LOCK_CREATED" -eq 1 ]]; then
        rmdir "$LOCK_DIR" 2>/dev/null || true
    fi
    case "$WORK_DIR" in
        /tmp/qvac-streaming-bench.*) rm -rf "$WORK_DIR" ;;
        *) echo "[bench] warning: refusing to remove unexpected work path: $WORK_DIR" >&2 ;;
    esac
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Evidence and the resolver-local staged module are deliberately single-writer.
# mkdir is atomic; a concurrent or uncleanly terminated invocation fails closed
# without touching the active run's files.
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    fail "another benchmark invocation (or a stale lock) owns $LOCK_DIR"
fi
LOCK_CREATED=1

# A failed invocation must never leave an earlier aggregate looking current.
# Partial per-run evidence remains available for the workflow's always-upload
# diagnostic artifact.
if [[ -e "$RESULT_FILE" || -L "$RESULT_FILE" ]]; then
    mv "$RESULT_FILE" "$WORK_DIR/previous-result"
fi
if [[ -e "$EVIDENCE_DIR" || -L "$EVIDENCE_DIR" ]]; then
    mv "$EVIDENCE_DIR" "$WORK_DIR/previous-evidence"
fi
mkdir "$EVIDENCE_DIR"

SETUP_LOG="$EVIDENCE_DIR/setup.log"
if ! bash "$RUNTIME_DIR/bootstrap.sh" >"$SETUP_LOG" 2>&1; then
    tail -100 "$SETUP_LOG" >&2
    fail "exact runtime bootstrap failed"
fi
if ! "$NODE_BIN" "$RUNTIME_DIR/verify-runtime-lock.mjs" >>"$SETUP_LOG" 2>&1; then
    tail -100 "$SETUP_LOG" >&2
    fail "installed runtime graph does not match package-lock.json"
fi
if [[ ! -x "$BARE_BIN" ]]; then
    fail "exact package-owned Bare launcher is missing: $BARE_BIN"
fi
if [[ ! -f "$WORKER_SCRIPT" || -L "$WORKER_SCRIPT" ]]; then
    fail "exact packaged QVAC worker is missing or unsafe: $WORKER_SCRIPT"
fi

SDK_VERSION="$("$NODE_BIN" -e '
const { readFileSync } = require("node:fs")
const value = JSON.parse(readFileSync(process.argv[1], "utf8")).version
if (typeof value !== "string") process.exit(2)
process.stdout.write(value)
' "$NODE_MODULES/@qvac/sdk/package.json")"
[[ "$SDK_VERSION" == "0.17.0" ]] || fail "benchmark requires exact @qvac/sdk 0.17.0; found $SDK_VERSION"

WORKLOAD_CONTRACT="$("$NODE_BIN" -e '
const { lstatSync, readFileSync } = require("node:fs")
const path = process.argv[1]
const stat = lstatSync(path)
if (!stat.isFile() || stat.isSymbolicLink()) throw new Error("workload must be a regular non-symlink file")
const workload = JSON.parse(readFileSync(path, "utf8"))
if (workload.schema_version !== 3) throw new Error("workload schema_version must be 3")
if (workload.measurement?.process_pairs !== 10) throw new Error("KR-2 requires exactly ten process pairs")
if (workload.measurement?.maximum_overhead_ratio !== 1.05) throw new Error("KR-2 overhead ratio must be 1.05")
if (workload.preconditioning?.predict !== 1000
    || workload.preconditioning?.completions !== 2) {
  throw new Error("KR-2 preconditioning must be exactly two 1,000-token completions")
}
if (workload.measurement?.predict !== 1000
    || workload.measurement?.completions_per_process !== 3) {
  throw new Error("KR-2 measurement must be exactly three 1,000-token completions per process")
}
if (workload.measurement?.bootstrap_iterations !== 20000) {
  throw new Error("KR-2 requires exactly 20,000 bootstrap iterations")
}
if (workload.measurement?.normalized_mean_factor_formula
    !== "mean_token_interval_ms / (1000 / stats.tokensPerSecond)") {
  throw new Error("KR-2 normalized mean factor formula is not the fixed contract")
}
if (workload.measurement?.normalized_mean_process_aggregation
    !== "arithmetic_mean(exactly_3_completion_factors)") {
  throw new Error("KR-2 normalized mean process aggregation is not the fixed contract")
}
if (workload.timeouts?.process_watchdog_seconds !== 240) throw new Error("KR-2 process watchdog must be exactly 240 seconds")
if (workload.timeouts?.completion_rpc_timeout !== "none") throw new Error("KR-2 completion RPC timeout must be disabled symmetrically")
process.stdout.write(`${workload.measurement.process_pairs}\t${workload.timeouts.process_watchdog_seconds}`
  + `\t${workload.preconditioning.completions}\t${workload.measurement.completions_per_process}`)
' "$WORKLOAD")"
IFS=$'\t' read -r PROCESS_PAIR_COUNT PROCESS_TIMEOUT_SECONDS \
    PRECONDITIONING_COUNT MEASUREMENT_COUNT <<<"$WORKLOAD_CONTRACT"
[[ "$PROCESS_PAIR_COUNT" == "10" && "$PROCESS_TIMEOUT_SECONDS" == "240" \
    && "$PRECONDITIONING_COUNT" == "2" && "$MEASUREMENT_COUNT" == "3" ]] \
    || fail "could not read the fixed workload orchestration contract"

NODE_VERSION="$("$NODE_BIN" --version)"
BARE_VERSION="$("$BARE_BIN" --version)"
SWIFT_VERSION="$("$SWIFT_BIN" --version | awk 'NR == 1 { print; exit }')"
HOST_DESCRIPTION="$(uname -s)-$(uname -r)-$(uname -m)"
for value in "$NODE_VERSION" "$BARE_VERSION" "$SWIFT_VERSION" "$HOST_DESCRIPTION"; do
    [[ -n "$value" ]] || fail "failed to capture exact benchmark toolchain metadata"
done

if [[ -e "$STAGED" || -L "$STAGED" ]]; then
    fail "runtime staging path already exists: $STAGED"
fi
cp "$STAGED_SOURCE" "$STAGED"
STAGED_CREATED=1

echo "[bench] real streaming completion; SDK=$SDK_VERSION pairs=$PROCESS_PAIR_COUNT threshold=1.05"
echo "[bench] fixed preconditioning=${PRECONDITIONING_COUNT}x1000; measurements=${MEASUREMENT_COUNT}x1000 per process"
echo "[bench] workload=$WORKLOAD"
echo "[bench] model=$MODEL_PATH"
echo "[bench] owned-process watchdog=${PROCESS_TIMEOUT_SECONDS}s; retries=0; exclusions=0"
echo "[bench] node=$NODE_VERSION bare=$BARE_VERSION swift=$SWIFT_VERSION host=$HOST_DESCRIPTION"

# Compile the release test bundle exactly once. Without QVAC_RUN_BENCH, the
# filtered test records its intentional opt-in skip and starts no worker.
PREBUILD_LOG="$EVIDENCE_DIR/prebuild.log"
echo "[bench] prebuilding the Swift release benchmark once"
if ! (
    cd "$REPO_ROOT"
    exec "$SWIFT_BIN" test -c release --filter BenchmarkTests.test_streaming_completion_latency
) >"$PREBUILD_LOG" 2>&1; then
    tail -100 "$PREBUILD_LOG" >&2
    fail "Swift release benchmark prebuild failed"
fi

stop_watchdog() {
    local pid="$WATCHDOG_PID"
    WATCHDOG_PID=""
    terminate_owned_tree "$pid" TERM
    wait "$pid" 2>/dev/null || true
}

run_one() {
    local client_kind="$1"
    local position="$2"
    local pair="$3"
    local pair_order="$4"
    local run_dir="$EVIDENCE_DIR/position-$position-$client_kind"
    local result="$run_dir/result.json"
    local log="$run_dir/run.log"
    local timeout_marker="$run_dir/timed-out"
    local home="$WORK_DIR/home-$position-$client_kind"
    local run_status=0
    local result_valid=0
    local -a run_environment

    mkdir "$run_dir"
    mkdir "$home"
    run_environment=(
        "QVAC_RUN_BENCH=1"
        "QVAC_BARE_BIN=$BARE_BIN"
        "QVAC_NODE_MODULES=$NODE_MODULES"
        "QVAC_BENCH_WORKLOAD=$WORKLOAD"
        "QVAC_BENCH_MODEL_PATH=$MODEL_PATH"
        "QVAC_BENCH_RESULT=$result"
        "QVAC_BENCH_HOME=$home"
        "SNAP_USER_COMMON=$home"
        "QVAC_BENCH_NODE_VERSION=$NODE_VERSION"
        "QVAC_BENCH_BARE_VERSION=$BARE_VERSION"
        "QVAC_BENCH_SWIFT_VERSION=$SWIFT_VERSION"
        "QVAC_BENCH_HOST=$HOST_DESCRIPTION"
        "QVAC_BENCH_SOURCE_COMMIT=$SOURCE_COMMIT"
        "QVAC_BENCH_POSITION=$position"
        "QVAC_BENCH_PAIR=$pair"
        "QVAC_BENCH_PAIR_ORDER=$pair_order"
        "QVAC_WORKER_PATH=$WORKER_SCRIPT"
    )

    echo "[bench] position=$position pair=$pair order=$pair_order client=$client_kind"
    if [[ "$client_kind" == "swift" ]]; then
        (
            cd "$REPO_ROOT"
            exec env -u QVAC_CONFIG_PATH -u QVAC_IPC_SOCKET_PATH -u QVAC_HYPERSWARM_SEED \
                "${run_environment[@]}" "$SWIFT_BIN" test -c release --skip-build \
                --filter BenchmarkTests.test_streaming_completion_latency
        ) >"$log" 2>&1 &
    else
        (
            cd "$RUNTIME_DIR"
            exec env -u QVAC_CONFIG_PATH -u QVAC_IPC_SOCKET_PATH -u QVAC_HYPERSWARM_SEED \
                "${run_environment[@]}" "$NODE_BIN" "$(basename "$STAGED")" \
                "$WORKLOAD" "$MODEL_PATH" "$result"
        ) >"$log" 2>&1 &
    fi
    ACTIVE_PID=$!

    (
        sleep "$PROCESS_TIMEOUT_SECONDS"
        if kill -0 "$ACTIVE_PID" 2>/dev/null; then
            touch "$timeout_marker"
            terminate_owned_tree "$ACTIVE_PID" TERM
            sleep 2
            if kill -0 "$ACTIVE_PID" 2>/dev/null; then
                terminate_owned_tree "$ACTIVE_PID" KILL
            fi
        fi
    ) &
    WATCHDOG_PID=$!

    if wait "$ACTIVE_PID"; then
        run_status=0
    else
        run_status=$?
    fi
    ACTIVE_PID=""

    if [[ -f "$timeout_marker" ]]; then
        wait "$WATCHDOG_PID" 2>/dev/null || true
        WATCHDOG_PID=""
    else
        stop_watchdog
    fi

    if [[ "$run_status" -eq 0 && -f "$result" && ! -L "$result" && -s "$result" ]]; then
        if "$NODE_BIN" -e '
const { readFileSync } = require("node:fs")
const sample = JSON.parse(readFileSync(process.argv[1], "utf8"))
if (sample.schema_version !== 2 || sample.status !== "sample" || sample.client !== process.argv[2]) process.exit(2)
if (sample.orchestration?.position !== process.argv[3]
    || sample.orchestration?.pair !== process.argv[4]
    || sample.orchestration?.pair_order !== process.argv[5]
    || sample.source_commit !== process.argv[6]) process.exit(2)
' "$result" "$client_kind" "$position" "$pair" "$pair_order" "$SOURCE_COMMIT" \
                >>"$log" 2>&1; then
            result_valid=1
        fi
    fi

    if [[ -f "$timeout_marker" ]]; then
        tail -100 "$log" >&2 || true
        echo "[bench] error: position $position ($client_kind) exceeded the fixed ${PROCESS_TIMEOUT_SECONDS}s process watchdog" >&2
        exit 3
    fi
    if [[ "$run_status" -ne 0 || "$result_valid" -ne 1 ]]; then
        tail -100 "$log" >&2 || true
        echo "[bench] error: position $position ($client_kind) failed or produced invalid evidence" >&2
        exit 3
    fi

    RESULTS+=("$result")
}

# Ten adjacent pairs alternate Swift/Node then Node/Swift. There are no retries,
# substitutions, discarded runs, or post-hoc exclusions.
RESULTS=()
POSITION=0
PAIR=1
while [[ "$PAIR" -le "$PROCESS_PAIR_COUNT" ]]; do
    if [[ $((PAIR % 2)) -eq 1 ]]; then
        PAIR_ORDER=(swift node)
    else
        PAIR_ORDER=(node swift)
    fi
    PAIR_ORDER_LABEL="${PAIR_ORDER[0]}/${PAIR_ORDER[1]}"
    for CLIENT_KIND in "${PAIR_ORDER[@]}"; do
        POSITION=$((POSITION + 1))
        printf -v POSITION_LABEL '%02d' "$POSITION"
        printf -v PAIR_LABEL '%02d' "$PAIR"
        run_one "$CLIENT_KIND" "$POSITION_LABEL" "$PAIR_LABEL" "$PAIR_ORDER_LABEL"
    done
    PAIR=$((PAIR + 1))
done

[[ "${#RESULTS[@]}" -eq 20 ]] || fail "internal error: expected exactly twenty process results"

# Bind the aggregate to the same clean commit captured before compilation and
# sampling. A concurrent checkout or source edit invalidates all evidence.
verify_source_tree
FINAL_SOURCE_COMMIT="$(git -C "$REPO_ROOT" rev-parse HEAD)"
[[ "$FINAL_SOURCE_COMMIT" == "$SOURCE_COMMIT" ]] \
    || fail "source commit changed while benchmark evidence was being recorded"

ANALYSIS_LOG="$EVIDENCE_DIR/analysis.log"
ANALYSIS_STATUS=0
if (
    cd "$REPO_ROOT"
    exec "$NODE_BIN" "$SCRIPT_DIR/analyze.mjs" "$RESULT_FILE" "$WORKLOAD" "${RESULTS[@]}"
) >"$ANALYSIS_LOG" 2>&1; then
    ANALYSIS_STATUS=0
else
    ANALYSIS_STATUS=$?
fi
# The analyzer itself is a benchmark input. Close the pre-analysis check/use
# race before accepting its report or publishing it as grant evidence.
verify_source_tree
POST_ANALYSIS_SOURCE_COMMIT="$(git -C "$REPO_ROOT" rev-parse HEAD)"
[[ "$POST_ANALYSIS_SOURCE_COMMIT" == "$SOURCE_COMMIT" ]] \
    || fail "source commit changed while benchmark evidence was being analyzed"
cat "$ANALYSIS_LOG"
[[ -f "$RESULT_FILE" && ! -L "$RESULT_FILE" && -s "$RESULT_FILE" ]] \
    || fail "analyzer did not atomically publish a result"
echo "[bench] wrote $RESULT_FILE and preserved inputs under $EVIDENCE_DIR"
if [[ "$ANALYSIS_STATUS" -ne 0 ]]; then
    echo "[bench] error: KR-2 result did not pass (analyzer exit $ANALYSIS_STATUS)" >&2
    exit "$ANALYSIS_STATUS"
fi
