import Foundation

/// Default vision-tower image size exported by the published QVAC 0.17 SDK.
public let VLA_DEFAULT_IMAGE_SIZE = 512

/// Memory layout of a three-channel VLA source image.
public enum VLAImageLayout: String, Sendable, Equatable {
    case hwc
    case chw
}

/// Client-side image preprocessing options for VLA inference.
public struct VLAImagePreprocessingOptions: Sendable, Equatable {
    public var size: Int
    public var layout: VLAImageLayout

    /// Input scaling override. Use `1` for `[0, 1]`, `1 / 255` for `[0, 255]`,
    /// or `nil` to reproduce the upstream auto-detection heuristic. Any other
    /// value also selects auto-detection, matching the 0.17 JavaScript helper.
    public var scale: Double?

    public init(
        size: Int = VLA_DEFAULT_IMAGE_SIZE,
        layout: VLAImageLayout = .hwc,
        scale: Double? = nil
    ) {
        self.size = size
        self.layout = layout
        self.scale = scale
    }
}

/// Resize, bottom-right letterbox, convert to CHW, and normalize byte pixels to
/// `[-1, 1]`. This is a byte-exact port of `vlaPreprocessImage` from npm
/// `@qvac/sdk@0.17.0` for finite inputs.
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

/// Zero-pad a VLA state vector to `targetDimension` (32 by default).
public func vlaPadState(
    _ state: [Float],
    targetDimension: Int = 32
) throws -> [Float] {
    try _vlaPadState(state, targetDimension: targetDimension)
}

/// Double-input overload matching JavaScript's plain `number[]` input.
public func vlaPadState(
    _ state: [Double],
    targetDimension: Int = 32
) throws -> [Float] {
    try _vlaPadState(state.map(Float.init), targetDimension: targetDimension)
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
    /// the host architecture.
    func vla(
        _ parameters: VLAParameters,
        rpcOptions: QVACRPCOptions = .init()
    ) async throws -> VLAResult {
        guard parameters.imageWidth > 0, parameters.imageHeight > 0 else {
            throw QVACError.invalidArgument("vla image dimensions must be positive")
        }
        guard !parameters.images.isEmpty,
              parameters.images.allSatisfy({ !$0.isEmpty }) else {
            throw QVACError.invalidArgument("vla requires at least one non-empty image tensor")
        }
        guard !parameters.tokens.isEmpty else {
            throw QVACError.invalidArgument("vla tokens must not be empty")
        }
        guard !parameters.mask.isEmpty else {
            throw QVACError.invalidArgument("vla mask must not be empty")
        }
        if let noise = parameters.noise, noise.isEmpty {
            throw QVACError.invalidArgument("vla noise must not be empty when supplied")
        }

        let request = VLARunWireRequest(
            type: "vlaRun",
            modelId: parameters.modelId,
            images: parameters.images.map { vlaFloat32Data($0).base64EncodedString() },
            imgWidth: parameters.imageWidth,
            imgHeight: parameters.imageHeight,
            state: vlaFloat32Data(parameters.state).base64EncodedString(),
            tokens: vlaInt32Data(parameters.tokens).base64EncodedString(),
            mask: Data(parameters.mask).base64EncodedString(),
            noise: parameters.noise.map { vlaFloat32Data($0).base64EncodedString() }
        )
        let response: JSONValue = try await invokePlugin(
            modelId: parameters.modelId,
            handler: "vlaRun",
            params: request,
            rpcOptions: rpcOptions
        )
        return try Self.parseVLAResult(response)
    }

    /// Fetch hyperparameters from the 0.17 `vlaHparams` plugin handler.
    func vlaHparams(
        modelId: String,
        rpcOptions: QVACRPCOptions = .init()
    ) async throws -> VLAHyperparametersResult {
        let request = VLAHparamsWireRequest(type: "vlaHparams", modelId: modelId)
        let response: JSONValue = try await invokePlugin(
            modelId: modelId,
            handler: "vlaHparams",
            params: request,
            rpcOptions: rpcOptions
        )
        return try Self.parseVLAHyperparametersResult(response)
    }

    private static func parseVLAResult(_ wire: JSONValue) throws -> VLAResult {
        let object = try vlaObject(wire, path: "vla result")
        let encoded = try vlaString(object["actions"], path: "vla result.actions")
        guard !encoded.isEmpty, let data = Data(base64Encoded: encoded) else {
            throw QVACError.protocolViolation("vla result.actions is not non-empty base64")
        }
        let actions = try vlaDecodeFloat32(data, path: "vla result.actions")
        let actionDimension = try vlaInteger(
            object["actionDim"], path: "vla result.actionDim", minimum: 1
        )
        let chunkSize = try vlaInteger(
            object["chunkSize"], path: "vla result.chunkSize", minimum: 1
        )
        let (expectedCount, overflow) = actionDimension.multipliedReportingOverflow(by: chunkSize)
        guard !overflow, actions.count == expectedCount else {
            throw QVACError.protocolViolation(
                "vla result.actions contains \(actions.count) values; expected \(actionDimension) × \(chunkSize)"
            )
        }
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
    let (pixelCount, pixelsOverflow) = width.multipliedReportingOverflow(by: height)
    let (expected, channelsOverflow) = pixelCount.multipliedReportingOverflow(by: 3)
    guard !pixelsOverflow, !channelsOverflow, count == expected else {
        throw QVACError.invalidArgument(
            "vlaPreprocessImage expected \(pixelsOverflow || channelsOverflow ? -1 : expected) pixel values, got \(count)"
        )
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
    let size = options.size
    let ratio = max(Double(width) / Double(size), Double(height) / Double(size))
    let newWidth = max(1, Int(floor(Double(width) / ratio)))
    let newHeight = max(1, Int(floor(Double(height) / ratio)))
    let padLeft = size - newWidth
    let padTop = size - newHeight
    let xScale = Double(width) / Double(newWidth)
    let yScale = Double(height) / Double(newHeight)
    let (planeStride, planeOverflow) = size.multipliedReportingOverflow(by: size)
    let (outputCount, outputOverflow) = planeStride.multipliedReportingOverflow(by: 3)
    guard !planeOverflow, !outputOverflow else {
        throw QVACError.invalidArgument("vlaPreprocessImage size is too large")
    }
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
                output[channel * planeStride + outputIndex] = Float(value * scale * 2 - 1)
            }
        }
    }
    return output
}

private func _vlaPadState(
    _ state: [Float],
    targetDimension: Int
) throws -> [Float] {
    guard targetDimension > 0 else {
        throw QVACError.invalidArgument("vlaPadState targetDimension must be positive")
    }
    guard state.count <= targetDimension else {
        throw QVACError.invalidArgument(
            "vlaPadState input length \(state.count) exceeds targetDimension \(targetDimension)"
        )
    }
    return state + [Float](repeating: 0, count: targetDimension - state.count)
}

private func vlaFloat32Data(_ values: [Float]) -> Data {
    var data = Data(capacity: values.count * MemoryLayout<UInt32>.size)
    for value in values {
        var littleEndian = value.bitPattern.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }
    return data
}

private func vlaInt32Data(_ values: [Int32]) -> Data {
    var data = Data(capacity: values.count * MemoryLayout<Int32>.size)
    for value in values {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }
    return data
}

private func vlaDecodeFloat32(_ data: Data, path: String) throws -> [Float] {
    guard data.count.isMultiple(of: MemoryLayout<UInt32>.size) else {
        throw QVACError.protocolViolation("\(path) byte length is not divisible by four")
    }
    let bytes = [UInt8](data)
    return stride(from: 0, to: bytes.count, by: 4).map { offset in
        let bits = UInt32(bytes[offset])
            | UInt32(bytes[offset + 1]) << 8
            | UInt32(bytes[offset + 2]) << 16
            | UInt32(bytes[offset + 3]) << 24
        return Float(bitPattern: bits)
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
          number >= Double(minimum),
          number <= Double(Int.max) else {
        throw QVACError.protocolViolation("\(path) must be an integer greater than or equal to \(minimum)")
    }
    return Int(number)
}
