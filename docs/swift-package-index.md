# Swift Package Index submission

Swift Package Index submission is a post-release operation. It must not be used to
paper over an unpublished binary closure or an unverified source tag.

## Preconditions

Before submitting `qvac-swift`, verify all of the following:

- the repository is publicly readable at
  `https://github.com/Jainakin/qvac-swift.git`;
- the root `Package.swift` contains immutable HTTPS binary-target URLs and checksums,
  not development `path:` targets;
- the Source Release workflow has created the first stable SemVer tag (`v0.1.0`)
  from the exact commit whose full required CI run passed;
- `swift package dump-package` succeeds with the latest supported Swift toolchain;
- an anonymous external consumer resolves the Git URL at `exact: "0.1.0"`, builds,
  and imports `QVACClient`; and
- the macOS 14, iOS 17 device/simulator, DocC, live-worker, pinned-model, and
  performance gates are green for that source commit.

These checks mirror the current inclusion requirements published by the
[Swift Package Index](https://swiftpackageindex.com/add-a-package): public access,
a valid root manifest, Swift 5 or later, a SemVer release, a protocol-qualified
`.git` URL, valid `dump-package` output, and a compiling package.

## Submit and verify

1. Open [Add a Package](https://swiftpackageindex.com/add-a-package) and submit
   `https://github.com/Jainakin/qvac-swift.git`.
2. Wait for the package-list validation and index build to complete. Do not create
   a replacement tag to work around a failure; fix the source and publish a new
   SemVer patch release through the guarded release workflow.
3. On the indexed package page, verify that `v0.1.0`, iOS 17, macOS 14, the
   `QVACClient` library product, and hosted DocC documentation are detected.
4. Use the page's maintainer-claim flow and add its generated compatibility badges
   to the README only after the package is actually indexed.

Submission and maintainer claiming require external account actions, so they are
intentionally not automated by this repository and remain incomplete until the
artifact and source releases exist.
