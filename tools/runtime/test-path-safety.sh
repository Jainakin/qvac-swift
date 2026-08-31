#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

expect_rejected() {
    local candidate="$1"
    if bash "$SCRIPT_DIR/link-ios-artifacts.sh" "$candidate" >/dev/null 2>&1; then
        echo "[path-safety] unsafe output was accepted: $candidate" >&2
        exit 1
    fi
}

# These checks fail before bootstrap/linking. In particular, the traversal case
# must never reach rm -rf even though its raw spelling begins under .build.
expect_rejected "$SCRIPT_DIR/.build/../.."
expect_rejected "$SCRIPT_DIR/.build"
expect_rejected "$SCRIPT_DIR/.build/."
expect_rejected "$SCRIPT_DIR/artifacts"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
make_link_fixture() {
    local fixture="$1"
    mkdir -p "$fixture/tools/runtime"
    cp "$SCRIPT_DIR/link-ios-artifacts.sh" "$fixture/tools/runtime/link-ios-artifacts.sh"
}

make_bundle_fixture() {
    local fixture="$1"
    mkdir -p "$fixture/tools/runtime"
    cp "$SCRIPT_DIR/bundle-worker.sh" "$fixture/tools/runtime/bundle-worker.sh"
}

make_package_fixture() {
    local fixture="$1"
    mkdir -p "$fixture/tools/release" "$fixture/tools/runtime"
    cp "$SCRIPT_DIR/../release/package-artifacts.mjs" "$fixture/tools/release/package-artifacts.mjs"
    cp "$SCRIPT_DIR/../release/verify-bundle-provenance.mjs" "$fixture/tools/release/verify-bundle-provenance.mjs"
    cp "$SCRIPT_DIR/../release/zip-artifact.mjs" "$fixture/tools/release/zip-artifact.mjs"
}

VICTIM="$WORK_DIR/victim"
mkdir -p "$VICTIM"
touch "$VICTIM/do-not-delete"

BUILD_LINK_FIXTURE="$WORK_DIR/build-link-fixture"
make_link_fixture "$BUILD_LINK_FIXTURE"
ln -s "$VICTIM" "$BUILD_LINK_FIXTURE/tools/runtime/.build"
if bash "$BUILD_LINK_FIXTURE/tools/runtime/link-ios-artifacts.sh" >/dev/null 2>&1; then
    echo "[path-safety] symlinked .build root was accepted" >&2
    exit 1
fi

OUTPUT_LINK_FIXTURE="$WORK_DIR/output-link-fixture"
make_link_fixture "$OUTPUT_LINK_FIXTURE"
mkdir -p "$OUTPUT_LINK_FIXTURE/tools/runtime/.build"
ln -s "$VICTIM" "$OUTPUT_LINK_FIXTURE/tools/runtime/.build/artifacts"
if bash "$OUTPUT_LINK_FIXTURE/tools/runtime/link-ios-artifacts.sh" >/dev/null 2>&1; then
    echo "[path-safety] symlinked deletion target was accepted" >&2
    exit 1
fi
if [[ ! -f "$VICTIM/do-not-delete" ]]; then
    echo "[path-safety] symlink target was modified or deleted" >&2
    exit 1
fi

BUNDLE_BUILD_LINK_FIXTURE="$WORK_DIR/bundle-build-link-fixture"
make_bundle_fixture "$BUNDLE_BUILD_LINK_FIXTURE"
ln -s "$VICTIM" "$BUNDLE_BUILD_LINK_FIXTURE/tools/runtime/.build"
if QVAC_BUNDLE_BUILD_ID=escape \
    bash "$BUNDLE_BUILD_LINK_FIXTURE/tools/runtime/bundle-worker.sh" >/dev/null 2>&1; then
    echo "[path-safety] bundle-worker accepted a symlinked .build root" >&2
    exit 1
fi

BUNDLE_WORK_LINK_FIXTURE="$WORK_DIR/bundle-work-link-fixture"
make_bundle_fixture "$BUNDLE_WORK_LINK_FIXTURE"
mkdir -p "$BUNDLE_WORK_LINK_FIXTURE/tools/runtime/.build"
ln -s "$VICTIM" "$BUNDLE_WORK_LINK_FIXTURE/tools/runtime/.build/bundle-escape"
if QVAC_BUNDLE_BUILD_ID=escape \
    bash "$BUNDLE_WORK_LINK_FIXTURE/tools/runtime/bundle-worker.sh" >/dev/null 2>&1; then
    echo "[path-safety] bundle-worker accepted a symlinked work directory" >&2
    exit 1
fi

BUNDLE_QVAC_LINK_FIXTURE="$WORK_DIR/bundle-qvac-link-fixture"
make_bundle_fixture "$BUNDLE_QVAC_LINK_FIXTURE"
mkdir -p "$BUNDLE_QVAC_LINK_FIXTURE/tools/runtime/.build/bundle-escape"
ln -s "$VICTIM" "$BUNDLE_QVAC_LINK_FIXTURE/tools/runtime/.build/bundle-escape/qvac"
if QVAC_BUNDLE_BUILD_ID=escape \
    bash "$BUNDLE_QVAC_LINK_FIXTURE/tools/runtime/bundle-worker.sh" >/dev/null 2>&1; then
    echo "[path-safety] bundle-worker accepted a symlinked generated qvac directory" >&2
    exit 1
fi

BUNDLE_OUTPUT_LINK_FIXTURE="$WORK_DIR/bundle-output-link-fixture"
make_bundle_fixture "$BUNDLE_OUTPUT_LINK_FIXTURE"
mkdir -p "$BUNDLE_OUTPUT_LINK_FIXTURE/tools/runtime/.build"
ln -s "$VICTIM/do-not-delete" \
    "$BUNDLE_OUTPUT_LINK_FIXTURE/tools/runtime/.build/worker.mobile.bundle"
if QVAC_BUNDLE_BUILD_ID=escape \
    bash "$BUNDLE_OUTPUT_LINK_FIXTURE/tools/runtime/bundle-worker.sh" >/dev/null 2>&1; then
    echo "[path-safety] bundle-worker accepted a symlinked bundle output" >&2
    exit 1
fi
if [[ ! -f "$VICTIM/do-not-delete" ]]; then
    echo "[path-safety] bundle-worker modified or deleted a symlink target" >&2
    exit 1
fi

PACKAGE_FRAMEWORK_LINK_FIXTURE="$WORK_DIR/package-framework-link-fixture"
make_package_fixture "$PACKAGE_FRAMEWORK_LINK_FIXTURE"
mkdir -p "$PACKAGE_FRAMEWORK_LINK_FIXTURE/tools/runtime/.build"
ln -s "$VICTIM" "$PACKAGE_FRAMEWORK_LINK_FIXTURE/tools/runtime/.build/artifacts"
touch "$PACKAGE_FRAMEWORK_LINK_FIXTURE/tools/runtime/.build/link-set.json"
touch "$PACKAGE_FRAMEWORK_LINK_FIXTURE/tools/runtime/.build/worker.bundle"
if node "$PACKAGE_FRAMEWORK_LINK_FIXTURE/tools/release/package-artifacts.mjs" \
    "$PACKAGE_FRAMEWORK_LINK_FIXTURE/tools/runtime/.build/artifacts" \
    "$PACKAGE_FRAMEWORK_LINK_FIXTURE/tools/runtime/.build/link-set.json" \
    "$PACKAGE_FRAMEWORK_LINK_FIXTURE/tools/runtime/.build/worker.bundle" \
    "$PACKAGE_FRAMEWORK_LINK_FIXTURE/tools/runtime/.build/release-assets" >/dev/null 2>&1; then
    echo "[path-safety] package-artifacts accepted a symlinked mutable framework input" >&2
    exit 1
fi

PACKAGE_OUTPUT_LINK_FIXTURE="$WORK_DIR/package-output-link-fixture"
make_package_fixture "$PACKAGE_OUTPUT_LINK_FIXTURE"
mkdir -p "$PACKAGE_OUTPUT_LINK_FIXTURE/tools/runtime/.build/artifacts"
touch "$PACKAGE_OUTPUT_LINK_FIXTURE/tools/runtime/.build/link-set.json"
touch "$PACKAGE_OUTPUT_LINK_FIXTURE/tools/runtime/.build/worker.bundle"
ln -s "$VICTIM" "$PACKAGE_OUTPUT_LINK_FIXTURE/tools/runtime/.build/release-assets"
if node "$PACKAGE_OUTPUT_LINK_FIXTURE/tools/release/package-artifacts.mjs" \
    "$PACKAGE_OUTPUT_LINK_FIXTURE/tools/runtime/.build/artifacts" \
    "$PACKAGE_OUTPUT_LINK_FIXTURE/tools/runtime/.build/link-set.json" \
    "$PACKAGE_OUTPUT_LINK_FIXTURE/tools/runtime/.build/worker.bundle" \
    "$PACKAGE_OUTPUT_LINK_FIXTURE/tools/runtime/.build/release-assets" >/dev/null 2>&1; then
    echo "[path-safety] package-artifacts accepted a symlinked deletion target" >&2
    exit 1
fi
if [[ ! -f "$VICTIM/do-not-delete" ]]; then
    echo "[path-safety] package-artifacts modified or deleted a symlink target" >&2
    exit 1
fi

if node "$SCRIPT_DIR/../release/package-artifacts.mjs" \
    "$SCRIPT_DIR/.build/artifacts" \
    "$SCRIPT_DIR/.build/link-set.json" \
    "$SCRIPT_DIR/.build/worker.repro-a.bundle" \
    "$SCRIPT_DIR/.build/artifacts" >/dev/null 2>&1; then
    echo "[path-safety] package-artifacts accepted output equal to framework input" >&2
    exit 1
fi

echo "[path-safety] traversal, bundle/package symlink roots and targets, and input/output overlap rejected"
