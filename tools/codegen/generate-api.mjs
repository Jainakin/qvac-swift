#!/usr/bin/env node
// Generate the complete method inventory and a generic public invocation surface
// from the pinned SDK contract manifest. Adding a method upstream therefore yields
// a callable Swift wire operation according to its declared call shape without a
// hand-maintained routing table.

import { mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

const scriptDir = dirname(fileURLToPath(import.meta.url))
const repoRoot = resolve(scriptDir, '..', '..')
const provenance = JSON.parse(readFileSync(resolve(repoRoot, 'tools/provenance/qvac-sdk.lock.json'), 'utf8'))
const upstreamDir = resolve(process.env.QVAC_UPSTREAM_DIR ?? resolve(scriptDir, '.build/qvac-sdk'))
const manifestPath = resolve(upstreamDir, 'packages/sdk/contract/manifest.json')
const schemaPath = resolve(upstreamDir, 'packages/sdk/contract/schema.json')
const generatedDir = resolve(process.env.QVAC_GENERATED_DIR
  ?? resolve(repoRoot, 'Sources/QVACClient/Generated'))
const output = resolve(generatedDir, 'QVACSDKContract.generated.swift')
const manifest = JSON.parse(readFileSync(manifestPath, 'utf8'))
const schema = JSON.parse(readFileSync(schemaPath, 'utf8'))

const shapes = new Map([
  ['request-reply', 'requestReply'],
  ['server-stream', 'serverStream'],
  ['duplex', 'duplex'],
])

function progressMetadata(method) {
  if (!method.progress) return null
  const condition = method.progress.condition
  if (condition === 'request.withProgress === true') {
    return { condition, operations: null, allowsMissingOperation: true }
  }
  const match = condition.match(/^request\.withProgress === true && \[(.*)\]\.includes\(request\.operation\)$/)
  if (!match) throw new Error(`Unsupported progress condition for ${method.name}: ${condition}`)
  const tokens = match[1].split(',').map(token => token.trim())
  const operations = []
  let allowsMissingOperation = false
  for (const token of tokens) {
    if (token === 'undefined') {
      allowsMissingOperation = true
      continue
    }
    const quoted = token.match(/^['"]([^'"]+)['"]$/)
    if (!quoted) throw new Error(`Unsupported progress token for ${method.name}: ${token}`)
    operations.push(quoted[1])
  }
  return { condition, operations, allowsMissingOperation }
}

const seen = new Set()
for (const method of manifest.methods ?? []) {
  if (!/^[A-Za-z][A-Za-z0-9]*$/.test(method.name)) throw new Error(`Unsafe method name: ${method.name}`)
  if (seen.has(method.name)) throw new Error(`Duplicate method: ${method.name}`)
  if (!shapes.has(method.callShape)) throw new Error(`Unsupported call shape for ${method.name}: ${method.callShape}`)
  if (method.requestSchema !== `schema.json#/$defs/${method.name}.request`) {
    throw new Error(`Unexpected request schema routing for ${method.name}: ${method.requestSchema}`)
  }
  if (method.responseSchema !== `schema.json#/$defs/${method.name}.response`) {
    throw new Error(`Unexpected response schema routing for ${method.name}: ${method.responseSchema}`)
  }
  const requestTitle = schema.$defs?.[`${method.name}.request`]?.title
  const responseTitle = schema.$defs?.[`${method.name}.response`]?.title
  if (!/^[A-Z][A-Za-z0-9]*Request$/.test(requestTitle ?? '')) {
    throw new Error(`Missing/collision-unsafe request title for ${method.name}: ${requestTitle}`)
  }
  if (!/^[A-Z][A-Za-z0-9]*Response$/.test(responseTitle ?? '')) {
    throw new Error(`Missing/collision-unsafe response title for ${method.name}: ${responseTitle}`)
  }
  progressMetadata(method)
  seen.add(method.name)
}

const literals = manifest.methods.map(method => {
  const metadata = progressMetadata(method)
  const progress = metadata
    ? `, progress: .init(condition: ${JSON.stringify(metadata.condition)}, responseSchema: ${JSON.stringify(method.progress.responseSchema)}, operations: ${metadata.operations === null ? 'nil' : `[${metadata.operations.map(JSON.stringify).join(', ')}]`}, allowsMissingOperation: ${metadata.allowsMissingOperation})`
    : ''
  return `        .init(name: ${JSON.stringify(method.name)}, callShape: .${shapes.get(method.callShape)}, requestSchema: ${JSON.stringify(method.requestSchema)}, responseSchema: ${JSON.stringify(method.responseSchema)}${progress})`
}).join(',\n')

function typedMethod(method) {
  const requestType = schema.$defs[`${method.name}.request`].title
  const responseType = schema.$defs[`${method.name}.response`].title
  const swiftMethod = `wire${requestType.slice(0, -'Request'.length)}`
  const requestCase = method.name
  switch (method.callShape) {
    case 'request-reply': {
      const progressMethod = method.progress ? `

    /// Invoke the conditional progress transport declared for \`${method.name}\`.
    func ${swiftMethod}Progress(
        _ request: ${requestType},
        rpcOptions: QVACRPCOptions = .init()
    ) async throws -> QVACResponseStream<QVACResponse> {
        try await wireProgressStream(.${requestCase}(request), rpcOptions: rpcOptions)
    }` : ''
      return `    /// Exact generated request/reply entry point for \`${method.name}\`.
    func ${swiftMethod}(
        _ request: ${requestType},
        rpcOptions: QVACRPCOptions = .init()
    ) async throws -> ${responseType} {
        let response = try await wireRequestReply(.${requestCase}(request), rpcOptions: rpcOptions)
        guard case .${requestCase}(let value) = response else {
            throw QVACError.protocolViolation(
                "expected ${method.name} response, got \\(response.discriminator)"
            )
        }
        return value
    }${progressMethod}`
    }
    case 'server-stream':
      return `    /// Exact generated server-stream entry point for \`${method.name}\`.
    func ${swiftMethod}(
        _ request: ${requestType},
        rpcOptions: QVACRPCOptions = .init()
    ) async throws -> QVACResponseStream<${responseType}> {
        let source = try await wireServerStream(.${requestCase}(request), rpcOptions: rpcOptions)
        return Self.pullMap(source) { response in
            guard case .${requestCase}(let value) = response else {
                throw QVACError.protocolViolation(
                    "expected ${method.name} response, got \\(response.discriminator)"
                )
            }
            return .emit(value)
        }
    }`
    case 'duplex':
      return `    /// Exact generated duplex entry point for \`${method.name}\`.
    func ${swiftMethod}(
        _ request: ${requestType},
        rpcOptions: QVACRPCOptions = .init()
    ) async throws -> QVACDuplexSession<${responseType}> {
        let envelope = QVACRequest.${requestCase}(request)
        _ = try Self.requireCallShape(.duplex, for: envelope)
        return try await duplexTyped(envelope, decoding: ${responseType}.self, rpcOptions: rpcOptions)
    }`
    default:
      throw new Error(`Unsupported call shape: ${method.callShape}`)
  }
}

const typedMethods = manifest.methods.map(typedMethod).join('\n\n')

const swift = `// QVACSDKContract.generated.swift
//
// AUTO-GENERATED from @qvac/sdk@${provenance.sdkVersion} contract/manifest.json
// gitHead: ${provenance.source.commit}
// DO NOT EDIT BY HAND. Re-run \`tools/codegen/run.sh\` to update.

import Foundation

/// Immutable provenance and routing inventory for the exact QVAC wire contract.
public enum QVACSDKContract {
    public static let sdkVersion = "${provenance.sdkVersion}"
    public static let upstreamCommit = "${provenance.source.commit}"
    public static let methodCount = ${manifest.methods.length}

    public enum CallShape: String, Sendable, Equatable, Codable {
        case requestReply = "request-reply"
        case serverStream = "server-stream"
        case duplex
    }

    public struct Method: Sendable, Equatable, Codable {
        public struct Progress: Sendable, Equatable, Codable {
            public let condition: String
            public let responseSchema: String
            public let operations: [String]?
            public let allowsMissingOperation: Bool

            public init(
                condition: String,
                responseSchema: String,
                operations: [String]?,
                allowsMissingOperation: Bool
            ) {
                self.condition = condition
                self.responseSchema = responseSchema
                self.operations = operations
                self.allowsMissingOperation = allowsMissingOperation
            }
        }

        public let name: String
        public let callShape: CallShape
        public let requestSchema: String
        public let responseSchema: String
        public let progress: Progress?

        public init(
            name: String,
            callShape: CallShape,
            requestSchema: String,
            responseSchema: String,
            progress: Progress? = nil
        ) {
            self.name = name
            self.callShape = callShape
            self.requestSchema = requestSchema
            self.responseSchema = responseSchema
            self.progress = progress
        }
    }

    /// Exact method order exported by the pinned source contract.
    public static let methods: [Method] = [
${literals}
    ]

    private static let methodsByName = Dictionary(uniqueKeysWithValues: methods.map { ($0.name, $0) })

    public static func method(named name: String) -> Method? {
        methodsByName[name]
    }
}

public extension QVACClient {
    /// Invoke any contract method declared as request/reply. Prefer a typed convenience
    /// API when one exists; this surface guarantees newly generated methods are callable.
    func wireRequestReply(
        _ request: QVACRequest,
        rpcOptions: QVACRPCOptions = .init()
    ) async throws -> QVACResponse {
        let method = try Self.requireCallShape(.requestReply, for: request)
        if try Self.usesConditionalProgressTransport(method, request: request) {
            throw QVACError.invalidArgument(
                "\\(request.discriminator) requested progress; use wireProgressStream"
            )
        }
        return try await sendTyped(request, rpcOptions: rpcOptions)
    }

    /// Invoke the conditional progress transport of a request/reply method. This is
    /// available only when the manifest declares progress and the request satisfies
    /// its exact \`withProgress\`/operation condition.
    func wireProgressStream(
        _ request: QVACRequest,
        rpcOptions: QVACRPCOptions = .init()
    ) async throws -> QVACResponseStream<QVACResponse> {
        let method = try Self.requireCallShape(.requestReply, for: request)
        guard method.progress != nil else {
            throw QVACError.invalidArgument(
                "\\(request.discriminator) has no conditional progress transport"
            )
        }
        guard try Self.usesConditionalProgressTransport(method, request: request) else {
            throw QVACError.invalidArgument(
                "\\(request.discriminator) request does not satisfy \\(method.progress!.condition)"
            )
        }
        return try await streamTyped(request, rpcOptions: rpcOptions)
    }

    /// Invoke any contract method declared as a server stream.
    func wireServerStream(
        _ request: QVACRequest,
        rpcOptions: QVACRPCOptions = .init()
    ) async throws -> QVACResponseStream<QVACResponse> {
        _ = try Self.requireCallShape(.serverStream, for: request)
        return try await streamTyped(request, rpcOptions: rpcOptions)
    }

    /// Open any contract method declared as a duplex stream.
    func wireDuplex(
        _ request: QVACRequest,
        rpcOptions: QVACRPCOptions = .init()
    ) async throws -> QVACDuplexSession<QVACResponse> {
        _ = try Self.requireCallShape(.duplex, for: request)
        return try await duplexTyped(request, rpcOptions: rpcOptions)
    }

    private static func requireCallShape(
        _ expected: QVACSDKContract.CallShape,
        for request: QVACRequest
    ) throws -> QVACSDKContract.Method {
        guard let method = QVACSDKContract.method(named: request.discriminator) else {
            throw QVACError.invalidArgument(
                "request discriminator \\(request.discriminator) is not in the pinned SDK contract"
            )
        }
        guard method.callShape == expected else {
            throw QVACError.invalidArgument(
                "\\(request.discriminator) is \\(method.callShape.rawValue), not \\(expected.rawValue)"
            )
        }
        return method
    }

    private static func usesConditionalProgressTransport(
        _ method: QVACSDKContract.Method,
        request: QVACRequest
    ) throws -> Bool {
        guard let progress = method.progress else { return false }
        let data: Data
        do {
            data = try JSONEncoder.qvac.encode(request)
        } catch {
            throw QVACError.encoding("could not inspect progress request: \\(error)")
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw QVACError.encoding("progress request did not encode as an object")
        }
        guard object["withProgress"] as? Bool == true else { return false }
        guard let operations = progress.operations else { return true }
        guard let operation = object["operation"] as? String else {
            return progress.allowsMissingOperation
        }
        return operations.contains(operation)
    }

${typedMethods}
}
`

mkdirSync(dirname(output), { recursive: true })
writeFileSync(output, swift)
console.log(`Wrote ${manifest.methods.length} contract routes -> ${output}`)
