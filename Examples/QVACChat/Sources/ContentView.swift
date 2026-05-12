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
    @Published var modelURL: String =
        "https://huggingface.co/HuggingFaceTB/SmolLM2-135M-Instruct-GGUF/resolve/main/smollm2-135m-instruct-q4_k_m.gguf"
    @Published var loadPercent: Double = 0
    @Published var isBusy: Bool = false

    private var client: QVACClient?

    func loadModel() async {
        guard !isBusy else { return }
        isBusy = true; defer { isBusy = false }
        status = "Connecting to worker…"
        output = ""
        do {
            let config = try Self.makeDefaultConfig()
            let client = try await QVACClient(configuration: config)
            self.client = client
            status = "Loading model…"
            let (progress, idTask) = try await client.loadModelStreaming(
                modelSrc: modelURL,
                modelType: "llamacpp-completion"
            )
            Task {
                for try await tick in progress {
                    await MainActor.run { self.loadPercent = tick.percentage }
                }
            }
            let id = try await idTask.value
            modelId = id
            status = "Loaded: \(id)"
        } catch {
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
            let run = try await client.completion(
                modelId: modelId,
                history: [.user(prompt)],
                generationParams: .object(["max_new_tokens": .number(120)])
            )
            for try await tok in run.tokenStream {
                await MainActor.run { self.output += tok }
            }
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
            try await client.unloadModel(modelId: modelId)
            self.modelId = nil
            status = "Unloaded"
        } catch {
            status = "Unload error: \(error)"
        }
    }

    private static func makeDefaultConfig() throws -> QVACClient.Configuration {
        #if os(iOS)
        return try .iOSWithBundledResource()
        #elseif os(macOS)
        guard let nodeModulesDir = resolveNodeModulesDir() else {
            throw QVACError.transport(reason:
                "macOS demo needs an @qvac/sdk install. Set QVAC_NODE_MODULES to your " +
                "node_modules dir, or run from the repo root (we'll find spike-js/node_modules)."
            )
        }
        return try .macOS(nodeModulesDir: nodeModulesDir)
        #else
        throw QVACError.transport(reason: "unsupported platform")
        #endif
    }

    #if os(macOS)
    /// Resolve the node_modules dir, in order:
    ///   1. QVAC_NODE_MODULES env var (explicit override).
    ///   2. ./spike-js/node_modules under the current working directory (repo monorepo dev).
    ///   3. nil — caller must configure.
    private static func resolveNodeModulesDir() -> URL? {
        if let env = ProcessInfo.processInfo.environment["QVAC_NODE_MODULES"], !env.isEmpty {
            return URL(fileURLWithPath: env)
        }
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let candidates = [
            cwd.appendingPathComponent("spike-js/node_modules"),
            cwd.appendingPathComponent("node_modules"),
        ]
        for c in candidates where FileManager.default.fileExists(atPath: c.path) {
            return c
        }
        return nil
    }
    #endif
}

struct ContentView: View {
    @StateObject private var vm = ChatViewModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("QVAC Chat — Swift Client demo").font(.title2).bold()
            Text(vm.status).font(.caption).foregroundStyle(.secondary)
            if vm.loadPercent > 0 && vm.loadPercent < 100 {
                ProgressView(value: vm.loadPercent, total: 100)
            }
            Divider()
            TextField("Model URL", text: $vm.modelURL)
                .textFieldStyle(.roundedBorder)
            HStack {
                Button("Load") { Task { await vm.loadModel() } }.disabled(vm.isBusy)
                Button("Unload") { Task { await vm.unload() } }.disabled(vm.modelId == nil)
            }
            Divider()
            Text("Prompt")
            TextEditor(text: $vm.prompt).frame(minHeight: 60).border(.gray.opacity(0.3))
            Button("Run completion") { Task { await vm.runCompletion() } }
                .disabled(vm.modelId == nil || vm.isBusy)
            Divider()
            Text("Output").bold()
            ScrollView {
                Text(vm.output)
                    .font(.system(.body, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding()
    }
}

#Preview {
    ContentView()
}
