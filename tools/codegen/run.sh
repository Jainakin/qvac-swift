#!/usr/bin/env bash
# Regenerate every generated Swift file under Sources/QVACClient/Generated/
# from the current QVAC SDK schemas. CI calls this then `git diff --exit-code`
# to verify the checked-in output is up to date.
#
# Env:
#   QVAC_SCHEMAS_DIR  Override source-of-truth schemas dir
#                     (default: <repo>/qvac-sparse/packages/sdk/schemas)
#   QVAC_COMMON_JS    Override built JS for type generation
#                     (default: <repo>/spike-js/node_modules/@qvac/sdk/dist/schemas/common.js)

set -euo pipefail

# Force C locale so JS string sort + property orderings are deterministic across
# platforms (avoids locale-dependent drift in generated output).
export LC_ALL=C
export LANG=C

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$SCRIPT_DIR"

if [ ! -d node_modules ]; then
    echo "[codegen] installing JS deps (one-time)..."
    npm install --no-fund --no-audit --silent
fi

START=$(date +%s)
node generate-errors.mjs
node generate-types.mjs
END=$(date +%s)
echo "[codegen] done in $((END - START))s"
