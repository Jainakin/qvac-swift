# BareKit IPC hardening candidate

This directory prepares a patched BareKit 2.3.0 XCFramework for a future
`artifacts-sdk-0.17.0-r2` (or later) handoff. It does not publish an artifact,
modify `Package.swift`, or make the candidate active.

## Why this patch exists

The BareKit 2.3.0 binary in the immutable r1 artifact has five IPC defects that
cannot all be corrected safely in Swift:

- `-[BareIPC read]` returns a retained `NSData` despite its non-owning method
  name. A direct Swift call therefore leaks one object and its copied payload
  for every successful native read.
- a native read error other than `EAGAIN`/`EWOULDBLOCK` reaches `NSData` with
  uninitialized pointer and length values in release builds;
- readable and writable blocks are replaced without releasing the previous
  block, and polling invokes an ivar without first taking a stable local copy.
- native read, write, callback replacement, and close do not share a lifecycle
  boundary, so direct native calls can overlap descriptor teardown.
- native write errors can flow into `NSMakeRange` as negative offsets in the
  callback-based API, and interrupted writes are not retried.

[`bare-kit-2.3.0-qvac.patch`](bare-kit-2.3.0-qvac.patch) adds checked read-error
reporting, retries `EINTR`, restores conventional Objective-C return ownership,
serializes IPC use against close, propagates write failures without invalid
ranges, and makes callback replacement and write state safe under manual
reference counting. It also changes BareKit's Bare-runtime fetch from the
`1.29.4` tag to the exact commit behind that tag.

## Locked inputs

[`provenance.lock.json`](provenance.lock.json) binds all of the following:

- BareKit tag, annotated tag object, commit, Git tree, and a SHA-256 digest over
  every tracked source path and byte;
- the original and patched hashes of every edited file plus the complete
  patched-tree SHA-256;
- Bare runtime 1.29.4 commit;
- every Git repository materialized by BareKit's generated CMake graph, bound
  to its origin, full commit, and Git tree;
- every prebuilt `libc++`, `libjs`, and `libv8` archive fetched for the three
  iOS build targets, bound to the upstream mirror key, checkout, and SHA-256;
- the patch SHA-256;
- Node, Xcode-provided Apple Clang, bare-make, and the complete npm build-tool
  lock.

[`verify.mjs`](verify.mjs) rejects unreviewed keys, changed hashes, unexpected
patch paths, a moved tag or source origin, additional tracked edits, a mutable
npm resolution, an unpatched r1 binary, or an XCFramework with the wrong
architecture/header/marker inventory. After every generated slice is built, it
also rejects missing, extra, dirty, substituted, or moved transitive source
checkouts and changed prebuilt archive bytes.

Run the inexpensive repository checks anywhere Node is available:

```sh
node tools/native/bare-kit/verify.mjs --check
node tools/native/bare-kit/verify.mjs --self-test
tools/native/bare-kit/build-candidate.sh --self-test
```

Build the candidate on the pinned CI toolchain:

```sh
export DEVELOPER_DIR=/Applications/Xcode_16.4.app/Contents/Developer
tools/native/bare-kit/build-candidate.sh
```

The builder fetches the exact annotated BareKit v2.3.0 tag, validates the
pristine checkout, applies and revalidates the reviewed patch, checks that the
generated native tree matches the complete locked dependency closure, installs
both npm graphs with `npm ci`, builds arm64 device plus arm64/x86_64 simulator slices,
creates the XCFramework, installs the SwiftPM module map, and verifies the
finished binary. It emits both
`tools/native/bare-kit/.build/BareKit.xcframework` and the deterministic
`tools/native/bare-kit/.build/bare-kit-native-closure.json` evidence document.
Patch revalidation compares every path, blob ID, mode, hunk range, and payload
byte. It ignores only Git's optional hunk-heading description, which is not part
of the applied patch and varies with Git's installation-specific Objective-C
userdiff attributes. The verifier pins the Myers algorithm, indentation
heuristic, and blank-context rendering so ambient Git configuration cannot
change the reviewed payload.

The lock records the exact dependency closure observed after generation rather
than relying on the abbreviated tags present in upstream CMake files. The
builder verifies the resolved checkout and archive bytes after each slice has
finished building. Reproducibility across independent clean roots and the
publication checks below remain separate release requirements.

## Native Thread Sanitizer evidence

The hosted candidate job also builds a separate arm64 iOS Simulator framework:

```sh
export DEVELOPER_DIR=/Applications/Xcode_16.4.app/Contents/Developer
tools/native/bare-kit/build-candidate.sh --thread-sanitizer-simulator
```

This mode uses the same pinned checkout, patch, native dependency closure, Node,
Xcode, and bare-make inputs. It passes `--sanitize thread` through bare-make for
C compilation and linking and explicitly applies the same flags to C++,
Objective-C, and Objective-C++. The verifier requires both patched compilation
units and every emitted C-family compile command to contain
`-fsanitize=thread`; it also requires TSan symbols and an `LC_LOAD_DYLIB`
command for
`@rpath/libclang_rt.tsan_iossim_dynamic.dylib` in the finished framework.

The result is written below `.build/tsan/`, is activated only for the dedicated
37-test simulator lane, and is marked `distributable: false` in its evidence.
The ordinary device/simulator XCFramework under `.build/BareKit.xcframework`
remains unsanitized and the verifier rejects sanitizer symbols or runtime loads
there. The simulator artifact is diagnostic evidence, not a release asset.
The three byte-pinned prebuilt archives (`libc++`, `libjs`, and `libv8`) are not
rebuilt, so this evidence covers every native unit compiled from the pinned
source graph—including the patched IPC C and Objective-C files—but does not
claim instrumentation inside those prebuilt archives.

## Activation gate

The candidate is deliberately marked `blocked`. Correcting the Objective-C
ownership convention changes how Swift must consume the result: the r1-only
`perform(...).takeRetainedValue()` compensation must not run against this
binary. The internal artifact-ABI selector uses the checked +0 Objective-C
method on r2 and retains the narrowly scoped +1 compensation on immutable r1.
That r1 path balances ownership only; it cannot repair r1's native error,
callback, or close-race semantics, so r2 remains the production activation
target. Before a publishing maintainer can host r2, all of these conditions
must be met:

1. Build twice from clean, locked-toolchain CI roots and confirm byte-identical
   output, or review and record every nondeterministic field.
2. Run lifecycle, close/read races, backpressure, sustained-memory, real-worker,
   simulator, and physical-device tests against the patched artifact.
3. Include the patch, provenance lock, and generated native-closure evidence in
   the candidate assets and bind each by SHA-256 in the release manifest.
4. Resolve the repository's separate privacy and native-license publication
   blockers.
5. Generate and commit the URL-backed `Package.swift` from the verified dry-run
   r2-or-later candidate, then require complete CI on that exact source commit.
   Only after a separate review removes the publication kill switch may the
   publishing maintainer rebuild and publish the byte-identical assets under the
   reserved immutable tag.

Until those checks pass, the canonical URL package stays on immutable r1. This
repository prepares evidence; it does not publish to Swift Package Index or
create a GitHub release.
