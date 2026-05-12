// QVACChat — minimal cross-platform SwiftUI demo for the QVAC Swift client.
// Loads SmolLM2-135M (or any model URL the user pastes), runs streaming completion,
// and displays the tokens as they arrive.

import SwiftUI

@main
struct QVACChatApp: App {
    var body: some Scene {
        WindowGroup {
            // The minWidth/minHeight is a macOS-window default sizing hint — it must
            // NOT apply on iOS, where it would force the view to render wider than
            // the phone's screen and clip the right/top edges.
            #if os(macOS)
            ContentView()
                .frame(minWidth: 480, minHeight: 600)
            #else
            ContentView()
            #endif
        }
    }
}
