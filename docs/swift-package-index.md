# Swift Package Index

Submit QVACClient to Swift Package Index only after its source release and binary
artifacts are publicly available. A designated maintainer owns this step; it is
separate from source review.

## Configuration

The root `.spi.yml` enables hosted DocC for `QVACClient`:

```yaml
version: 1
builder:
  configs:
    - documentation_targets: [QVACClient]
```

Platform requirements come from `Package.swift`. CI separately builds the DocC
archive with warnings treated as errors.

Swift Package Index reads `.spi.yml` from each release tag. `v0.1.0` predates this
file, so do not move that tag to add hosted documentation. Publish a new SemVer
release from a reviewed commit instead.

## Before submission

Verify that:

- `https://github.com/Jainakin/qvac-swift.git` is publicly readable;
- the selected release uses public binary-target URLs and valid checksums;
- `swift package dump-package` succeeds for the release tag;
- a clean external consumer resolves the Git URL and imports `QVACClient`;
- macOS, iOS device and simulator, DocC, live-worker, model, and performance jobs
  passed for the release commit; and
- the selected tag contains `.spi.yml`.

The release workflow performs the package and external-consumer checks. Validate
`.spi.yml` separately with the
[SPI manifest validator](https://swiftpackageindex.com/validate-spi-manifest).

## Submit and verify

1. Open [Add a Package](https://swiftpackageindex.com/add-a-package) and submit
   `https://github.com/Jainakin/qvac-swift.git`.
2. Wait for package validation and the hosted build to finish.
3. Confirm the latest reviewed version, supported platforms, `QVACClient` product,
   compatibility builds, and hosted documentation on the package page.
4. Complete the maintainer-claim flow.
5. Add Index badges to the README only after the listing and builds exist.
6. Record the package and documentation URLs in the release record.

If validation fails, fix the source and publish a new version through the release
process. Do not replace or move an existing release tag.
