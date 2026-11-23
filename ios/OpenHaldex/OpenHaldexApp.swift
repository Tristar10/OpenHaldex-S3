import SwiftUI

@main
struct OpenHaldexApp: App {
    @StateObject private var model = AppModel()
    @StateObject private var presets = PresetStore()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environmentObject(model.api)
                .environmentObject(presets)
                .preferredColorScheme(.dark)
        }
    }
}
