# Changelog

Notable changes to QVACClient are recorded here.

## [Unreleased]

- Added finite per-request deadlines across unary, server-stream, and duplex
  operations.
- Improved profiling-trailer handling for generated streams and duplex errors.
- Added generation-aware worker reconnection without replaying in-flight work.
- Reworked public stream buffering to preserve producer batches, bound retained
  bytes, coalesce progress snapshots, and report lossless overflow explicitly.
- Added independent inbound, outbound, inline-binary byte and item, accumulated
  result, metadata-response, record, and stream-buffer limits, with checked
  arithmetic and fail-fast validation for handshakes, media, and tensor operations.
- Hardened macOS socket and iOS BareIPC teardown against accept, callback, write,
  cancellation, and concurrent-close races.
- Strengthened real-model, RAG, profiling, package-consumer, and iOS runtime tests.
- Added fail-closed macOS and iOS source-coverage gates, exact test inventories,
  macOS Address, Thread, and Undefined Behavior Sanitizer jobs, and a native and
  Swift iOS Simulator Thread Sanitizer job.
- Added publication checks for native-license provenance and Apple privacy
  manifests.
- Reorganized user, contributor, release, and reviewer documentation and removed
  obsolete prototype sources and binaries from the distribution repository.

## 0.1.0

- First public Swift Package Manager release targeting QVAC SDK 0.17.0.
- Added the generated 0.17.0 request, response, error, and model-type contracts.
- Added macOS Bare subprocess and iOS BareKit worker transports.
- Added async APIs, streaming operations, the QVACChat example, DocC guides, and
  checksum-pinned iOS binary artifacts.

## 0.0.1-rc1

- Initial release candidate.
