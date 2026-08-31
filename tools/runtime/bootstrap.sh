#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
EXPECTED_NODE="$(node -e "const l=require(process.argv[1]); process.stdout.write(l.toolchain.node)" "$REPO_ROOT/tools/provenance/qvac-sdk.lock.json")"
ACTUAL_NODE="$(node -p 'process.versions.node')"

if [[ "$ACTUAL_NODE" != "$EXPECTED_NODE" && "${QVAC_ALLOW_NODE_VERSION_MISMATCH:-0}" != "1" ]]; then
    echo "[runtime] error: Node $EXPECTED_NODE is required; found $ACTUAL_NODE." >&2
    echo "[runtime] QVAC_ALLOW_NODE_VERSION_MISMATCH=1 is diagnostic-only and forbidden for releases." >&2
    exit 2
fi

if [[ -d "$SCRIPT_DIR/node_modules" ]] \
    && node "$SCRIPT_DIR/verify-runtime-lock.mjs" >/dev/null 2>&1 \
    && node "$SCRIPT_DIR/generate-resolution-inventory.mjs" --check >/dev/null 2>&1; then
    echo "[runtime] reusing installed graph verified against package-lock.json"
else
    npm ci --no-audit --no-fund --prefix "$SCRIPT_DIR"
fi
node "$SCRIPT_DIR/verify-runtime-lock.mjs"
node "$SCRIPT_DIR/generate-resolution-inventory.mjs" --check
