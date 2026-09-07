#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPOSITORY_ROOT="$(cd -P "$SCRIPT_DIR/../../.." && pwd -P)"
LOCK="$SCRIPT_DIR/provenance.lock.json"
PATCH="$SCRIPT_DIR/bare-kit-2.3.0-qvac.patch"
BUILD_MODE="candidate"
if [[ "${1:-}" == "--thread-sanitizer-simulator" ]]; then
    if [[ "$#" -ne 1 ]]; then
        echo "usage: $0 [--self-test | --thread-sanitizer-simulator]" >&2
        exit 2
    fi
    BUILD_MODE="thread-sanitizer-simulator"
    shift
fi

BUILD_PARENT="$SCRIPT_DIR/.build"
if [[ "$BUILD_MODE" == "thread-sanitizer-simulator" ]]; then
    # This test-only build must never replace the distributable candidate.
    BUILD_ROOT="$BUILD_PARENT/tsan"
else
    BUILD_ROOT="$BUILD_PARENT"
fi
SOURCE="$BUILD_ROOT/source"
SLICES="$BUILD_ROOT/slices"
CANDIDATE="$BUILD_ROOT/BareKit.xcframework"
EVIDENCE="$BUILD_ROOT/evidence"
BARE_MAKE="$SCRIPT_DIR/node_modules/bare-make/bin.js"

barekit_framework_path() {
    local slices_root="$1"
    local slice_name="$2"
    printf '%s/%s/BareKit.framework\n' "$slices_root" "$slice_name"
}

validate_framework_bundle() {
    local framework="$1"
    local bundle_name
    local executable_name

    bundle_name="$(basename "$framework")"
    if [[ "$bundle_name" != *.framework ]]; then
        echo "[bare-kit] error: framework bundle must use a .framework suffix: $framework" >&2
        return 1
    fi
    executable_name="${bundle_name%.framework}"
    if [[ ! -d "$framework" || -L "$framework" ]]; then
        echo "[bare-kit] error: framework bundle must be a real directory: $framework" >&2
        return 1
    fi
    if [[ ! -f "$framework/$executable_name" || -L "$framework/$executable_name" ]]; then
        echo "[bare-kit] error: framework bundle/executable names differ: $framework/$executable_name" >&2
        return 1
    fi
    if [[ ! -f "$framework/Info.plist" || -L "$framework/Info.plist" ]]; then
        echo "[bare-kit] error: framework is missing a regular Info.plist: $framework" >&2
        return 1
    fi
    if [[ ! -f "$framework/Headers/BareKit.h" || -L "$framework/Headers/BareKit.h" ]]; then
        echo "[bare-kit] error: framework is missing its public BareKit header: $framework" >&2
        return 1
    fi
}

stage_barekit_framework() {
    local source_framework="$1"
    local slices_root="$2"
    local slice_name="$3"
    local destination

    if [[ ! "$slice_name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
        echo "[bare-kit] error: unsafe framework slice name: $slice_name" >&2
        return 1
    fi
    if ! validate_framework_bundle "$source_framework"; then
        return 1
    fi
    if [[ "$(basename "$source_framework")" != "BareKit.framework" ]]; then
        echo "[bare-kit] error: source framework must be named BareKit.framework: $source_framework" >&2
        return 1
    fi

    destination="$(barekit_framework_path "$slices_root" "$slice_name")"
    if [[ -e "$destination" || -L "$destination" ]]; then
        echo "[bare-kit] error: refusing to replace staged framework: $destination" >&2
        return 1
    fi
    mkdir -p "$slices_root/$slice_name"
    cp -R "$source_framework" "$destination"
    validate_framework_bundle "$destination"
}

framework_staging_self_test() (
    set -euo pipefail

    local fixture
    local source_framework
    local staged_framework
    local mismatched_framework
    fixture="$(mktemp -d "${TMPDIR:-/tmp}/qvac-bare-kit-framework.XXXXXX")"
    trap 'rm -rf "$fixture"' EXIT

    source_framework="$fixture/generated/BareKit.framework"
    mkdir -p "$source_framework/Headers"
    printf 'test executable\n' > "$source_framework/BareKit"
    printf 'test plist\n' > "$source_framework/Info.plist"
    printf 'test header\n' > "$source_framework/Headers/BareKit.h"

    stage_barekit_framework "$source_framework" "$fixture/slices" "ios-arm64"
    staged_framework="$(barekit_framework_path "$fixture/slices" "ios-arm64")"
    validate_framework_bundle "$staged_framework"
    if [[ -e "$fixture/slices/ios-arm64.framework" ]]; then
        echo "[bare-kit] error: self-test staged a framework under the slice name" >&2
        exit 1
    fi

    mismatched_framework="$fixture/generated/Renamed.framework"
    mkdir -p "$mismatched_framework/Headers"
    cp "$source_framework/BareKit" "$mismatched_framework/BareKit"
    cp "$source_framework/Info.plist" "$mismatched_framework/Info.plist"
    cp "$source_framework/Headers/BareKit.h" "$mismatched_framework/Headers/BareKit.h"
    if validate_framework_bundle "$mismatched_framework" >/dev/null 2>&1; then
        echo "[bare-kit] error: self-test accepted a renamed framework with a mismatched executable" >&2
        exit 1
    fi
    if stage_barekit_framework "$mismatched_framework" "$fixture/slices" "invalid" >/dev/null 2>&1; then
        echo "[bare-kit] error: self-test staged a renamed BareKit framework" >&2
        exit 1
    fi
)

if [[ "${1:-}" == "--self-test" ]]; then
    if [[ "$#" -ne 1 ]]; then
        echo "usage: $0 [--self-test | --thread-sanitizer-simulator]" >&2
        exit 2
    fi
    node "$SCRIPT_DIR/verify.mjs" --self-test
    bash -n "$0"
    framework_staging_self_test
    echo "[bare-kit] candidate builder self-test passed"
    exit 0
elif [[ "$#" -ne 0 ]]; then
    echo "usage: $0 [--self-test | --thread-sanitizer-simulator]" >&2
    exit 2
fi

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "[bare-kit] error: the iOS XCFramework candidate requires macOS" >&2
    exit 1
fi
if [[ -L "$BUILD_PARENT" || -L "$BUILD_ROOT" ]]; then
    echo "[bare-kit] error: refusing symlinked build root: $BUILD_ROOT" >&2
    exit 1
fi

EXPECTED_NODE="$(node -e 'const l=require(process.argv[1]); process.stdout.write(l.buildToolchain.node)' "$LOCK")"
EXPECTED_DEVELOPER_DIR="$(node -e 'const l=require(process.argv[1]); process.stdout.write(l.buildToolchain.developerDirectory)' "$LOCK")"
UPSTREAM_REPOSITORY="$(node -e 'const l=require(process.argv[1]); process.stdout.write(l.upstream.repository)' "$LOCK")"
UPSTREAM_TAG="$(node -e 'const l=require(process.argv[1]); process.stdout.write(l.upstream.tag)' "$LOCK")"
UPSTREAM_COMMIT="$(node -e 'const l=require(process.argv[1]); process.stdout.write(l.upstream.commit)' "$LOCK")"

if [[ "$(node -p 'process.versions.node')" != "$EXPECTED_NODE" ]]; then
    echo "[bare-kit] error: Node $EXPECTED_NODE is required" >&2
    exit 1
fi
if [[ "${DEVELOPER_DIR:-}" != "$EXPECTED_DEVELOPER_DIR" ]]; then
    echo "[bare-kit] error: DEVELOPER_DIR must be $EXPECTED_DEVELOPER_DIR" >&2
    exit 1
fi

node "$SCRIPT_DIR/verify.mjs" --check
npm ci --prefix "$SCRIPT_DIR" --ignore-scripts --no-audit --no-fund
node "$SCRIPT_DIR/verify.mjs" --toolchain

if [[ "$BUILD_MODE" == "thread-sanitizer-simulator" ]]; then
    rm -rf "$BUILD_ROOT"
else
    rm -rf "$BUILD_PARENT"
fi
mkdir -p "$SOURCE" "$SLICES" "$EVIDENCE"

git -C "$SOURCE" init --quiet
git -C "$SOURCE" remote add origin "$UPSTREAM_REPOSITORY"
git -C "$SOURCE" fetch --quiet --depth=1 origin \
    "refs/tags/$UPSTREAM_TAG:refs/tags/$UPSTREAM_TAG"
git -C "$SOURCE" checkout --quiet --detach "$UPSTREAM_COMMIT"
node "$SCRIPT_DIR/verify.mjs" --source "$SOURCE" --state upstream

git -C "$SOURCE" apply --check "$PATCH"
git -C "$SOURCE" apply "$PATCH"
node "$SCRIPT_DIR/verify.mjs" --source "$SOURCE" --state patched

npm ci --prefix "$SOURCE" --ignore-scripts --no-audit --no-fund

build_slice() {
    local name="$1"
    local closure_target="$2"
    shift 2

    rm -rf "$SOURCE/build"
    if [[ "$BUILD_MODE" == "thread-sanitizer-simulator" ]]; then
        # bare-make applies --sanitize to C and link commands. Bind the same
        # instrumentation to the remaining C-family languages so Objective-C
        # lifecycle code and any transitive C++ units cannot remain opaque.
        node "$BARE_MAKE" generate --platform ios "$@" --with-debug-symbols \
            --sanitize thread \
            -D "CMAKE_CXX_FLAGS:STRING=-fno-omit-frame-pointer -fsanitize=thread" \
            -D "CMAKE_OBJC_FLAGS:STRING=-fno-omit-frame-pointer -fsanitize=thread" \
            -D "CMAKE_OBJCXX_FLAGS:STRING=-fno-omit-frame-pointer -fsanitize=thread" \
            -D APPLE_CLANG=ON
    else
        node "$BARE_MAKE" generate --platform ios "$@" --with-debug-symbols \
            -D APPLE_CLANG=ON
    fi

    if [[ "$BUILD_MODE" == "thread-sanitizer-simulator" ]]; then
        node "$BARE_MAKE" build --verbose
    else
        node "$BARE_MAKE" build
    fi
    node "$SCRIPT_DIR/verify.mjs" \
        --native-closure "$SOURCE/build" \
        --target "$closure_target" \
        --evidence "$EVIDENCE/$closure_target.json"

    local framework="$SOURCE/build/apple/BareKit.framework"
    if ! validate_framework_bundle "$framework"; then
        echo "[bare-kit] error: bare-make did not produce the $name framework" >&2
        exit 1
    fi
    stage_barekit_framework "$framework" "$SLICES" "$name"
}

if [[ "$BUILD_MODE" == "thread-sanitizer-simulator" ]]; then
    (
        cd "$SOURCE"
        build_slice ios-arm64-simulator ios-arm64-simulator --arch arm64 --simulator
    )
else
    (
        cd "$SOURCE"
        build_slice ios-arm64 ios-arm64 --arch arm64
        build_slice ios-arm64-simulator ios-arm64-simulator --arch arm64 --simulator
        build_slice ios-x86_64-simulator ios-x64-simulator --arch x64 --simulator
    )
fi

DEVICE_FRAMEWORK="$(barekit_framework_path "$SLICES" "ios-arm64")"
ARM_SIMULATOR_FRAMEWORK="$(barekit_framework_path "$SLICES" "ios-arm64-simulator")"
X86_SIMULATOR_FRAMEWORK="$(barekit_framework_path "$SLICES" "ios-x86_64-simulator")"
UNIVERSAL_SIMULATOR_FRAMEWORK="$(barekit_framework_path "$SLICES" "ios-simulator")"

if [[ "$BUILD_MODE" == "thread-sanitizer-simulator" ]]; then
    xcodebuild -create-xcframework \
        -framework "$ARM_SIMULATOR_FRAMEWORK" \
        -output "$CANDIDATE"
else
    cmp "$ARM_SIMULATOR_FRAMEWORK/Headers/BareKit.h" \
        "$X86_SIMULATOR_FRAMEWORK/Headers/BareKit.h"
    cmp "$ARM_SIMULATOR_FRAMEWORK/Info.plist" \
        "$X86_SIMULATOR_FRAMEWORK/Info.plist"

    stage_barekit_framework "$ARM_SIMULATOR_FRAMEWORK" "$SLICES" "ios-simulator"
    rm -rf "$UNIVERSAL_SIMULATOR_FRAMEWORK/_CodeSignature"
    lipo -create \
        "$ARM_SIMULATOR_FRAMEWORK/BareKit" \
        "$X86_SIMULATOR_FRAMEWORK/BareKit" \
        -output "$UNIVERSAL_SIMULATOR_FRAMEWORK/BareKit"
    validate_framework_bundle "$UNIVERSAL_SIMULATOR_FRAMEWORK"
    rm -rf "$DEVICE_FRAMEWORK/_CodeSignature"

    xcodebuild -create-xcframework \
        -framework "$DEVICE_FRAMEWORK" \
        -framework "$UNIVERSAL_SIMULATOR_FRAMEWORK" \
        -output "$CANDIDATE"
fi

SLICE_COUNT=0
for FRAMEWORK in "$CANDIDATE"/*/BareKit.framework; do
    if [[ ! -d "$FRAMEWORK" ]]; then
        echo "[bare-kit] error: malformed candidate slice: $FRAMEWORK" >&2
        exit 1
    fi
    mkdir -p "$FRAMEWORK/Modules"
    cp "$REPOSITORY_ROOT/tools/runtime/BareKit.modulemap" "$FRAMEWORK/Modules/module.modulemap"
    SLICE_COUNT=$((SLICE_COUNT + 1))
done
EXPECTED_SLICE_COUNT=2
if [[ "$BUILD_MODE" == "thread-sanitizer-simulator" ]]; then
    EXPECTED_SLICE_COUNT=1
fi
if [[ "$SLICE_COUNT" -ne "$EXPECTED_SLICE_COUNT" ]]; then
    echo "[bare-kit] error: expected exactly $EXPECTED_SLICE_COUNT XCFramework slices, found $SLICE_COUNT" >&2
    exit 1
fi

if [[ "$BUILD_MODE" == "thread-sanitizer-simulator" ]]; then
    node "$SCRIPT_DIR/verify.mjs" \
        --thread-sanitizer-artifact "$CANDIDATE" \
        --compile-commands "$SOURCE/build/compile_commands.json" \
        --source-root "$SOURCE" \
        --tsan-evidence "$BUILD_ROOT/bare-kit-tsan-evidence.json"
    echo "[bare-kit] prepared simulator-only Thread Sanitizer test artifact: $CANDIDATE"
    echo "[bare-kit] this instrumented artifact is CI evidence and must not be distributed"
else
    node "$SCRIPT_DIR/verify.mjs" --artifact "$CANDIDATE"
    node "$SCRIPT_DIR/verify.mjs" \
        --aggregate-evidence "$EVIDENCE" \
        --output "$BUILD_ROOT/bare-kit-native-closure.json"
    echo "[bare-kit] prepared non-publishing candidate: $CANDIDATE"
    echo "[bare-kit] activation remains blocked; see $SCRIPT_DIR/README.md"
fi
