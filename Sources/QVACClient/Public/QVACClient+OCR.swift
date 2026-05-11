// QVAC-212 — ocr
//
// Optical character recognition on an image. The worker streams discovered text blocks
// progressively (e.g. as it finishes recognizing each region). Block shape varies by
// model — we keep it as JSONValue and let callers extract whatever they need.

import Foundation

public extension QVACClient {

    /// Outcome of an OCR call. Iterate `blockStream` for incremental blocks; the `blocks`
    /// task resolves once the stream terminates with the full collected list.
    final class OCRRun: @unchecked Sendable {
        public let blockStream: AsyncThrowingStream<JSONValue, Error>
        public let blocks: Task<[JSONValue], Error>
        public let stats: Task<JSONValue?, Error>
        init(
            blockStream: AsyncThrowingStream<JSONValue, Error>,
            blocks: Task<[JSONValue], Error>,
            stats: Task<JSONValue?, Error>
        ) {
            self.blockStream = blockStream; self.blocks = blocks; self.stats = stats
        }
    }

    /// OCR an image from a file path.
    func ocr(modelId: String, imagePath: String, options: JSONValue? = nil) async throws -> OCRRun {
        return try await ocrInternal(
            modelId: modelId,
            imageValue: .object(["type": .string("filePath"), "value": .string(imagePath)]),
            options: options
        )
    }

    /// OCR an image from in-memory bytes (base64-encoded on the wire).
    func ocr(modelId: String, imageBytes: Data, options: JSONValue? = nil) async throws -> OCRRun {
        return try await ocrInternal(
            modelId: modelId,
            imageValue: .object(["type": .string("base64"), "value": .string(imageBytes.base64EncodedString())]),
            options: options
        )
    }

    private func ocrInternal(modelId: String, imageValue: JSONValue, options: JSONValue?) async throws -> OCRRun {
        let req = OcrStreamRequest(image: imageValue, modelId: modelId, options: options)
        let stream: AsyncThrowingStream<QVACResponse, Error> = try await streamTyped(.ocrStream(req))

        let (blockStream, blockCont) = Self.makeStream(of: JSONValue.self)
        let statsBox = ResultBox<JSONValue?>()
        let blocksTask = Task<[JSONValue], Error> {
            var collected: [JSONValue] = []
            do {
                for try await response in stream {
                    guard case .ocrStream(let r) = response else { continue }
                    if let e = r.error { throw QVACError.server(.ocrFailed, message: e) }
                    if let bs = r.blocks {
                        for b in bs {
                            collected.append(b)
                            blockCont.yield(b)
                        }
                    }
                    if let s = r.stats { statsBox.set(s) }
                    if r.done == true { break }
                }
                blockCont.finish()
                return collected
            } catch {
                blockCont.finish(throwing: error)
                throw error
            }
        }
        let statsTask = Task<JSONValue?, Error> {
            _ = try await blocksTask.value
            return statsBox.get() ?? nil
        }
        return OCRRun(blockStream: blockStream, blocks: blocksTask, stats: statsTask)
    }
}

// Tiny thread-safe box for cross-task value passing.
final class ResultBox<T: Sendable>: @unchecked Sendable {
    private var value: T?
    private let lock = NSLock()
    func set(_ v: T) { lock.lock(); value = v; lock.unlock() }
    func get() -> T? { lock.lock(); defer { lock.unlock() }; return value }
}
