#!/usr/bin/env bash
# Rebuild the mobile worker from the independently identified exact runtime graph.
# Output remains in tools/runtime/.build until the matching addon artifact set and
# release manifest have passed the artifact-first preflight.

set -euo pipefail

export LC_ALL=C
export LANG=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BUILD_ID="${QVAC_BUNDLE_BUILD_ID:-work}"
if [[ ! "$BUILD_ID" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
    echo "[runtime] error: QVAC_BUNDLE_BUILD_ID must be a simple path-free identifier" >&2
    exit 2
fi
BUILD_ROOT="$SCRIPT_DIR/.build"
OUTPUT="${1:-$BUILD_ROOT/worker.mobile.bundle}"

# Every mutable path is a direct descendant of the real tool-owned build root.
# Check this before bootstrap or deletion: a symlinked `.build`, work directory,
# qvac output, or bundle output must never redirect generation into caller data.
if [[ -L "$BUILD_ROOT" ]]; then
    echo "[runtime] error: refusing symlinked tool-owned build root" >&2
    exit 2
fi
mkdir -p "$BUILD_ROOT"
BUILD_ROOT_REAL="$(cd -P "$BUILD_ROOT" && pwd -P)"
if [[ "$BUILD_ROOT_REAL" != "$SCRIPT_DIR/.build" ]]; then
    echo "[runtime] error: canonical build root escaped tools/runtime" >&2
    exit 2
fi

WORK_DIR="$BUILD_ROOT_REAL/bundle-$BUILD_ID"
if [[ -L "$WORK_DIR" ]]; then
    echo "[runtime] error: refusing symlinked bundle work directory" >&2
    exit 2
fi
if [[ -e "$WORK_DIR" && ! -d "$WORK_DIR" ]]; then
    echo "[runtime] error: bundle work path is not a directory" >&2
    exit 2
fi
mkdir -p "$WORK_DIR"
WORK_DIR_REAL="$(cd -P "$WORK_DIR" && pwd -P)"
if [[ "$(dirname "$WORK_DIR_REAL")" != "$BUILD_ROOT_REAL" ]]; then
    echo "[runtime] error: canonical bundle work directory escaped the build root" >&2
    exit 2
fi

QVAC_DIR="$WORK_DIR_REAL/qvac"
if [[ -L "$QVAC_DIR" ]]; then
    echo "[runtime] error: refusing symlinked generated qvac directory" >&2
    exit 2
fi

OUTPUT_BASENAME="$(basename "$OUTPUT")"
OUTPUT_PARENT="$(dirname "$OUTPUT")"
if [[ ! "$OUTPUT_BASENAME" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*\.bundle$ \
    || ! -d "$OUTPUT_PARENT" || -L "$OUTPUT_PARENT" ]]; then
    echo "[runtime] error: bundle output must be a path-safe direct .bundle child of $BUILD_ROOT_REAL" >&2
    exit 2
fi
OUTPUT_PARENT_REAL="$(cd -P "$OUTPUT_PARENT" && pwd -P)"
if [[ "$OUTPUT_PARENT_REAL" != "$BUILD_ROOT_REAL" || -L "$OUTPUT" ]]; then
    echo "[runtime] error: refusing non-canonical or symlinked bundle output" >&2
    exit 2
fi
OUTPUT="$BUILD_ROOT_REAL/$OUTPUT_BASENAME"

bash "$SCRIPT_DIR/bootstrap.sh"

# All components were resolved without following symlinks before this deletion.
rm -rf "$QVAC_DIR"

pushd "$WORK_DIR" >/dev/null
node "$SCRIPT_DIR/node_modules/@qvac/cli/dist/index.js" bundle sdk \
    --sdk-path "$SCRIPT_DIR/node_modules/@qvac/sdk" \
    --host ios-arm64 \
    --host ios-arm64-simulator \
    --host ios-x64-simulator \
    --quiet

node "$SCRIPT_DIR/embed-sdk-provenance.mjs" "$QVAC_DIR/worker.entry.mjs"

# Re-pack once after adding the non-tree-shakeable SDK metadata import. Running
# from WORK_DIR keeps every virtual bundle path portable (no local absolute path).
node "$SCRIPT_DIR/node_modules/bare-pack/bin.js" \
    --host ios-arm64 \
    --host ios-arm64-simulator \
    --host ios-x64-simulator \
    --linked \
    --imports "$SCRIPT_DIR/node_modules/@qvac/sdk/bare-imports.json" \
    --out "$QVAC_DIR/worker.provenance.bundle.js" \
    "$QVAC_DIR/worker.entry.mjs"
popd >/dev/null

node "$REPO_ROOT/tools/bundle/unwrap-bundle.mjs" \
    "$QVAC_DIR/worker.provenance.bundle.js" \
    "$OUTPUT"
node "$REPO_ROOT/tools/release/verify-bundle-provenance.mjs" "$OUTPUT"

echo "[runtime] fresh SDK 0.17.0 bundle staged at $OUTPUT"
