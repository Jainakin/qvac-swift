import SwiftUI

struct ContentView: View {
    @StateObject private var runner = ProbeRunner()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("QVAC · BareKit Probe").font(.title2).bold()
            Text("iOS · in-process Bare worklet · BareIPC echo").font(.subheadline).foregroundStyle(.secondary)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(runner.log.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            if let r = runner.result {
                Text(r.passed ? "✅ PASS" : "❌ FAIL")
                    .font(.title3).bold()
                    .foregroundStyle(r.passed ? .green : .red)
                Text(r.summary).font(.caption)
            } else {
                Text("Running...").italic().foregroundStyle(.secondary)
            }
        }
        .padding()
        .task { await runner.run() }
    }
}

#Preview {
    ContentView()
}
