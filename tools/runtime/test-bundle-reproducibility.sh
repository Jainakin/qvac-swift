#!/usr/bin/env bash
# Build the exact worker twice from separate tool-owned roots and require the
# complete portable bare-bundle bytes (therefore its content ID) to match.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXPECTED_NODE="$(node -e "const l=require(process.argv[1]); process.stdout.write(l.toolchain.node)" "$SCRIPT_DIR/../provenance/qvac-sdk.lock.json")"
ACTUAL_NODE="$(node -p 'process.versions.node')"
if [[ "$ACTUAL_NODE" != "$EXPECTED_NODE" ]]; then
    echo "[bundle-repro] error: Node $EXPECTED_NODE is required; found $ACTUAL_NODE" >&2
    exit 2
fi

FIRST="$SCRIPT_DIR/.build/worker.repro-a.bundle"
SECOND="$SCRIPT_DIR/.build/worker.repro-b.bundle"

QVAC_BUNDLE_BUILD_ID=repro-a bash "$SCRIPT_DIR/bundle-worker.sh" "$FIRST"
QVAC_BUNDLE_BUILD_ID=repro-b bash "$SCRIPT_DIR/bundle-worker.sh" "$SECOND"

if ! cmp -s "$FIRST" "$SECOND"; then
    echo "[bundle-repro] error: builds from bundle-repro-a and bundle-repro-b differ" >&2
    shasum -a 256 "$FIRST" "$SECOND" >&2
    exit 1
fi

node "$SCRIPT_DIR/../release/verify-bundle-provenance.mjs" "$FIRST"
SHA="$(shasum -a 256 "$FIRST" | awk '{print $1}')"
echo "[bundle-repro] byte-identical across two roots: sha256=$SHA"
