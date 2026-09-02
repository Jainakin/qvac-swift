# Changelog

Notable changes to QVACClient are recorded here.

## 0.2.0

- Added finite per-request deadlines across unary, server-stream, and duplex
  operations.
- Improved profiling-trailer handling for generated streams and duplex errors.
- Added generation-aware worker reconnection without replaying in-flight work.
- Reworked public stream buffering to preserve producer batches, bound retained
  bytes, coalesce progress snapshots, and report lossless overflow explicitly.
- Strengthened real-model, RAG, profiling, package-consumer, and iOS runtime tests.
- Added publication checks for native-license provenance and Apple privacy
  manifests.
- Reorganized user, contributor, release, and reviewer documentation.

## 0.1.0

- First public Swift Package Manager release targeting QVAC SDK 0.17.0.
- Added the generated 0.17.0 request, response, error, and model-type contracts.
- Added macOS Bare subprocess and iOS BareKit worker transports.
- Added async APIs, streaming operations, the QVACChat example, DocC guides, and
  checksum-pinned iOS binary artifacts.

## 0.0.1-rc1

- Initial release candidate.
