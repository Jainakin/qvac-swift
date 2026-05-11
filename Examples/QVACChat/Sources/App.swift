// QVACChat — minimal cross-platform SwiftUI demo for the QVAC Swift client.
// Loads SmolLM2-135M (or any model URL the user pastes), runs streaming completion,
// and displays the tokens as they arrive.

import SwiftUI

@main
struct QVACChatApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 480, minHeight: 600)
        }
    }
}
