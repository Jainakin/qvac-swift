#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPOSITORY_ROOT="$(cd -P "$SCRIPT_DIR/../.." && pwd -P)"
ANALYZER="$SCRIPT_DIR/analyze-ios-transport.mjs"
POLICY="$SCRIPT_DIR/ios-transport-policy.json"

if [[ "${1:-}" == "--self-test" ]]; then
    if [[ "$#" -ne 1 ]]; then
        echo "usage: $0 --self-test" >&2
        exit 2
    fi
    node "$ANALYZER" --self-test
    exit 0
fi

if [[ "$#" -ne 3 ]]; then
    echo "usage: $0 <DerivedData> <xcodebuild.log> <evidence-directory>" >&2
    exit 2
fi

DERIVED_DATA="$1"
TEST_LOG="$2"
EVIDENCE="$3"
BINARY="$DERIVED_DATA/Build/Products/Debug-iphonesimulator/QVACiOSSmokeTests.xctest/QVACiOSSmokeTests"

for INPUT in "$DERIVED_DATA" "$TEST_LOG" "$POLICY" "$BINARY"; do
    if [[ -L "$INPUT" || ! -e "$INPUT" ]]; then
        echo "[ios-transport-coverage] missing or symlinked input: $INPUT" >&2
        exit 1
    fi
done

SOURCES=()
while IFS= read -r RELATIVE_SOURCE; do
    SOURCES+=("$REPOSITORY_ROOT/$RELATIVE_SOURCE")
done < <(node -e '
const fs = require("node:fs")
const policy = JSON.parse(fs.readFileSync(process.argv[1], "utf8"))
if (!Array.isArray(policy.sources) || policy.sources.length === 0) process.exit(2)
for (const source of policy.sources) {
    if (!source || typeof source.path !== "string" || source.path.includes("\n")) process.exit(2)
    process.stdout.write(`${source.path}\n`)
}
' "$POLICY")
if [[ "${#SOURCES[@]}" -eq 0 ]]; then
    echo "[ios-transport-coverage] policy did not declare any sources" >&2
    exit 1
fi
for SOURCE in "${SOURCES[@]}"; do
    if [[ -L "$SOURCE" || ! -f "$SOURCE" ]]; then
        echo "[ios-transport-coverage] missing or symlinked source: $SOURCE" >&2
        exit 1
    fi
done
if [[ -e "$EVIDENCE" ]]; then
    if [[ -L "$EVIDENCE" || ! -d "$EVIDENCE" || -n "$(find "$EVIDENCE" -mindepth 1 -print -quit)" ]]; then
        echo "[ios-transport-coverage] evidence directory must be absent or empty and non-symlinked" >&2
        exit 1
    fi
else
    mkdir -p "$EVIDENCE"
fi

PROFILE=""
PROFILE_COUNT=0
while IFS= read -r CANDIDATE; do
    PROFILE="$CANDIDATE"
    PROFILE_COUNT=$((PROFILE_COUNT + 1))
done < <(
    find "$DERIVED_DATA/Build/ProfileData" -type f -name Coverage.profdata -print
)
if [[ "$PROFILE_COUNT" -ne 1 || -L "$PROFILE" || ! -f "$PROFILE" ]]; then
    echo "[ios-transport-coverage] expected exactly one regular Coverage.profdata; found $PROFILE_COUNT" >&2
    exit 1
fi

RAW_TEMP="$EVIDENCE/llvm-ios-transport-coverage.json.tmp"
RAW_REPORT="$EVIDENCE/llvm-ios-transport-coverage.json"
SUMMARY="$EVIDENCE/ios-transport-coverage-summary.json"
MARKDOWN="$EVIDENCE/ios-transport-coverage-summary.md"
xcrun llvm-cov export "$BINARY" \
    -instr-profile="$PROFILE" \
    "${SOURCES[@]}" > "$RAW_TEMP"
mv "$RAW_TEMP" "$RAW_REPORT"
node "$ANALYZER" "$RAW_REPORT" "$TEST_LOG" "$SUMMARY" "$MARKDOWN"
