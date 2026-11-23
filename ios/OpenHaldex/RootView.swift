import SwiftUI

struct RootView: View {
    @EnvironmentObject var link: HaldexLink

    var body: some View {
        TabView {
            DashboardView()
                .tabItem { Label("Dash", systemImage: "gauge.with.dots.needle.67percent") }
            SettingsView()
                .tabItem { Label("Settings", systemImage: "slider.horizontal.3") }
        }
        .tint(.orange)
        .task {
            if ProcessInfo.processInfo.arguments.contains("-demo") { link.setDemo(true) }
        }
    }
}

struct ConnectionBadge: View {
    @EnvironmentObject var link: HaldexLink

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text).font(.caption.monospaced())
            if link.sampleRateHz > 0 {
                Text(String(format: "%.0f Hz", link.sampleRateHz))
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private var text: String {
        switch link.state {
        case .bluetoothOff: "Bluetooth off"
        case .unauthorized: "Bluetooth not allowed"
        case .scanning: "Searching…"
        case .connecting(let n): "Connecting \(n)"
        case .connected(let n): n
        case .demo: "DEMO"
        }
    }

    private var color: Color {
        switch link.state {
        case .connected: link.isLive ? .green : .yellow
        case .demo: .purple
        case .scanning, .connecting: .yellow
        default: .red
        }
    }
}
