// QVAC-212 — ocr
//
// Optical character recognition on an image. The worker streams discovered text blocks
// progressively (e.g. as it finishes recognizing each region).

import Foundation

public extension QVACClient {

    struct OCRTextBlock: Sendable, Equatable {
        public let text: String
        public let boundingBox: [Double]?
        public let confidence: Double?

        init(wire: JSONValue) throws {
            guard case .object(let object) = wire,
                  case .string(let text) = object["text"] ?? .null else {
                throw QVACError.protocolViolation("OCR block requires text")
            }
            if let value = object["bbox"] {
                guard case .array(let values) = value, values.count == 4 else {
                    throw QVACError.protocolViolation("OCR block bbox must contain four numbers")
                }
                boundingBox = try values.map { value in
                    guard case .number(let number) = value, number.isFinite else {
                        throw QVACError.protocolViolation("OCR block bbox must contain finite numbers")
                    }
                    return number
                }
            } else {
                boundingBox = nil
            }
            if let value = object["confidence"] {
                guard case .number(let number) = value, number.isFinite else {
                    throw QVACError.protocolViolation("OCR block confidence must be a finite number")
                }
                confidence = number
            } else {
                confidence = nil
            }
            self.text = text
        }
    }

    struct OCRStats: Codable, Sendable, Equatable {
        public let detectionTime: Double?
        public let recognitionTime: Double?
        public let totalTime: Double?
    }

    /// Outcome of an OCR call, matching the QVAC 0.17 result modes. When `stream` is
    /// `true`, consume `blockStream` and `blocks` resolves to an empty array. When
    /// `stream` is `false`, `blockStream` is empty and `blocks` resolves to the complete
    /// collected list.
    final class OCRRun: @unchecked Sendable {
        public let blockStream: AsyncThrowingStream<[OCRTextBlock], Error>
        public let blocks: Task<[OCRTextBlock], Error>
        public let stats: Task<OCRStats?, Error>
        private let processing: Task<[OCRTextBlock], Error>

        init(
            blockStream: AsyncThrowingStream<[OCRTextBlock], Error>,
            blocks: Task<[OCRTextBlock], Error>,
            stats: Task<OCRStats?, Error>,
            processing: Task<[OCRTextBlock], Error>
        ) {
            self.blockStream = blockStream
            self.blocks = blocks
            self.stats = stats
            self.processing = processing
        }

        deinit { processing.cancel() }
    }

    /// OCR an image from a file path.
    func ocr(
        modelId: String,
        imagePath: String,
        options: JSONValue? = nil,
        stream: Bool = false,
        rpcOptions: QVACRPCOptions = .init()
    ) async throws -> OCRRun {
        return try await ocrInternal(
            modelId: modelId,
            imageValue: .object(["type": .string("filePath"), "value": .string(imagePath)]),
            options: options,
            stream: stream,
            rpcOptions: rpcOptions
        )
    }

    /// OCR an image from in-memory bytes (base64-encoded on the wire).
    func ocr(
        modelId: String,
        imageBytes: Data,
        options: JSONValue? = nil,
        stream: Bool = false,
        rpcOptions: QVACRPCOptions = .init()
    ) async throws -> OCRRun {
        return try await ocrInternal(
            modelId: modelId,
            imageValue: .object(["type": .string("base64"), "value": .string(imageBytes.base64EncodedString())]),
            options: options,
            stream: stream,
            rpcOptions: rpcOptions
        )
    }

    private func ocrInternal(
        modelId: String,
        imageValue: JSONValue,
        options: JSONValue?,
        stream: Bool,
        rpcOptions: QVACRPCOptions
    ) async throws -> OCRRun {
        let req = OcrStreamRequest(image: imageValue, modelId: modelId, options: options)
        let responseStream: QVACResponseStream<QVACResponse> = try await streamTyped(
            .ocrStream(req),
            rpcOptions: rpcOptions
        )

        let (blockStream, blockCont) = Self.makeStream(
            of: [OCRTextBlock].self,
            name: "ocr.blockStream"
        )
        if !stream { blockCont.finish() }
        let statsBox = ResultBox<OCRStats?>()
        let processing = Task<[OCRTextBlock], Error> {
            var collected: [OCRTextBlock] = []
            var receivedTerminalFrame = false
            do {
                for try await response in responseStream {
                    guard case .ocrStream(let r) = response else {
                        try Self.rejectUnexpectedResponse(response, expected: "ocrStream")
                    }
                    if let e = r.error { throw QVACError.server(.ocrFailed, message: e) }
                    if let wireBlocks = r.blocks {
                        let blocks = try wireBlocks.map(OCRTextBlock.init(wire:))
                        if stream {
                            if !blocks.isEmpty { blockCont.yield(blocks) }
                        } else {
                            collected.append(contentsOf: blocks)
                        }
                    }
                    if let wireStats = r.stats {
                        do {
                            statsBox.set(try Self.decodeFromJSONValue(
                                wireStats,
                                as: OCRStats.self
                            ))
                        } catch {
                            throw QVACError.protocolViolation(
                                "OCR returned malformed stats: \(error)"
                            )
                        }
                    }
                    if r.done == true {
                        receivedTerminalFrame = true
                        break
                    }
                }
                guard receivedTerminalFrame else {
                    throw QVACError.client(
                        .streamEndedWithoutResponse,
                        message: "ocrStream ended without a terminal done frame"
                    )
                }
                blockCont.finish()
                return stream ? [] : collected
            } catch {
                blockCont.finish(throwing: error)
                throw error
            }
        }
        let blocksTask = stream ? Task<[OCRTextBlock], Error> { [] } : processing
        let statsTask = Task<OCRStats?, Error> {
            _ = try await processing.value
            return statsBox.get() ?? nil
        }
        return OCRRun(
            blockStream: blockStream,
            blocks: blocksTask,
            stats: statsTask,
            processing: processing
        )
    }
}

// Tiny thread-safe box for cross-task value passing.
final class ResultBox<T: Sendable>: @unchecked Sendable {
    private var value: T?
    private let lock = NSLock()
    func set(_ v: T) { lock.lock(); value = v; lock.unlock() }
    func get() -> T? { lock.lock(); defer { lock.unlock() }; return value }
}
