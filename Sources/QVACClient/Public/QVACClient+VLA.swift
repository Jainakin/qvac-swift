import Foundation

/// Default vision-tower image size exported by the published QVAC 0.17 SDK.
public let VLA_DEFAULT_IMAGE_SIZE = 512

// Defaults used by standalone footprint tests. The client-bound VLA operation
// supplies its configured inline byte, item, and outbound ceilings explicitly.
let vlaMaximumClientRequestTensorBytes = QVACClient.defaultMaximumInlineBinaryBytes
let vlaMaximumClientEncodedRequestBytes =
    (qvacBase64EncodedByteCount(QVACClient.defaultMaximumInlineBinaryBytes) ?? 0)
    + QVACClient.defaultMaximumInlineBinaryItems * 4
let vlaMaximumSafeJSONInteger = 9_007_199_254_740_991

/// Memory layout of a three-channel VLA source image.
public enum VLAImageLayout: String, Sendable, Equatable {
    case hwc
    case chw
}

/// Client-side image preprocessing options for VLA inference.
public struct VLAImagePreprocessingOptions: Sendable, Equatable {
    /// Output width and height.
    public var size: Int
    public var layout: VLAImageLayout

    /// Finite ceiling for the resulting CHW Float32 tensor. The default matches
    /// the client's inline-binary byte budget and can be raised deliberately for
    /// a client configured with a larger budget.
    public var maximumOutputBytes: Int

    /// Input scaling override. Use `1` for `[0, 1]`, `1 / 255` for `[0, 255]`,
    /// or `nil` to reproduce the upstream auto-detection heuristic. Any other
    /// value also selects auto-detection, matching the 0.17 JavaScript helper.
    public var scale: Double?

    public init(
        size: Int = VLA_DEFAULT_IMAGE_SIZE,
        layout: VLAImageLayout = .hwc,
        scale: Double? = nil,
        maximumOutputBytes: Int = QVACClient.defaultMaximumInlineBinaryBytes
    ) {
        self.size = size
        self.layout = layout
        self.scale = scale
        self.maximumOutputBytes = maximumOutputBytes
    }
}

/// Resize, bottom-right letterbox, convert to CHW, and normalize byte pixels to
/// `[-1, 1]`. This is a byte-exact port of `vlaPreprocessImage` from npm
/// `@qvac/sdk@0.17.0` for inputs whose normalized values are finite Float32.
/// Output is bounded by `options.maximumOutputBytes` before allocation.
public func vlaPreprocessImage(
    _ pixels: [UInt8],
    width: Int,
    height: Int,
    options: VLAImagePreprocessingOptions = .init()
) throws -> [Float] {
    try _vlaPreprocessImage(
        count: pixels.count,
        valueAt: { Double(pixels[$0]) },
        byteInput: true,
        width: width,
        height: height,
        options: options
    )
}

/// Float-input overload of ``vlaPreprocessImage(_:width:height:options:)``.
public func vlaPreprocessImage(
    _ pixels: [Float],
    width: Int,
    height: Int,
    options: VLAImagePreprocessingOptions = .init()
) throws -> [Float] {
    try _vlaPreprocessImage(
        count: pixels.count,
        valueAt: { Double(pixels[$0]) },
        byteInput: false,
        width: width,
        height: height,
        options: options
    )
}

/// Double-input overload matching JavaScript's plain `number[]` input.
public func vlaPreprocessImage(
    _ pixels: [Double],
    width: Int,
    height: Int,
    options: VLAImagePreprocessingOptions = .init()
) throws -> [Float] {
    try _vlaPreprocessImage(
        count: pixels.count,
        valueAt: { pixels[$0] },
        byteInput: false,
        width: width,
        height: height,
        options: options
    )
}

/// Zero-pad a finite VLA state vector to `targetDimension` (32 by default).
/// The resulting tensor is bounded by `maximumOutputBytes` before allocation.
public func vlaPadState(
    _ state: [Float],
    targetDimension: Int = 32,
    maximumOutputBytes: Int = QVACClient.defaultMaximumInlineBinaryBytes
) throws -> [Float] {
    try _vlaPadState(
        state,
        targetDimension: targetDimension,
        maximumOutputBytes: maximumOutputBytes
    )
}

/// Double-input overload matching JavaScript's plain `number[]` input.
public func vlaPadState(
    _ state: [Double],
    targetDimension: Int = 32,
    maximumOutputBytes: Int = QVACClient.defaultMaximumInlineBinaryBytes
) throws -> [Float] {
    try _vlaValidatePaddedStateSize(
        inputCount: state.count,
        targetDimension: targetDimension,
        maximumOutputBytes: maximumOutputBytes
    )
    for value in state {
        guard value.isFinite, Float(value).isFinite else {
            throw QVACError.invalidArgument(
                "vlaPadState input must contain finite Float32 values"
            )
        }
    }
    var output: [Float] = []
    output.reserveCapacity(targetDimension)
    for value in state {
        output.append(Float(value))
    }
    output.append(contentsOf: repeatElement(0, count: targetDimension - state.count))
    return output
}

public extension QVACClient {
    struct VLAParameters: Sendable, Equatable {
        public var modelId: String
        public var images: [[Float]]
        public var imageWidth: Int
        public var imageHeight: Int
        public var state: [Float]
        public var tokens: [Int32]
        public var mask: [UInt8]
        public var noise: [Float]?

        public init(
            modelId: String,
            images: [[Float]],
            imageWidth: Int,
            imageHeight: Int,
            state: [Float],
            tokens: [Int32],
            mask: [UInt8],
            noise: [Float]? = nil
        ) {
            self.modelId = modelId
            self.images = images
            self.imageWidth = imageWidth
            self.imageHeight = imageHeight
            self.state = state
            self.tokens = tokens
            self.mask = mask
            self.noise = noise
        }
    }

    struct VLAStats: Sendable, Equatable {
        public let visionMs: Double?
        public let prefillComputeMs: Double?
        public let prefillTotalMs: Double?
        public let smollm2ComputeMs: Double?
        public let smollm2TotalMs: Double?
        public let odeMs: Double?
        public let totalMs: Double?
        /// `0` is CPU and `1` is an accelerated backend in the 0.17 schema.
        public let backendDevice: Double?
    }

    struct VLAResult: Sendable, Equatable {
        /// Finite action values bounded by the client's dedicated VLA action budget.
        public let actions: [Float]
        public let actionDimension: Int
        public let chunkSize: Int
        public let stats: VLAStats?
    }

    enum VLAStateInputMode: String, Sendable, Equatable {
        case continuous
        case discrete
    }

    enum VLAImageInputMode: String, Sendable, Equatable {
        case pixels
        case patches
    }

    struct VLAHyperparameters: Sendable, Equatable {
        public let chunkSize: Int
        public let actionDimension: Int
        public let maximumActionDimension: Int
        public let maximumStateDimension: Int
        public let tokenizerMaximumLength: Int
        public let visionImageSize: Int
        public let numberOfCameras: Int?
        public let stateInputMode: VLAStateInputMode?
        public let imageInputMode: VLAImageInputMode?
        public let imagePatchElements: Int?
    }

    struct VLAHyperparametersResult: Sendable, Equatable {
        public let hyperparameters: VLAHyperparameters
        /// Human-readable backend name, or `nil` when the addon does not expose one.
        public let backendName: String?
    }

    /// Run VLA inference through the 0.17 `vlaRun` plugin handler. Float32 and
    /// Int32 arrays are encoded explicitly in little-endian order, independent of
    /// the host architecture. Tokens and mask entries must have matching counts.
    /// Camera count and raw tensor bytes are bounded by the client's configured
    /// inline-binary item and byte ceilings. Returned action bytes are bounded by
    /// `maximumVLAActionBytes` before the encoded response is copied and again
    /// before decoded Float32 storage is allocated.
    func vla(
        _ parameters: VLAParameters,
        rpcOptions: QVACRPCOptions = .init()
    ) async throws -> VLAResult {
        guard parameters.imageWidth > 0,
              parameters.imageHeight > 0,
              parameters.imageWidth <= vlaMaximumSafeJSONInteger,
              parameters.imageHeight <= vlaMaximumSafeJSONInteger else {
            throw QVACError.invalidArgument(
                "vla image dimensions must be positive JSON-safe integers"
            )
        }
        guard !parameters.images.isEmpty,
              parameters.images.allSatisfy({ !$0.isEmpty }) else {
            throw QVACError.invalidArgument("vla requires at least one non-empty image tensor")
        }
        let fixedTensorCount = parameters.noise == nil ? 3 : 4
        let (tensorCount, tensorCountOverflow) = parameters.images.count
            .addingReportingOverflow(fixedTensorCount)
        guard !tensorCountOverflow, tensorCount <= maximumInlineBinaryItems else {
            throw QVACError.invalidArgument(
                "vla has more than maximumInlineBinaryItems "
                    + "\(maximumInlineBinaryItems) binary tensors"
            )
        }
        guard !parameters.tokens.isEmpty else {
            throw QVACError.invalidArgument("vla tokens must not be empty")
        }
        guard !parameters.mask.isEmpty else {
            throw QVACError.invalidArgument("vla mask must not be empty")
        }
        guard parameters.mask.count == parameters.tokens.count else {
            throw QVACError.invalidArgument("vla tokens and mask must have the same length")
        }
        if let noise = parameters.noise, noise.isEmpty {
            throw QVACError.invalidArgument("vla noise must not be empty when supplied")
        }

        var tensorShapes = parameters.images.map {
            (elementCount: $0.count, elementStride: MemoryLayout<Float>.stride)
        }
        tensorShapes.append(
            (elementCount: parameters.state.count, elementStride: MemoryLayout<Float>.stride)
        )
        tensorShapes.append(
            (elementCount: parameters.tokens.count, elementStride: MemoryLayout<Int32>.stride)
        )
        tensorShapes.append(
            (elementCount: parameters.mask.count, elementStride: MemoryLayout<UInt8>.stride)
        )
        if let noise = parameters.noise {
            tensorShapes.append(
                (elementCount: noise.count, elementStride: MemoryLayout<Float>.stride)
            )
        }
        let footprint = try vlaValidateRequestTensorFootprint(
            tensorShapes,
            rawByteLimit: maximumInlineBinaryBytes,
            encodedByteLimit: maximumOutboundPayloadBytes
        )
        try validateBase64InputSizes(footprint.byteCounts, operation: "vla")

        guard parameters.images.allSatisfy({ image in image.allSatisfy(\.isFinite) }) else {
            throw QVACError.invalidArgument("vla image tensors must contain only finite values")
        }
        guard parameters.state.allSatisfy(\.isFinite) else {
            throw QVACError.invalidArgument("vla state must contain only finite values")
        }
        if let noise = parameters.noise, !noise.allSatisfy(\.isFinite) {
            throw QVACError.invalidArgument("vla noise must contain only finite values")
        }

        var encodedImages: [String] = []
        encodedImages.reserveCapacity(parameters.images.count)
        for (index, image) in parameters.images.enumerated() {
            encodedImages.append(
                vlaFloat32Data(image, byteCount: footprint.byteCounts[index])
                    .base64EncodedString()
            )
        }
        var byteCountIndex = parameters.images.count
        let stateByteCount = footprint.byteCounts[byteCountIndex]
        byteCountIndex += 1
        let tokenByteCount = footprint.byteCounts[byteCountIndex]
        byteCountIndex += 1
        let maskByteCount = footprint.byteCounts[byteCountIndex]
        byteCountIndex += 1
        let encodedNoise: String?
        if let noise = parameters.noise {
            encodedNoise = vlaFloat32Data(
                noise,
                byteCount: footprint.byteCounts[byteCountIndex]
            ).base64EncodedString()
        } else {
            encodedNoise = nil
        }

        let request = VLARunWireRequest(
            type: "vlaRun",
            modelId: parameters.modelId,
            images: encodedImages,
            imgWidth: parameters.imageWidth,
            imgHeight: parameters.imageHeight,
            state: vlaFloat32Data(parameters.state, byteCount: stateByteCount)
                .base64EncodedString(),
            tokens: vlaInt32Data(parameters.tokens, byteCount: tokenByteCount)
                .base64EncodedString(),
            mask: vlaUInt8Data(parameters.mask, byteCount: maskByteCount)
                .base64EncodedString(),
            noise: encodedNoise
        )
        let response: JSONValue = try await invokePluginWithResponseLimit(
            modelId: parameters.modelId,
            handler: "vlaRun",
            params: request,
            rpcOptions: rpcOptions,
            maximumResponseBytes: vlaMaximumEncodedResponseBytes
        )
        return try Self.parseVLAResult(
            response,
            maximumActionBytes: maximumVLAActionBytes
        )
    }

    /// Fetch hyperparameters from the 0.17 `vlaHparams` plugin handler.
    func vlaHparams(
        modelId: String,
        rpcOptions: QVACRPCOptions = .init()
    ) async throws -> VLAHyperparametersResult {
        let request = VLAHparamsWireRequest(type: "vlaHparams", modelId: modelId)
        let response: JSONValue = try await invokePluginWithResponseLimit(
            modelId: modelId,
            handler: "vlaHparams",
            params: request,
            rpcOptions: rpcOptions,
            maximumResponseBytes: maximumMetadataResponseBytes
        )
        return try Self.parseVLAHyperparametersResult(response)
    }

    private var vlaMaximumEncodedResponseBytes: Int {
        guard let encodedActionBytes = qvacBase64EncodedByteCount(
            maximumVLAActionBytes
        ) else {
            return maximumWireMessageBytes
        }
        let (withEnvelopeAllowance, overflow) = encodedActionBytes
            .addingReportingOverflow(64 * 1_024)
        return min(
            maximumWireMessageBytes,
            overflow ? maximumWireMessageBytes : withEnvelopeAllowance
        )
    }

    private static func parseVLAResult(
        _ wire: JSONValue,
        maximumActionBytes: Int
    ) throws -> VLAResult {
        let object = try vlaObject(wire, path: "vla result")
        let actionDimension = try vlaInteger(
            object["actionDim"], path: "vla result.actionDim", minimum: 1
        )
        let chunkSize = try vlaInteger(
            object["chunkSize"], path: "vla result.chunkSize", minimum: 1
        )
        let (expectedCount, overflow) = actionDimension.multipliedReportingOverflow(by: chunkSize)
        guard !overflow else {
            throw QVACError.protocolViolation(
                "vla result action dimensions are too large"
            )
        }
        let (expectedByteCount, byteOverflow) = expectedCount.multipliedReportingOverflow(
            by: MemoryLayout<Float>.stride
        )
        guard !byteOverflow, expectedByteCount <= maximumActionBytes else {
            throw QVACError.resourceLimitExceeded(
                operation: "vla",
                resource: "decoded action bytes",
                maximumBytes: maximumActionBytes,
                attemptedBytes: byteOverflow ? Int.max : expectedByteCount
            )
        }

        let encoded = try vlaString(object["actions"], path: "vla result.actions")
        guard !encoded.isEmpty else {
            throw QVACError.protocolViolation("vla result.actions is not non-empty base64")
        }
        guard let expectedEncodedByteCount = qvacBase64EncodedByteCount(expectedByteCount),
              encoded.utf8.count == expectedEncodedByteCount else {
            throw QVACError.protocolViolation(
                "vla result.actions encoded length is inconsistent with expected "
                    + "\(actionDimension) × \(chunkSize) Float32 values"
            )
        }
        guard let decodedByteCount = qvacStrictBase64DecodedByteCount(encoded) else {
            throw QVACError.protocolViolation("vla result.actions is not non-empty base64")
        }
        guard decodedByteCount.isMultiple(of: MemoryLayout<UInt32>.size) else {
            throw QVACError.protocolViolation(
                "vla result.actions byte length is not divisible by four"
            )
        }
        guard decodedByteCount == expectedByteCount else {
            throw QVACError.protocolViolation(
                "vla result.actions contains "
                    + "\(decodedByteCount / MemoryLayout<Float>.stride) values; "
                    + "expected \(actionDimension) × \(chunkSize)"
            )
        }
        // Syntax, exact decoded size, and the client result limit are all
        // established before allocating worker-controlled decoded storage.
        guard let data = Data(base64Encoded: encoded),
              data.count == decodedByteCount else {
            throw QVACError.protocolViolation("vla result.actions is not non-empty base64")
        }
        let actions = try vlaDecodeFloat32(data, path: "vla result.actions")
        let stats = try object["stats"].map(Self.parseVLAStats)
        return .init(
            actions: actions,
            actionDimension: actionDimension,
            chunkSize: chunkSize,
            stats: stats
        )
    }

    private static func parseVLAHyperparametersResult(
        _ wire: JSONValue
    ) throws -> VLAHyperparametersResult {
        let object = try vlaObject(wire, path: "vla hparams result")
        let hparams = try vlaObject(object["hparams"], path: "vla hparams result.hparams")
        let backendName: String?
        guard let backendNameValue = object["backendName"] else {
            throw QVACError.protocolViolation("vla hparams result.backendName is missing")
        }
        switch backendNameValue {
        case .null:
            backendName = nil
        case .string(let value):
            backendName = value
        default:
            throw QVACError.protocolViolation("vla hparams result.backendName must be string or null")
        }

        let stateInputMode: VLAStateInputMode?
        if let value = hparams["stateInputMode"] {
            let raw = try vlaString(value, path: "vla hparams.stateInputMode")
            guard let parsed = VLAStateInputMode(rawValue: raw) else {
                throw QVACError.protocolViolation("vla hparams.stateInputMode is not a 0.17 value")
            }
            stateInputMode = parsed
        } else {
            stateInputMode = nil
        }

        let imageInputMode: VLAImageInputMode?
        if let value = hparams["imageInputMode"] {
            let raw = try vlaString(value, path: "vla hparams.imageInputMode")
            guard let parsed = VLAImageInputMode(rawValue: raw) else {
                throw QVACError.protocolViolation("vla hparams.imageInputMode is not a 0.17 value")
            }
            imageInputMode = parsed
        } else {
            imageInputMode = nil
        }

        return .init(
            hyperparameters: .init(
                chunkSize: try vlaInteger(hparams["chunkSize"], path: "vla hparams.chunkSize", minimum: 0),
                actionDimension: try vlaInteger(hparams["actionDim"], path: "vla hparams.actionDim", minimum: 0),
                maximumActionDimension: try vlaInteger(hparams["maxActionDim"], path: "vla hparams.maxActionDim", minimum: 0),
                maximumStateDimension: try vlaInteger(hparams["maxStateDim"], path: "vla hparams.maxStateDim", minimum: 0),
                tokenizerMaximumLength: try vlaInteger(hparams["tokenizerMaxLength"], path: "vla hparams.tokenizerMaxLength", minimum: 0),
                visionImageSize: try vlaInteger(hparams["visionImageSize"], path: "vla hparams.visionImageSize", minimum: 0),
                numberOfCameras: try hparams["numCameras"].map {
                    try vlaInteger($0, path: "vla hparams.numCameras", minimum: 1)
                },
                stateInputMode: stateInputMode,
                imageInputMode: imageInputMode,
                imagePatchElements: try hparams["imagePatchElems"].map {
                    try vlaInteger($0, path: "vla hparams.imagePatchElems", minimum: 0)
                }
            ),
            backendName: backendName
        )
    }

    private static func parseVLAStats(_ wire: JSONValue) throws -> VLAStats {
        let object = try vlaObject(wire, path: "vla result.stats")
        func number(_ key: String) throws -> Double? {
            guard let value = object[key] else { return nil }
            guard case .number(let number) = value, number.isFinite else {
                throw QVACError.protocolViolation("vla result.stats.\(key) must be a finite number")
            }
            return number
        }
        return .init(
            visionMs: try number("vision_ms"),
            prefillComputeMs: try number("prefill_compute_ms"),
            prefillTotalMs: try number("prefill_total_ms"),
            smollm2ComputeMs: try number("smollm2_compute_ms"),
            smollm2TotalMs: try number("smollm2_total_ms"),
            odeMs: try number("ode_ms"),
            totalMs: try number("total_ms"),
            backendDevice: try number("backendDevice")
        )
    }
}

private struct VLARunWireRequest: Encodable, Sendable {
    let type: String
    let modelId: String
    let images: [String]
    let imgWidth: Int
    let imgHeight: Int
    let state: String
    let tokens: String
    let mask: String
    let noise: String?
}

private struct VLAHparamsWireRequest: Encodable, Sendable {
    let type: String
    let modelId: String
}

private func _vlaPreprocessImage(
    count: Int,
    valueAt: (Int) -> Double,
    byteInput: Bool,
    width: Int,
    height: Int,
    options: VLAImagePreprocessingOptions
) throws -> [Float] {
    guard width > 0, height > 0 else {
        throw QVACError.invalidArgument("vlaPreprocessImage width and height must be positive")
    }
    guard options.size > 0 else {
        throw QVACError.invalidArgument("vlaPreprocessImage size must be positive")
    }
    guard options.maximumOutputBytes > 0,
          options.maximumOutputBytes <= Int(UInt32.max) else {
        throw QVACError.invalidArgument(
            "vlaPreprocessImage maximumOutputBytes must be between 1 and UInt32.max"
        )
    }
    let (pixelCount, pixelsOverflow) = width.multipliedReportingOverflow(by: height)
    let (expected, channelsOverflow) = pixelCount.multipliedReportingOverflow(by: 3)
    guard !pixelsOverflow, !channelsOverflow, count == expected else {
        throw QVACError.invalidArgument(
            "vlaPreprocessImage expected \(pixelsOverflow || channelsOverflow ? -1 : expected) pixel values, got \(count)"
        )
    }

    let size = options.size
    // Preflight the output shape before inspecting input values, converting
    // resize intermediates to Int, or allocating output storage.
    let (planeStride, planeOverflow) = size.multipliedReportingOverflow(by: size)
    let (outputCount, outputOverflow) = planeStride.multipliedReportingOverflow(by: 3)
    let (outputBytes, byteOverflow) = outputCount.multipliedReportingOverflow(
        by: MemoryLayout<Float>.stride
    )
    guard !planeOverflow, !outputOverflow, !byteOverflow else {
        throw QVACError.invalidArgument("vlaPreprocessImage size is too large")
    }
    guard outputBytes <= options.maximumOutputBytes else {
        throw QVACError.resourceLimitExceeded(
            operation: "vlaPreprocessImage",
            resource: "output tensor bytes",
            maximumBytes: options.maximumOutputBytes,
            attemptedBytes: outputBytes
        )
    }

    if !byteInput {
        for index in 0..<count where !valueAt(index).isFinite {
            throw QVACError.invalidArgument(
                "vlaPreprocessImage input must contain only finite values"
            )
        }
    }

    let detectedScale: Double
    if byteInput {
        detectedScale = 1 / 255
    } else {
        var maximum = 0.0
        for index in 0..<min(count, 256) {
            maximum = max(maximum, valueAt(index))
        }
        detectedScale = maximum > 1.001 ? 1 / 255 : 1
    }
    let scale: Double
    if let requestedScale = options.scale,
       requestedScale == 1 || requestedScale == 1 / 255 {
        scale = requestedScale
    } else {
        scale = detectedScale
    }
    let ratio = max(Double(width) / Double(size), Double(height) / Double(size))
    let newWidth = max(1, Int(floor(Double(width) / ratio)))
    let newHeight = max(1, Int(floor(Double(height) / ratio)))
    let padLeft = size - newWidth
    let padTop = size - newHeight
    let xScale = Double(width) / Double(newWidth)
    let yScale = Double(height) / Double(newHeight)
    var output = [Float](repeating: -1, count: outputCount)

    for yy in 0..<newHeight {
        let yInput = (Double(yy) + 0.5) * yScale - 0.5
        let y0 = max(0, Int(floor(yInput)))
        let y1 = min(height - 1, y0 + 1)
        let dy = min(1, max(0, yInput - Double(y0)))
        let dyInverse = 1 - dy
        let outputY = yy + padTop
        for xx in 0..<newWidth {
            let xInput = (Double(xx) + 0.5) * xScale - 0.5
            let x0 = max(0, Int(floor(xInput)))
            let x1 = min(width - 1, x0 + 1)
            let dx = min(1, max(0, xInput - Double(x0)))
            let dxInverse = 1 - dx
            let outputX = xx + padLeft
            let w00 = dxInverse * dyInverse
            let w10 = dx * dyInverse
            let w01 = dxInverse * dy
            let w11 = dx * dy
            let outputIndex = outputY * size + outputX
            for channel in 0..<3 {
                let i00: Int
                let i10: Int
                let i01: Int
                let i11: Int
                if options.layout == .hwc {
                    i00 = (y0 * width + x0) * 3 + channel
                    i10 = (y0 * width + x1) * 3 + channel
                    i01 = (y1 * width + x0) * 3 + channel
                    i11 = (y1 * width + x1) * 3 + channel
                } else {
                    let plane = channel * pixelCount
                    i00 = plane + y0 * width + x0
                    i10 = plane + y0 * width + x1
                    i01 = plane + y1 * width + x0
                    i11 = plane + y1 * width + x1
                }
                let value = valueAt(i00) * w00
                    + valueAt(i10) * w10
                    + valueAt(i01) * w01
                    + valueAt(i11) * w11
                let normalized = Float(value * scale * 2 - 1)
                guard normalized.isFinite else {
                    throw QVACError.invalidArgument(
                        "vlaPreprocessImage normalization produced a non-finite Float32 value"
                    )
                }
                output[channel * planeStride + outputIndex] = normalized
            }
        }
    }
    return output
}

private func _vlaPadState(
    _ state: [Float],
    targetDimension: Int,
    maximumOutputBytes: Int
) throws -> [Float] {
    try _vlaValidatePaddedStateSize(
        inputCount: state.count,
        targetDimension: targetDimension,
        maximumOutputBytes: maximumOutputBytes
    )
    guard state.allSatisfy(\.isFinite) else {
        throw QVACError.invalidArgument("vlaPadState input must contain only finite values")
    }
    guard state.count != targetDimension else { return state }
    var output = state
    output.reserveCapacity(targetDimension)
    output.append(contentsOf: repeatElement(0, count: targetDimension - state.count))
    return output
}

private func _vlaValidatePaddedStateSize(
    inputCount: Int,
    targetDimension: Int,
    maximumOutputBytes: Int
) throws {
    guard targetDimension > 0 else {
        throw QVACError.invalidArgument("vlaPadState targetDimension must be positive")
    }
    guard inputCount <= targetDimension else {
        throw QVACError.invalidArgument(
            "vlaPadState input length \(inputCount) exceeds targetDimension \(targetDimension)"
        )
    }
    guard maximumOutputBytes > 0,
          maximumOutputBytes <= Int(UInt32.max) else {
        throw QVACError.invalidArgument(
            "vlaPadState maximumOutputBytes must be between 1 and UInt32.max"
        )
    }
    let (outputBytes, overflow) = targetDimension.multipliedReportingOverflow(
        by: MemoryLayout<Float>.stride
    )
    guard !overflow, outputBytes <= maximumOutputBytes else {
        throw QVACError.resourceLimitExceeded(
            operation: "vlaPadState",
            resource: "output tensor bytes",
            maximumBytes: maximumOutputBytes,
            attemptedBytes: overflow ? Int.max : outputBytes
        )
    }
}

struct VLATensorFootprint: Equatable {
    let byteCounts: [Int]
    let rawByteCount: Int
    let base64ByteCount: Int
}

func vlaTensorFootprint(
    _ shapes: [(elementCount: Int, elementStride: Int)]
) -> VLATensorFootprint? {
    var byteCounts: [Int] = []
    byteCounts.reserveCapacity(shapes.count)
    var rawByteCount = 0
    var base64ByteCount = 0

    for shape in shapes {
        guard shape.elementCount >= 0, shape.elementStride > 0 else { return nil }
        let (byteCount, byteOverflow) = shape.elementCount.multipliedReportingOverflow(
            by: shape.elementStride
        )
        guard !byteOverflow,
              let encodedByteCount = qvacBase64EncodedByteCount(byteCount) else {
            return nil
        }
        let (nextRawByteCount, rawOverflow) = rawByteCount.addingReportingOverflow(byteCount)
        let (nextBase64ByteCount, base64Overflow) = base64ByteCount.addingReportingOverflow(
            encodedByteCount
        )
        guard !rawOverflow, !base64Overflow else { return nil }
        byteCounts.append(byteCount)
        rawByteCount = nextRawByteCount
        base64ByteCount = nextBase64ByteCount
    }

    return .init(
        byteCounts: byteCounts,
        rawByteCount: rawByteCount,
        base64ByteCount: base64ByteCount
    )
}

func vlaValidateRequestTensorFootprint(
    _ shapes: [(elementCount: Int, elementStride: Int)],
    rawByteLimit: Int = vlaMaximumClientRequestTensorBytes,
    encodedByteLimit: Int = vlaMaximumClientEncodedRequestBytes
) throws -> VLATensorFootprint {
    guard let footprint = vlaTensorFootprint(shapes) else {
        throw QVACError.invalidArgument("vla request tensor size arithmetic overflowed")
    }
    guard footprint.byteCounts.allSatisfy({ $0 <= rawByteLimit }) else {
        throw QVACError.invalidArgument(
            "an individual vla request tensor exceeds the raw-data limit "
                + "maximumInlineBinaryBytes \(rawByteLimit)"
        )
    }
    guard footprint.rawByteCount <= rawByteLimit else {
        throw QVACError.invalidArgument(
            "vla request tensors total \(footprint.rawByteCount) raw bytes, exceeding "
                + "the raw-data limit maximumInlineBinaryBytes \(rawByteLimit)"
        )
    }
    guard footprint.base64ByteCount <= encodedByteLimit else {
        throw QVACError.invalidArgument(
            "vla request tensors require \(footprint.base64ByteCount) base64 bytes, "
                + "exceeding maximumOutboundPayloadBytes \(encodedByteLimit)"
        )
    }
    return footprint
}

private func vlaFloat32Data(_ values: [Float], byteCount: Int) -> Data {
    var data = Data(capacity: byteCount)
    for value in values {
        var littleEndian = value.bitPattern.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }
    assert(data.count == byteCount)
    return data
}

private func vlaInt32Data(_ values: [Int32], byteCount: Int) -> Data {
    var data = Data(capacity: byteCount)
    for value in values {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }
    assert(data.count == byteCount)
    return data
}

private func vlaUInt8Data(_ values: [UInt8], byteCount: Int) -> Data {
    let data = Data(values)
    assert(data.count == byteCount)
    return data
}

private func vlaDecodeFloat32(_ data: Data, path: String) throws -> [Float] {
    guard data.count.isMultiple(of: MemoryLayout<UInt32>.size) else {
        throw QVACError.protocolViolation("\(path) byte length is not divisible by four")
    }
    return try data.withUnsafeBytes { rawBuffer throws -> [Float] in
        let bytes = rawBuffer.bindMemory(to: UInt8.self)
        func value(at offset: Int) -> Float {
            let bits = UInt32(bytes[offset])
                | UInt32(bytes[offset + 1]) << 8
                | UInt32(bytes[offset + 2]) << 16
                | UInt32(bytes[offset + 3]) << 24
            return Float(bitPattern: bits)
        }
        for offset in stride(from: 0, to: bytes.count, by: 4)
        where !value(at: offset).isFinite {
            throw QVACError.protocolViolation("\(path) contains a non-finite value")
        }
        var values: [Float] = []
        values.reserveCapacity(bytes.count / MemoryLayout<UInt32>.size)
        for offset in stride(from: 0, to: bytes.count, by: 4) {
            values.append(value(at: offset))
        }
        return values
    }
}

private func vlaObject(
    _ value: JSONValue?,
    path: String
) throws -> [String: JSONValue] {
    guard case .object(let object) = value else {
        throw QVACError.protocolViolation("\(path) must be an object")
    }
    return object
}

private func vlaString(_ value: JSONValue?, path: String) throws -> String {
    guard case .string(let string) = value else {
        throw QVACError.protocolViolation("\(path) must be a string")
    }
    return string
}

private func vlaInteger(
    _ value: JSONValue?,
    path: String,
    minimum: Int
) throws -> Int {
    guard case .number(let number) = value,
          number.isFinite,
          number.rounded() == number,
          number <= Double(vlaMaximumSafeJSONInteger),
          let integer = Int(exactly: number),
          integer >= minimum else {
        throw QVACError.protocolViolation(
            "\(path) must be an integer from \(minimum) through "
                + "\(vlaMaximumSafeJSONInteger)"
        )
    }
    return integer
}
