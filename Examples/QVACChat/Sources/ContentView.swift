// ContentView — single SwiftUI view that drives a QVACClient end-to-end:
//   load → stream completion → unload, with progress shown live.

import SwiftUI
import QVACClient

@MainActor
final class ChatViewModel: ObservableObject {
    @Published var status: String = "idle"
    @Published var modelId: String? = nil
    @Published var prompt: String = "What is QVAC in one sentence?"
    @Published var output: String = ""
    // Same immutable model revision, byte size, and SHA-256 as the required real-
    // model integration fixture. Do not use a mutable `/resolve/main/` URL here.
    @Published var modelURL: String =
        "https://huggingface.co/bartowski/SmolLM2-135M-Instruct-GGUF/resolve/d255afaffd3441b95abca9b5cc4c819b93f66936/SmolLM2-135M-Instruct-Q4_K_M.gguf"
    @Published var loadPercent: Double = 0
    @Published var isBusy: Bool = false

    private var client: QVACClient?

    func loadModel() async {
        guard !isBusy else { return }
        guard modelId == nil else {
            status = "Unload the current model before loading another"
            return
        }
        isBusy = true; defer { isBusy = false }
        status = "Connecting to worker…"
        output = ""
        loadPercent = 0
        do {
            // `unload()` closes its worker, but also defend against an idle client
            // left by an interrupted UI flow before replacing the reference.
            if let existingClient = client {
                await existingClient.close()
                client = nil
            }
            let config = try Self.makeDefaultConfig()
            let client = try await QVACClient(configuration: config)
            self.client = client
            status = "Loading model…"
            let load = try await client.loadModelStreaming(
                modelSrc: modelURL,
                modelType: "llamacpp-completion",
                rpcOptions: .init(timeout: .seconds(600))
            )
            let progressTask = Task { @MainActor in
                for try await tick in load.progress {
                    self.loadPercent = tick.percentage
                }
            }
            let id: String
            do {
                id = try await load.result.value
                try await progressTask.value
            } catch {
                progressTask.cancel()
                _ = try? await progressTask.value
                throw error
            }
            modelId = id
            loadPercent = 100
            status = "Loaded: \(id)"
        } catch {
            // Covers failures before a progress task exists as well as failures
            // after it starts. Never leave a worker hidden behind a failed load.
            if let failedClient = client, modelId == nil {
                await failedClient.close()
                client = nil
            }
            status = "Error: \(error)"
        }
    }

    func runCompletion() async {
        guard let client, let modelId else { status = "Load a model first"; return }
        guard !isBusy else { return }
        isBusy = true; defer { isBusy = false }
        output = ""
        status = "Streaming completion…"
        do {
            // generationParams schema is .strict() — only the keys in
            // @qvac/sdk's generationParamsSchema are accepted:
            // temp, top_p, top_k, predict, seed, frequency_penalty,
            // presence_penalty, repeat_penalty. `predict` is the max-tokens
            // budget (-1 = until stop, -2 = until ctx full).
            let run = try await client.completion(
                modelId: modelId,
                history: [.user(prompt)],
                generationParams: .object(["predict": .number(120)]),
                rpcOptions: .init(timeout: .seconds(60))
            )
            for try await tok in run.tokenStream {
                output += tok
            }
            _ = try await run.final.value
            status = "Done"
        } catch {
            status = "Error: \(error)"
        }
    }

    func unload() async {
        guard let client, let modelId else { return }
        isBusy = true; defer { isBusy = false }
        status = "Unloading…"
        do {
            try await client.unloadModel(
                modelId: modelId,
                rpcOptions: .init(timeout: .seconds(10))
            )
            await client.close()
            self.client = nil
            self.modelId = nil
            loadPercent = 0
            status = "Unloaded"
        } catch {
            status = "Unload error: \(error)"
        }
    }

    func close() async {
        guard let client else { return }
        if let modelId {
            _ = try? await client.unloadModel(
                modelId: modelId,
                rpcOptions: .init(timeout: .seconds(10))
            )
        }
        await client.close()
        self.client = nil
        self.modelId = nil
        loadPercent = 0
    }

    private static func makeDefaultConfig() throws -> QVACClient.Configuration {
        #if os(iOS)
        return try .iOSWithBundledResource()
        #elseif os(macOS)
        guard let nodeModulesDir = resolveNodeModulesDir() else {
            throw QVACError.transport(reason:
                "macOS demo needs an @qvac/sdk install. Set QVAC_NODE_MODULES to your " +
                "node_modules dir, or materialize tools/runtime/node_modules from the repo."
            )
        }
        return try .macOS(nodeModulesDir: nodeModulesDir)
        #else
        throw QVACError.transport(reason: "unsupported platform")
        #endif
    }

    #if os(macOS)
    /// Resolve an exact SDK runtime from an explicit environment override or a
    /// nearby repository checkout. Every candidate must contain the 0.17 worker.
    private static func resolveNodeModulesDir() -> URL? {
        if let env = ProcessInfo.processInfo.environment["QVAC_NODE_MODULES"], !env.isEmpty {
            let candidate = URL(fileURLWithPath: env)
            if containsWorker(candidate) { return candidate }
        }

        var directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        for _ in 0..<6 {
            let candidates = [
                directory.appendingPathComponent("tools/runtime/node_modules"),
                directory.appendingPathComponent("node_modules"),
            ]
            if let match = candidates.first(where: containsWorker) { return match }
            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path { break }
            directory = parent
        }
        return nil
    }

    private static func containsWorker(_ nodeModules: URL) -> Bool {
        FileManager.default.fileExists(
            atPath: nodeModules
                .appendingPathComponent("@qvac/sdk/dist/server/worker.js")
                .path
        )
    }
    #endif
}

struct ContentView: View {
    @StateObject private var vm = ChatViewModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                statusCard
                modelCard
                promptCard
                outputCard
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollDismissesKeyboard(.interactively)
        .dynamicTypeSize(...DynamicTypeSize.xLarge)
        .onDisappear {
            Task { await vm.close() }
        }
    }

    // MARK: - Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("QVAC Chat")
                .font(.largeTitle.bold())
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            Text("Swift Client Demo")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var statusCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: vm.isBusy ? "ellipsis.circle" : "checkmark.circle")
                        .foregroundStyle(.secondary)
                    Text(vm.status)
                        .font(.callout)
                        .foregroundStyle(.primary)
                        .lineLimit(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if vm.loadPercent > 0 && vm.loadPercent < 100 {
                    ProgressView(value: vm.loadPercent, total: 100)
                        .progressViewStyle(.linear)
                }
            }
        }
    }

    private var modelCard: some View {
        Card(title: "Model") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Model URL")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                TextField("https://.../model.gguf", text: $vm.modelURL, axis: .vertical)
                    .lineLimit(2...5)
                    .font(.system(.caption2, design: .monospaced))
                    .qvacURLInputBehavior()
                    .padding(10)
                    .background(softBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                HStack(spacing: 10) {
                    Button {
                        Task { await vm.loadModel() }
                    } label: {
                        Text("Load")
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .frame(maxWidth: .infinity, minHeight: 32)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(vm.isBusy || vm.modelId != nil)

                    Button {
                        Task { await vm.unload() }
                    } label: {
                        Text("Unload")
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .frame(maxWidth: .infinity, minHeight: 32)
                    }
                    .buttonStyle(.bordered)
                    .disabled(vm.modelId == nil)
                }
                if let id = vm.modelId {
                    Text("Loaded model: \(id)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var promptCard: some View {
        Card(title: "Prompt") {
            VStack(alignment: .leading, spacing: 10) {
                TextField("Ask anything…", text: $vm.prompt, axis: .vertical)
                    .lineLimit(3...8)
                    .font(.callout)
                    .padding(10)
                    .background(softBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                Button {
                    Task { await vm.runCompletion() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "play.fill")
                        Text("Run")
                    }
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .frame(maxWidth: .infinity, minHeight: 36)
                }
                .buttonStyle(.borderedProminent)
                .disabled(vm.modelId == nil || vm.isBusy)
            }
        }
    }

    private var outputCard: some View {
        Card(title: "Output") {
            if vm.output.isEmpty {
                Text("(no output yet)")
                    .foregroundStyle(.tertiary)
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
            } else {
                Text(vm.output)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(softBackground)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    // MARK: - Style helpers

    private var softBackground: Color {
        #if os(iOS)
        return Color(.secondarySystemBackground)
        #else
        return Color.gray.opacity(0.12)
        #endif
    }
}

private extension View {
    @ViewBuilder
    func qvacURLInputBehavior() -> some View {
        #if os(iOS)
        autocorrectionDisabled()
            .textInputAutocapitalization(.never)
        #else
        self
        #endif
    }
}

private struct Card<Content: View>: View {
    let title: String?
    @ViewBuilder let content: () -> Content

    init(title: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                Text(title.uppercased())
                    .font(.caption2.weight(.bold))
                    .tracking(0.5)
                    .foregroundStyle(.secondary)
            }
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var cardBackground: Color {
        #if os(iOS)
        return Color(.tertiarySystemBackground)
        #else
        return Color.gray.opacity(0.08)
        #endif
    }
}

#Preview {
    ContentView()
}
