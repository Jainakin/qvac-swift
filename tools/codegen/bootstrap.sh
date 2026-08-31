#!/usr/bin/env bash
# Materialize both independently pinned inputs used by code generation:
#   1. the published @qvac/sdk@0.17.0 tarball, through npm ci; and
#   2. the authoritative source release commit, through an exact Git checkout.

set -euo pipefail

export LC_ALL=C
export LANG=C

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LOCK="$REPO_ROOT/tools/provenance/qvac-sdk.lock.json"
SOURCE_DIR="${QVAC_UPSTREAM_DIR:-$SCRIPT_DIR/.build/qvac-sdk}"
SOURCE_IS_CALLER_OWNED=0
if [[ -n "${QVAC_UPSTREAM_DIR:-}" ]]; then SOURCE_IS_CALLER_OWNED=1; fi

SDK_VERSION="$(node -e "const l=require(process.argv[1]); process.stdout.write(l.sdkVersion)" "$LOCK")"
SOURCE_REPO="$(node -e "const l=require(process.argv[1]); process.stdout.write(l.source.repository)" "$LOCK")"
SOURCE_COMMIT="$(node -e "const l=require(process.argv[1]); process.stdout.write(l.source.commit)" "$LOCK")"
EXPECTED_NODE="$(node -e "const l=require(process.argv[1]); process.stdout.write(l.toolchain.node)" "$LOCK")"
ACTUAL_NODE="$(node -p 'process.versions.node')"

if [[ "$ACTUAL_NODE" != "$EXPECTED_NODE" && "${QVAC_ALLOW_NODE_VERSION_MISMATCH:-0}" != "1" ]]; then
    echo "[codegen] error: Node $EXPECTED_NODE is required; found $ACTUAL_NODE." >&2
    echo "[codegen] install/use the version in tools/codegen/.node-version, or set" >&2
    echo "[codegen] QVAC_ALLOW_NODE_VERSION_MISMATCH=1 for a non-release local diagnostic." >&2
    exit 2
fi

# Only the exact default path is tool-owned. Reject symlinks before any Git
# operation: otherwise checkout --force could mutate an unrelated repository
# reached through .build or qvac-sdk. An explicit override is caller-owned and
# remains read-only below.
if [[ "$SOURCE_IS_CALLER_OWNED" == "0" ]]; then
    BUILD_ROOT="$SCRIPT_DIR/.build"
    if [[ -L "$BUILD_ROOT" ]]; then
        echo "[codegen] error: refusing symlinked tool-owned build root: $BUILD_ROOT" >&2
        exit 3
    fi
    mkdir -p "$BUILD_ROOT"
    BUILD_ROOT_REAL="$(cd -P "$BUILD_ROOT" && pwd -P)"
    if [[ "$BUILD_ROOT_REAL" != "$SCRIPT_DIR/.build" ]]; then
        echo "[codegen] error: tool-owned build root resolved outside its canonical path: $BUILD_ROOT_REAL" >&2
        exit 3
    fi
    if [[ -L "$SOURCE_DIR" ]]; then
        echo "[codegen] error: refusing symlinked tool-owned source checkout: $SOURCE_DIR" >&2
        exit 3
    fi
    if [[ -e "$SOURCE_DIR" ]]; then
        if [[ ! -d "$SOURCE_DIR" ]]; then
            echo "[codegen] error: tool-owned source path is not a directory: $SOURCE_DIR" >&2
            exit 3
        fi
        SOURCE_REAL="$(cd -P "$SOURCE_DIR" && pwd -P)"
        if [[ "$SOURCE_REAL" != "$BUILD_ROOT_REAL/qvac-sdk" ]]; then
            echo "[codegen] error: tool-owned source resolved outside its exact child path: $SOURCE_REAL" >&2
            exit 3
        fi
        if [[ -L "$SOURCE_DIR/.git" ]]; then
            echo "[codegen] error: refusing checkout with a symlinked .git directory: $SOURCE_DIR" >&2
            exit 3
        fi
    elif [[ "$SOURCE_DIR" != "$BUILD_ROOT_REAL/qvac-sdk" ]]; then
        echo "[codegen] error: refusing non-canonical tool-owned source path: $SOURCE_DIR" >&2
        exit 3
    fi
fi

if [[ "$SOURCE_IS_CALLER_OWNED" == "1" && ! -d "$SOURCE_DIR/.git" ]]; then
    echo "[codegen] error: caller-owned QVAC_UPSTREAM_DIR is not a Git checkout: $SOURCE_DIR" >&2
    exit 3
fi

if [[ "$SOURCE_IS_CALLER_OWNED" == "0" && ! -d "$SOURCE_DIR/.git" ]]; then
    mkdir -p "$(dirname "$SOURCE_DIR")"
    git clone --filter=blob:none --no-checkout "$SOURCE_REPO" "$SOURCE_DIR"
fi

ACTUAL_REMOTE="$(git -C "$SOURCE_DIR" remote get-url origin)"
if [[ "$ACTUAL_REMOTE" != "$SOURCE_REPO" ]]; then
    echo "[codegen] error: $SOURCE_DIR has unexpected origin $ACTUAL_REMOTE" >&2
    echo "[codegen] expected $SOURCE_REPO; remove the generated checkout and retry." >&2
    exit 4
fi

if [[ "$SOURCE_IS_CALLER_OWNED" == "1" ]]; then
    ACTUAL_HEAD="$(git -C "$SOURCE_DIR" rev-parse HEAD)"
    if [[ "$ACTUAL_HEAD" != "$SOURCE_COMMIT" ]]; then
        echo "[codegen] error: caller-owned QVAC_UPSTREAM_DIR is at $ACTUAL_HEAD" >&2
        echo "[codegen] expected $SOURCE_COMMIT; the checkout was not modified." >&2
        exit 5
    fi
else
    ACTUAL_HEAD="$(git -C "$SOURCE_DIR" rev-parse HEAD 2>/dev/null || true)"
    if [[ "$ACTUAL_HEAD" == "$SOURCE_COMMIT" ]]; then
        echo "[codegen] reusing verified-commit candidate $SOURCE_DIR"
    else
        git -C "$SOURCE_DIR" sparse-checkout init --cone
        git -C "$SOURCE_DIR" sparse-checkout set packages/sdk
        git -C "$SOURCE_DIR" fetch --depth=1 origin "$SOURCE_COMMIT"
        git -C "$SOURCE_DIR" checkout --detach --force "$SOURCE_COMMIT"
    fi
fi

PACKAGE_LOCK_SHA="$(shasum -a 256 "$SCRIPT_DIR/package-lock.json" | awk '{print $1}')"
INSTALL_STAMP="$SCRIPT_DIR/node_modules/.qvac-swift-codegen-install.json"
STAMP_OK="$(node -e '
  const fs = require("fs")
  try {
    const stamp = JSON.parse(fs.readFileSync(process.argv[1], "utf8"))
    process.stdout.write(String(stamp.packageLockSHA256 === process.argv[2] && stamp.node === process.argv[3]))
  } catch { process.stdout.write("false") }
' "$INSTALL_STAMP" "$PACKAGE_LOCK_SHA" "$ACTUAL_NODE")"
if [[ "$STAMP_OK" == "true" ]] && npm ls --all --prefix "$SCRIPT_DIR" >/dev/null 2>&1; then
    echo "[codegen] reusing exact npm graph for @qvac/sdk@$SDK_VERSION"
else
    echo "[codegen] installing immutable npm graph for @qvac/sdk@$SDK_VERSION"
    npm ci --ignore-scripts --no-audit --no-fund --prefix "$SCRIPT_DIR"
    node -e '
      const fs = require("fs")
      fs.writeFileSync(process.argv[1], JSON.stringify({ packageLockSHA256: process.argv[2], node: process.argv[3] }) + "\n")
    ' "$INSTALL_STAMP" "$PACKAGE_LOCK_SHA" "$ACTUAL_NODE"
fi

export QVAC_UPSTREAM_DIR="$SOURCE_DIR"
node "$SCRIPT_DIR/verify-provenance.mjs"
node "$SCRIPT_DIR/verify-contract-parity.mjs"

echo "[codegen] verified source=$SOURCE_COMMIT npm=@qvac/sdk@$SDK_VERSION"
