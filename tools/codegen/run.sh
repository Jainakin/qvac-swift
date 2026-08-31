#!/usr/bin/env bash
# Regenerate every generated Swift file under Sources/QVACClient/Generated/
# from the immutable SDK 0.17.0 source contract. CI calls this and then compares
# to verify the checked-in output is up to date.
#
# Env:
#   QVAC_GENERATED_DIR  Override output directory (useful for drift checks).
#   QVAC_UPSTREAM_DIR   Override the exact source checkout materialized by bootstrap.sh.
#   QVAC_ALLOW_NODE_VERSION_MISMATCH=1 permits non-release local diagnostics.

set -euo pipefail

# Force C locale so JS string sort + property orderings are deterministic across
# platforms (avoids locale-dependent drift in generated output).
export LC_ALL=C
export LANG=C

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$SCRIPT_DIR"

if [[ "${1:-}" == "--generate-only" ]]; then
    export QVAC_UPSTREAM_DIR="${QVAC_UPSTREAM_DIR:-$SCRIPT_DIR/.build/qvac-sdk}"
    node "$SCRIPT_DIR/verify-provenance.mjs"
    node "$SCRIPT_DIR/verify-contract-parity.mjs"
elif [[ -n "${1:-}" ]]; then
    echo "usage: $0 [--generate-only]" >&2
    exit 2
else
    "$SCRIPT_DIR/bootstrap.sh"
fi

export QVAC_UPSTREAM_DIR="${QVAC_UPSTREAM_DIR:-$SCRIPT_DIR/.build/qvac-sdk}"

START=$(date +%s)
node generate-errors.mjs
node generate-types.mjs
node generate-model-type-maps.mjs
node generate-api.mjs
node verify-generated-output.mjs
END=$(date +%s)
echo "[codegen] done in $((END - START))s"
