import Foundation

/// Semantic validation for the hand-written diffusion and video result wrappers.
///
/// The generated `wire*` methods deliberately preserve the contract's raw wire
/// surface. The richer wrappers validate the same constraints as the pinned
/// `@qvac/sdk` 0.17 `sdcpp-config.ts` schemas before opening a transport request.
enum QVACMediaRequestValidator {
    private static let maximumSafeJSONInteger = 9_007_199_254_740_991

    private static let samplingMethods: Set<String> = [
        "euler",
        "euler_a",
        "heun",
        "dpm2",
        "dpm++2m",
        "dpm++2mv2",
        "dpm++2s_a",
        "lcm",
        "ipndm",
        "ipndm_v",
        "ddim_trailing",
        "tcd",
        "res_multistep",
        "res_2s",
    ]

    private static let schedulers: Set<String> = [
        "discrete",
        "karras",
        "exponential",
        "ays",
        "gits",
        "sgm_uniform",
        "simple",
        "lcm",
        "smoothstep",
        "kl_optimal",
        "bong_tangent",
    ]

    private static let cacheModes: Set<String> = [
        "disabled",
        "easycache",
        "ucache",
        "dbcache",
        "taylorseer",
        "cache-dit",
    ]

    /// Validate the rich diffusion contract and return the exact decoded byte
    /// count of every inline base64 value without allocating decoded copies.
    /// Callers use the returned counts to enforce the client-wide aggregate
    /// inline-binary quota against the final request after configuration hooks.
    @discardableResult
    static func validate(_ request: DiffusionStreamRequest) throws -> [Int] {
        var inlineBinaryByteCounts: [Int] = []
        try validatePositiveMultiple(
            request.width,
            divisor: 8,
            field: "diffusion width"
        )
        try validatePositiveMultiple(
            request.height,
            divisor: 8,
            field: "diffusion height"
        )
        try validatePositiveInteger(request.steps, field: "diffusion steps")
        try validateFinite(request.cfgScale, field: "diffusion cfgScale")
        try validateFinite(request.imgCfgScale, field: "diffusion imgCfgScale")
        try validateFinite(request.guidance, field: "diffusion guidance")
        try validateEnum(
            request.samplingMethod,
            allowed: samplingMethods,
            field: "diffusion samplingMethod"
        )
        try validateEnum(
            request.scheduler,
            allowed: schedulers,
            field: "diffusion scheduler"
        )
        try validateSafeInteger(request.seed, field: "diffusion seed")
        try validatePositiveInteger(request.batchCount, field: "diffusion batchCount")

        if let initImage = request.initImage {
            inlineBinaryByteCounts.append(
                try validateBase64(initImage, field: "diffusion initImage")
            )
        }
        if let initImages = request.initImages {
            guard !initImages.isEmpty else {
                throw invalid("diffusion initImages must not be empty")
            }
            for (index, encoded) in initImages.enumerated() {
                inlineBinaryByteCounts.append(
                    try validateBase64(
                        encoded,
                        field: "diffusion initImages[\(index)]"
                    )
                )
            }
        }
        guard request.initImage == nil || request.initImages == nil else {
            throw invalid("diffusion initImage and initImages are mutually exclusive")
        }

        if let lora = request.lora {
            guard isAbsolutePath(lora) else {
                throw invalid("diffusion lora must be a non-empty absolute path")
            }
        }
        try validateUnitRange(request.strength, field: "diffusion strength")
        if let upscale = request.upscale {
            try validateUpscale(upscale)
        }
        return inlineBinaryByteCounts
    }

    /// Validate the rich video contract and return the exact decoded byte count
    /// of every inline base64 value without allocating decoded copies.
    @discardableResult
    static func validate(_ request: VideoStreamRequest) throws -> [Int] {
        var inlineBinaryByteCounts: [Int] = []
        guard request.mode == "txt2vid" || request.mode == "img2vid" else {
            throw invalid("video mode must be txt2vid or img2vid")
        }
        if let requestId = request.requestId, requestId.isEmpty {
            throw invalid("video requestId must not be empty")
        }

        try validatePositiveMultiple(
            request.width,
            divisor: 16,
            field: "video width"
        )
        try validatePositiveMultiple(
            request.height,
            divisor: 16,
            field: "video height"
        )
        if let videoFrames = request.videoFrames {
            try validateSafeInteger(videoFrames, field: "video videoFrames")
            guard videoFrames >= 5, (videoFrames - 1).isMultiple(of: 4) else {
                throw invalid(
                    "video videoFrames must be at least 5 and have the form 4*k + 1"
                )
            }
        }
        if let fps = request.fps {
            guard fps.isFinite, fps > 0, fps <= 120 else {
                throw invalid("video fps must be finite and in the range (0, 120]")
            }
        }
        try validateSafeInteger(request.seed, field: "video seed")
        try validatePositiveInteger(request.steps, field: "video steps")
        try validateEnum(
            request.samplingMethod,
            allowed: samplingMethods,
            field: "video samplingMethod"
        )
        try validateEnum(
            request.scheduler,
            allowed: schedulers,
            field: "video scheduler"
        )
        try validateFinite(request.cfgScale, field: "video cfgScale")
        try validateFinite(request.flowShift, field: "video flowShift")
        try validatePositiveInteger(
            request.highNoiseSteps,
            field: "video highNoiseSteps"
        )
        try validateEnum(
            request.highNoiseSampler,
            allowed: samplingMethods,
            field: "video highNoiseSampler"
        )
        try validateEnum(
            request.highNoiseScheduler,
            allowed: schedulers,
            field: "video highNoiseScheduler"
        )
        try validateFinite(
            request.highNoiseCfgScale,
            field: "video highNoiseCfgScale"
        )
        try validateFinite(
            request.highNoiseFlowShift,
            field: "video highNoiseFlowShift"
        )
        try validateUnitRange(request.moeBoundary, field: "video moeBoundary")
        try validateUnitRange(request.vaceStrength, field: "video vaceStrength")

        if let controlFrames = request.controlFrames {
            guard !controlFrames.isEmpty else {
                throw invalid("video controlFrames must not be empty")
            }
            for (index, encoded) in controlFrames.enumerated() {
                inlineBinaryByteCounts.append(
                    try validateBase64(
                        encoded,
                        field: "video controlFrames[\(index)]"
                    )
                )
            }
        }
        if let initImage = request.initImage {
            inlineBinaryByteCounts.append(
                try validateBase64(initImage, field: "video initImage")
            )
        }
        try validateUnitRange(request.strength, field: "video strength")

        if request.mode == "img2vid", request.initImage == nil {
            throw invalid("video initImage is required for img2vid")
        }
        if request.mode == "txt2vid", request.initImage != nil {
            throw invalid("video initImage is only valid for img2vid")
        }
        if request.mode == "txt2vid", request.strength != nil {
            throw invalid("video strength is only valid for img2vid")
        }

        if let tileSize = request.vaeTileSize {
            switch tileSize {
            case .number(let value) where value.isFinite && value > 0:
                break
            case .string(let value) where !value.isEmpty:
                break
            default:
                throw invalid(
                    "video vaeTileSize must be a finite positive number or non-empty string"
                )
            }
        }
        try validateFinite(request.vaeTileOverlap, field: "video vaeTileOverlap")
        try validateEnum(
            request.cacheMode,
            allowed: cacheModes,
            field: "video cacheMode"
        )
        try validateFinite(request.cacheThreshold, field: "video cacheThreshold")
        return inlineBinaryByteCounts
    }

    private static func validateUpscale(_ value: JSONValue) throws {
        switch value {
        case .bool:
            return
        case .object(let object):
            guard object.keys.allSatisfy({ $0 == "repeats" }) else {
                throw invalid("diffusion upscale object may only contain repeats")
            }
            guard let repeats = object["repeats"] else { return }
            guard case .number(let number) = repeats,
                  number.isFinite,
                  number.rounded(.towardZero) == number,
                  number > 0,
                  number <= Double(maximumSafeJSONInteger) else {
                throw invalid(
                    "diffusion upscale.repeats must be a positive JSON-safe integer"
                )
            }
        default:
            throw invalid("diffusion upscale must be a boolean or strict repeats object")
        }
    }

    private static func validatePositiveMultiple(
        _ value: Int?,
        divisor: Int,
        field: String
    ) throws {
        guard let value else { return }
        try validateSafeInteger(value, field: field)
        guard value > 0, value.isMultiple(of: divisor) else {
            throw invalid("\(field) must be positive and a multiple of \(divisor)")
        }
    }

    private static func validatePositiveInteger(_ value: Int?, field: String) throws {
        guard let value else { return }
        try validateSafeInteger(value, field: field)
        guard value > 0 else {
            throw invalid("\(field) must be a positive integer")
        }
    }

    private static func validateSafeInteger(_ value: Int?, field: String) throws {
        guard let value else { return }
        guard value >= -maximumSafeJSONInteger,
              value <= maximumSafeJSONInteger else {
            throw invalid(
                "\(field) must be between -\(maximumSafeJSONInteger) and "
                    + "\(maximumSafeJSONInteger), the JSON-safe integer range"
            )
        }
    }

    private static func validateFinite(_ value: Double?, field: String) throws {
        guard let value else { return }
        guard value.isFinite else {
            throw invalid("\(field) must be finite")
        }
    }

    private static func validateUnitRange(_ value: Double?, field: String) throws {
        guard let value else { return }
        guard value.isFinite, value >= 0, value <= 1 else {
            throw invalid("\(field) must be finite and in the range [0, 1]")
        }
    }

    private static func validateEnum(
        _ value: String?,
        allowed: Set<String>,
        field: String
    ) throws {
        guard let value else { return }
        guard allowed.contains(value) else {
            throw invalid("\(field) has an unsupported value")
        }
    }

    private static func validateBase64(_ value: String, field: String) throws -> Int {
        guard let decodedByteCount = qvacStrictBase64DecodedByteCount(value) else {
            throw invalid("\(field) must be a non-empty base64 string")
        }
        return decodedByteCount
    }

    /// Matches `/^(\/|[A-Za-z]:[\\/]|\\\\)/` from the pinned SDK.
    private static func isAbsolutePath(_ value: String) -> Bool {
        let prefix = Array(value.utf8.prefix(3))
        if prefix.first == 47 { return true }
        if prefix.count >= 2, prefix[0] == 92, prefix[1] == 92 { return true }
        guard prefix.count == 3 else { return false }
        let isDriveLetter = (prefix[0] >= 65 && prefix[0] <= 90)
            || (prefix[0] >= 97 && prefix[0] <= 122)
        return isDriveLetter
            && prefix[1] == 58
            && (prefix[2] == 47 || prefix[2] == 92)
    }

    private static func invalid(_ message: String) -> QVACError {
        .invalidArgument(message)
    }
}
