#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
OUTPUT="${1:-$SCRIPT_DIR/.build/artifacts}"

if [[ "$OUTPUT" == *".."* ]]; then
    echo "[link-ios] error: output must not contain '..' path components" >&2
    exit 2
fi
OUTPUT_BASENAME="$(basename "$OUTPUT")"
if [[ "$OUTPUT_BASENAME" == "." || "$OUTPUT_BASENAME" == ".." || -z "$OUTPUT_BASENAME" ]]; then
    echo "[link-ios] error: output must name a strict child directory" >&2
    exit 2
fi
if [[ -L "$SCRIPT_DIR/.build" ]]; then
    echo "[link-ios] error: refusing symlinked tool-owned build root" >&2
    exit 2
fi
mkdir -p "$SCRIPT_DIR/.build"
BUILD_ROOT="$(cd -P "$SCRIPT_DIR/.build" && pwd -P)"
OUTPUT_PARENT="$(dirname "$OUTPUT")"
if [[ ! -d "$OUTPUT_PARENT" || -L "$OUTPUT_PARENT" ]]; then
    echo "[link-ios] error: output parent must be the real tool-owned build root" >&2
    exit 2
fi
OUTPUT_PARENT_REAL="$(cd -P "$OUTPUT_PARENT" && pwd -P)"
OUTPUT_REAL="$OUTPUT_PARENT_REAL/$OUTPUT_BASENAME"
if [[ "$OUTPUT_PARENT_REAL" != "$BUILD_ROOT" || "$OUTPUT_REAL" == "$BUILD_ROOT" ]]; then
    echo "[link-ios] error: canonical output must be a direct child of $BUILD_ROOT" >&2
    exit 2
fi
if [[ -L "$OUTPUT" ]]; then
    echo "[link-ios] error: refusing to replace a symlink output" >&2
    exit 2
fi
OUTPUT="$OUTPUT_REAL"

bash "$SCRIPT_DIR/bootstrap.sh"
rm -rf "$OUTPUT"
mkdir -p "$OUTPUT"

node "$SCRIPT_DIR/node_modules/bare-link/bin.js" "$SCRIPT_DIR" \
    --host ios-arm64 \
    --host ios-arm64-simulator \
    --host ios-x64-simulator \
    --out "$OUTPUT"

cp -R "$SCRIPT_DIR/node_modules/react-native-bare-kit/ios/BareKit.xcframework" "$OUTPUT/BareKit.xcframework"

# react-native-bare-kit's published XCFramework contains an Objective-C umbrella
# header but no Clang module map. CocoaPods synthesizes one, whereas SwiftPM
# binary targets require it in the artifact itself for `import BareKit` to work.
# Install the same deterministic map in every staged slice before checksumming or
# packaging; release archives therefore contain exactly what external consumers
# compile against.
BARE_KIT_SLICE_COUNT=0
for FRAMEWORK in "$OUTPUT/BareKit.xcframework"/*/BareKit.framework; do
    if [[ ! -d "$FRAMEWORK" || ! -f "$FRAMEWORK/Headers/BareKit.h" ]]; then
        echo "[link-ios] error: malformed BareKit framework slice: $FRAMEWORK" >&2
        exit 1
    fi
    mkdir -p "$FRAMEWORK/Modules"
    cp "$SCRIPT_DIR/BareKit.modulemap" "$FRAMEWORK/Modules/module.modulemap"
    BARE_KIT_SLICE_COUNT=$((BARE_KIT_SLICE_COUNT + 1))
done
if [[ "$BARE_KIT_SLICE_COUNT" -lt 2 ]]; then
    echo "[link-ios] error: expected device and simulator BareKit slices" >&2
    exit 1
fi

echo "[link-ios] staged $(find "$OUTPUT" -maxdepth 1 -type d -name '*.xcframework' | wc -l | tr -d ' ') xcframeworks"
