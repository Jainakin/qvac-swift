# Swift Package Index submission

Swift Package Index submission is a post-release operation. It must not be used to
paper over an unpublished binary closure or an unverified source tag. The first
exact release pair, `artifacts-sdk-0.17.0-r1` and `v0.1.0`, is public and remains
valid URL-installation evidence.

## Index build configuration

The repository-root `.spi.yml` opts `QVACClient` into Swift Package Index-hosted
DocC:

```yaml
version: 1
builder:
  configs:
    - documentation_targets: [QVACClient]
```

Keep this configuration minimal. Platform compatibility comes from
`Package.swift`, where every binary-target dependency of `QVACClient` is explicitly
conditioned on iOS; repository CI separately builds the target's DocC archive on
macOS. Validate any future change with the Index's
[SPI manifest validator](https://swiftpackageindex.com/validate-spi-manifest)
before publishing it.

Swift Package Index analyzes `.spi.yml` from each checked-out version. The
immutable-by-policy `v0.1.0` tag predates this file, so it must never be moved merely
to add hosted documentation. A subsequent `v0.2.0` release created from a commit
that contains `.spi.yml` can become the first stable tag with configured versioned
DocC. The grant-handoff stream API is intentionally the new original API and does
not carry a migration or compatibility layer for the unpublished review delta.
Existing release evidence remains additive and unchanged.

## Preconditions

Before submitting `qvac-swift`, verify all of the following:

- the repository is publicly readable at
  `https://github.com/Jainakin/qvac-swift.git`;
- the root `Package.swift` contains release-asset HTTPS binary-target URLs and
  checksums, not development `path:` targets;
- the Source Release workflow has created the selected stable SemVer tag from the
  exact commit whose full required CI run passed;
- the selected tag contains `.spi.yml` when versioned hosted DocC is part of the
  acceptance evidence;
- `swift package dump-package` succeeds with the latest supported Swift toolchain;
- an anonymous external consumer resolves the Git URL at the selected exact
  SemVer, builds, and imports `QVACClient`; and
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
   SemVer release through the guarded release workflow.
3. On the indexed package page, verify the latest reviewed stable version, iOS 17,
   macOS 14, the `QVACClient` library product, successful compatibility builds,
   and hosted DocC documentation for `QVACClient`.
4. Use the page's maintainer-claim flow and add its generated compatibility badges
   to the README only after the package is actually indexed.
5. Record the indexed package/documentation URLs and successful build evidence in
   `SUBMISSION.md`; do not infer completion merely from submitting the form.

The repository-side Index preparation is complete: this document and `.spi.yml`
provide the required guidance and hosted-DocC configuration. Actual Index
submission, build verification, maintainer claiming, and badges remain
publisher-owned operations; perform them only with explicit publication authority
and do not describe them as complete without the resulting evidence.
