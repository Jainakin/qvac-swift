#!/usr/bin/env bash
# Validate a published artifact release against the exact, already-prepared
# source commit. This command is deliberately read-only for the repository:
# candidate Package.swift generation happens from a dry-run workflow artifact,
# before final artifact publication and source tagging.

set -euo pipefail

ARTIFACT_TAG="${1:-}"
if [[ ! "$ARTIFACT_TAG" =~ ^artifacts-sdk-0\.17\.0-r[1-9][0-9]*$ || "$#" -ne 1 ]]; then
    echo "usage: $0 artifacts-sdk-0.17.0-rN" >&2
    exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPOSITORY="$(gh repo view --json nameWithOwner --jq .nameWithOwner)"
DOWNLOAD_DIR="$(mktemp -d)"
trap 'rm -rf "$DOWNLOAD_DIR"' EXIT

cd "$REPO_ROOT"
CURRENT_COMMIT="$(git rev-parse HEAD)"
if ! git diff --quiet || ! git diff --cached --quiet; then
    echo "[prepare-release] error: tracked files must be committed before release validation" >&2
    exit 3
fi

REMOTE_REFS="$(git ls-remote --tags origin \
    "refs/tags/$ARTIFACT_TAG" "refs/tags/$ARTIFACT_TAG^{}")"
ARTIFACT_COMMIT="$(printf '%s\n' "$REMOTE_REFS" | awk '$2 ~ /\^\{\}$/ { print $1; exit }')"
if [[ -z "$ARTIFACT_COMMIT" ]]; then
    ARTIFACT_COMMIT="$(printf '%s\n' "$REMOTE_REFS" | awk 'NF == 2 { print $1; exit }')"
fi
if [[ "$ARTIFACT_COMMIT" != "$CURRENT_COMMIT" ]]; then
    echo "[prepare-release] error: $ARTIFACT_TAG resolves to $ARTIFACT_COMMIT, not current source $CURRENT_COMMIT" >&2
    exit 3
fi

echo "[prepare-release] downloading immutable artifact release $REPOSITORY@$ARTIFACT_TAG"
gh release download "$ARTIFACT_TAG" --repo "$REPOSITORY" --dir "$DOWNLOAD_DIR"
gh release verify "$ARTIFACT_TAG" --repo "$REPOSITORY" >/dev/null
for ASSET in "$DOWNLOAD_DIR"/*; do
    gh release verify-asset "$ARTIFACT_TAG" "$ASSET" \
        --repo "$REPOSITORY" >/dev/null
done
MANIFEST="$DOWNLOAD_DIR/artifact-manifest.json"
if [[ ! -f "$MANIFEST" ]]; then
    echo "[prepare-release] error: $ARTIFACT_TAG has no artifact-manifest.json" >&2
    exit 3
fi

MANIFEST_TAG="$(node -e 'const m=require(process.argv[1]); process.stdout.write(m.artifactTag ?? "")' "$MANIFEST")"
if [[ "$MANIFEST_TAG" != "$ARTIFACT_TAG" ]]; then
    echo "[prepare-release] error: manifest says $MANIFEST_TAG, expected $ARTIFACT_TAG" >&2
    exit 4
fi

node "$SCRIPT_DIR/verify-release.mjs" "$MANIFEST" \
    --source-commit "$CURRENT_COMMIT" \
    --assets-dir "$DOWNLOAD_DIR" \
    --package "$REPO_ROOT/Package.swift" \
    --bundle "$REPO_ROOT/Sources/QVACClient/Resources/worker.mobile.bundle"
swift package --package-path "$REPO_ROOT" dump-package >/dev/null

echo "[prepare-release] published artifacts, canonical URL manifest, and source commit are identical"
echo "[prepare-release] run the Source Release workflow from this exact main commit; it verifies again before creating a SemVer tag"
