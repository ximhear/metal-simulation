import SwiftUI

@main
struct GalaxyCollisionApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)
        }
        #if os(macOS)
        .defaultSize(width: 1240, height: 820)
        .windowResizability(.contentMinSize)
        #endif
    }
}
