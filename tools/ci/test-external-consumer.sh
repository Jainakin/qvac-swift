#!/usr/bin/env bash

set -euo pipefail

PACKAGE_URL="${1:-}"
REFERENCE_KIND="${2:-}"
REFERENCE_VALUE="${3:-}"
if [[ ! "$PACKAGE_URL" =~ ^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\.git$ ]]; then
    echo "usage: $0 <https://github.com/owner/repo.git> <--revision sha|--version semver>" >&2
    exit 2
fi
case "$REFERENCE_KIND" in
    --revision)
        if [[ ! "$REFERENCE_VALUE" =~ ^[0-9a-f]{40}$ ]]; then
            echo "[external-consumer] --revision requires a full lowercase Git commit" >&2
            exit 2
        fi
        PACKAGE_REQUIREMENT="revision: \"$REFERENCE_VALUE\""
        ;;
    --version)
        if [[ ! "$REFERENCE_VALUE" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.-]+)?$ ]]; then
            echo "[external-consumer] --version requires a semantic version" >&2
            exit 2
        fi
        PACKAGE_REQUIREMENT="exact: \"$REFERENCE_VALUE\""
        ;;
    *)
        echo "usage: $0 <https://github.com/owner/repo.git> <--revision sha|--version semver>" >&2
        exit 2
        ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIXTURE="$SCRIPT_DIR/external-consumer"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

mkdir -p "$WORK_DIR/Sources/QVACExternalConsumer"
sed \
    -e "s|__QVAC_PACKAGE_URL__|$PACKAGE_URL|g" \
    -e "s|__QVAC_PACKAGE_REQUIREMENT__|$PACKAGE_REQUIREMENT|g" \
    "$FIXTURE/Package.swift.template" > "$WORK_DIR/Package.swift"
cp "$FIXTURE/Sources/QVACExternalConsumer/main.swift" \
    "$WORK_DIR/Sources/QVACExternalConsumer/main.swift"

swift package --package-path "$WORK_DIR" resolve
swift build --package-path "$WORK_DIR"
"$WORK_DIR/.build/debug/QVACExternalConsumer"
