#!/usr/bin/env bash
# tools/dev/vendor-from-release.sh — vendor xcframeworks the committed bundle needs.
#
# WHAT THIS FIXES
# ---------------
# The committed iOS bundle (`Sources/QVACClient/Resources/worker.mobile.bundle`)
# references ~34 native addons by name+version via its `addons` field. For the
# worker to start up on iOS, EACH addon must be linked into the host app as an
# xcframework — BareKit alone is not enough, because the worker bundle's first
# `require()` resolution touches `bare-buffer`, `bare-fs`, `bare-os`, etc., which
# all rely on native code.
#
# This script reads the bundle's `addons` list, looks at a GitHub release, and
# vendors the matching xcframeworks into `spike-swift/Vendor/`. The dev-mode
# Package.swift can then declare them as path-based binaryTargets.
#
# Usage:
#   tools/dev/vendor-from-release.sh v0.0.1-rc1
#
# Pre-conditions:
#   - The release tag exists on GitHub.
#   - `gh` CLI is authenticated.
#   - Node 18+ is on PATH (for bundle parsing).
#
# Post-conditions:
#   - Each matching xcframework is unzipped into spike-swift/Vendor/.
#   - Missing-from-release addons are listed; the script exits non-zero.
#
# Idempotency: re-running is safe. Existing xcframework dirs are left in place
# unless the script downloads a different version (in which case the old
# one is overwritten).

set -euo pipefail

VERSION="${1:-}"
if [ -z "$VERSION" ]; then
    echo "usage: $0 <version>   (e.g. v0.0.1-rc1)" >&2
    exit 2
fi

REPO_ROOT="$( cd "$( dirname "${BASH_SOURCE[0]}" )/../.." && pwd )"
cd "$REPO_ROOT"

REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner)"
VENDOR_DIR="$REPO_ROOT/spike-swift/Vendor"
BUNDLE_PATH="$REPO_ROOT/Sources/QVACClient/Resources/worker.mobile.bundle"

if [ ! -f "$BUNDLE_PATH" ]; then
    echo "[vendor] error: $BUNDLE_PATH not found. Run unwrap-bundle.mjs first." >&2
    exit 3
fi

mkdir -p "$VENDOR_DIR"

# Extract the bundle's required addons (name+version pairs). We use the
# bare-bundle library (committed in spike-js/node_modules) for parsing
# because hand-rolled offset math hits UTF-8 byte/char drift on the JSON header.
NEEDED=$(cd "$REPO_ROOT/spike-js" && node -e "
const fs = require('fs')
const Bundle = require('bare-bundle')
const buf = fs.readFileSync('$BUNDLE_PATH')
const b = Bundle.from(buf)
const set = new Set()
for (const v of Object.values(b.addons || {})) {
  const m = v.match(/^linked:(.+)\.framework\//)
  if (m) set.add(m[1])
}
process.stdout.write([...set].sort().join('\n'))
")

if [ -z "$NEEDED" ]; then
    echo "[vendor] error: bundle has no addons. Something is wrong with the bundle." >&2
    exit 4
fi

echo "[vendor] bundle requires $(echo "$NEEDED" | wc -l | tr -d ' ') addons"

# Pull release inventory once.
INVENTORY=$(gh release view "$VERSION" --repo "$REPO" --json assets -q '.assets[].name' | grep '\.xcframework\.zip$' | sed 's/\.xcframework\.zip$//')

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

MISSING=()
DOWNLOADED=0
SKIPPED=0

while IFS= read -r addon; do
    if [ -d "$VENDOR_DIR/$addon.xcframework" ]; then
        echo "[vendor] $addon: already vendored, skipping"
        SKIPPED=$((SKIPPED + 1))
        continue
    fi
    if echo "$INVENTORY" | grep -qx "$addon"; then
        echo "[vendor] $addon: downloading..."
        gh release download "$VERSION" --repo "$REPO" \
            --pattern "$addon.xcframework.zip" --dir "$WORK"
        # Unzip into Vendor/ (the zip contains a top-level <name>.xcframework dir).
        ( cd "$VENDOR_DIR" && unzip -q "$WORK/$addon.xcframework.zip" )
        if [ ! -d "$VENDOR_DIR/$addon.xcframework" ]; then
            echo "[vendor] error: unzip didn't produce $VENDOR_DIR/$addon.xcframework" >&2
            exit 5
        fi
        DOWNLOADED=$((DOWNLOADED + 1))
    else
        MISSING+=("$addon")
    fi
done <<<"$NEEDED"

echo
echo "[vendor] ✅ downloaded $DOWNLOADED, skipped $SKIPPED (already present)"
if [ "${#MISSING[@]}" -gt 0 ]; then
    echo "[vendor] ⚠️  $(echo "${MISSING[@]}" | wc -w | tr -d ' ') addons NOT in release $VERSION:"
    for m in "${MISSING[@]}"; do
        echo "         $m"
    done
    echo
    echo "[vendor] To fix: either"
    echo "  (a) regenerate the bundle to use versions that exist in the release, OR"
    echo "  (b) build the missing addons locally via bare-link and copy into $VENDOR_DIR/"
    exit 6
fi
