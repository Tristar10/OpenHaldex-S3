import SwiftUI

@main
struct OpenHaldexApp: App {
    @StateObject private var link = HaldexLink()
    @StateObject private var settings = AppSettings()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(link)
                .environmentObject(settings)
                .preferredColorScheme(.dark)
        }
    }
}
