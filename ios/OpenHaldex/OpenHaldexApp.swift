import SwiftUI

@main
struct OpenHaldexApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environmentObject(model.api)
                .preferredColorScheme(.dark)
        }
    }
}
