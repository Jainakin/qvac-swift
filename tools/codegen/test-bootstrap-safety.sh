#!/usr/bin/env bash
# Regression test: an explicit QVAC_UPSTREAM_DIR is caller-owned and must never
# be fetched, sparse-converted, or force-checked-out by bootstrap.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

git -C "$WORKDIR" init -q
git -C "$WORKDIR" config user.name qvac-bootstrap-test
git -C "$WORKDIR" config user.email qvac-bootstrap-test@example.invalid
touch "$WORKDIR/sentinel"
git -C "$WORKDIR" add sentinel
git -C "$WORKDIR" commit -qm sentinel
git -C "$WORKDIR" remote add origin https://github.com/tetherto/qvac.git

BEFORE="$(git -C "$WORKDIR" rev-parse HEAD)"
if QVAC_ALLOW_NODE_VERSION_MISMATCH=1 QVAC_UPSTREAM_DIR="$WORKDIR" bash "$SCRIPT_DIR/bootstrap.sh" >/dev/null 2>&1; then
    echo "[bootstrap-safety] error: mismatched caller checkout unexpectedly succeeded" >&2
    exit 1
fi
AFTER="$(git -C "$WORKDIR" rev-parse HEAD)"

if [[ "$BEFORE" != "$AFTER" || ! -f "$WORKDIR/sentinel" ]]; then
    echo "[bootstrap-safety] error: caller-owned checkout was modified" >&2
    exit 1
fi
echo "[bootstrap-safety] caller-owned checkout remained untouched"

make_bootstrap_fixture() {
    local fixture="$1"
    mkdir -p "$fixture/tools/codegen" "$fixture/tools/provenance"
    cp "$SCRIPT_DIR/bootstrap.sh" "$fixture/tools/codegen/bootstrap.sh"
    cp "$SCRIPT_DIR/../provenance/qvac-sdk.lock.json" "$fixture/tools/provenance/qvac-sdk.lock.json"
}

# A symlink at the default source path must be rejected before sparse-checkout,
# fetch, or checkout can touch its target repository.
VICTIM="$WORKDIR/victim"
git -C "$WORKDIR" init -q victim
git -C "$VICTIM" config user.name qvac-bootstrap-test
git -C "$VICTIM" config user.email qvac-bootstrap-test@example.invalid
touch "$VICTIM/do-not-modify"
git -C "$VICTIM" add do-not-modify
git -C "$VICTIM" commit -qm sentinel
git -C "$VICTIM" remote add origin https://github.com/tetherto/qvac.git
VICTIM_BEFORE="$(git -C "$VICTIM" rev-parse HEAD)"

SOURCE_LINK_FIXTURE="$WORKDIR/source-link-fixture"
make_bootstrap_fixture "$SOURCE_LINK_FIXTURE"
mkdir -p "$SOURCE_LINK_FIXTURE/tools/codegen/.build"
ln -s "$VICTIM" "$SOURCE_LINK_FIXTURE/tools/codegen/.build/qvac-sdk"
if QVAC_ALLOW_NODE_VERSION_MISMATCH=1 bash "$SOURCE_LINK_FIXTURE/tools/codegen/bootstrap.sh" >/dev/null 2>&1; then
    echo "[bootstrap-safety] error: symlinked default source unexpectedly succeeded" >&2
    exit 1
fi

# The parent .build component is equally dangerous and must also be rejected.
BUILD_LINK_FIXTURE="$WORKDIR/build-link-fixture"
EXTERNAL_BUILD="$WORKDIR/external-build"
make_bootstrap_fixture "$BUILD_LINK_FIXTURE"
mkdir -p "$EXTERNAL_BUILD"
ln -s "$EXTERNAL_BUILD" "$BUILD_LINK_FIXTURE/tools/codegen/.build"
ln -s "$VICTIM" "$EXTERNAL_BUILD/qvac-sdk"
if QVAC_ALLOW_NODE_VERSION_MISMATCH=1 bash "$BUILD_LINK_FIXTURE/tools/codegen/bootstrap.sh" >/dev/null 2>&1; then
    echo "[bootstrap-safety] error: symlinked default build root unexpectedly succeeded" >&2
    exit 1
fi

VICTIM_AFTER="$(git -C "$VICTIM" rev-parse HEAD)"
if [[ "$VICTIM_BEFORE" != "$VICTIM_AFTER" || ! -f "$VICTIM/do-not-modify" ]]; then
    echo "[bootstrap-safety] error: symlink-target checkout was modified" >&2
    exit 1
fi
echo "[bootstrap-safety] tool-owned symlink escapes were rejected before Git mutation"
