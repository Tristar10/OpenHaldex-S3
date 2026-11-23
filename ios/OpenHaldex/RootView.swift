import SwiftUI

struct RootView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        TabView {
            HomeView()
                .tabItem { Label("Home", systemImage: "car.rear") }
            ModesView()
                .tabItem { Label("Modes", systemImage: "chart.xyaxis.line") }
            SetupView()
                .tabItem { Label("Setup", systemImage: "gearshape") }
            DiagView()
                .tabItem { Label("Diagnostics", systemImage: "stethoscope") }
            MoreView()
                .tabItem { Label("More", systemImage: "ellipsis.circle") }
        }
        .tint(.orange)
        .overlay(alignment: .top) { ToastView() }
    }
}

struct ConnectionBadge: View {
    @EnvironmentObject var api: BLEApi

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text).font(.caption)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private var text: String {
        if Mock.enabled { return "Simulator (sample data)" }
        switch api.state {
        case .bluetoothOff: return "Bluetooth off"
        case .unauthorized: return "Bluetooth not allowed"
        case .scanning: return "Searching…"
        case .connecting: return "Connecting…"
        case .ready: return api.deviceName
        }
    }

    private var color: Color {
        if Mock.enabled { return .purple }
        switch api.state {
        case .ready: return .green
        case .scanning, .connecting: return .yellow
        default: return .red
        }
    }
}

struct ToastView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if let t = model.toast {
            Text(t)
                .font(.footnote)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(.thinMaterial, in: Capsule())
                .padding(.top, 4)
                .transition(.move(edge: .top).combined(with: .opacity))
                .task(id: t) {
                    try? await Task.sleep(nanoseconds: 2_500_000_000)
                    if model.toast == t { withAnimation { model.toast = nil } }
                }
        }
    }
}

/// Simple label/value row for read-only status.
struct ValueRow: View {
    let label: String
    let value: String

    init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            Text(value).foregroundStyle(.secondary).monospacedDigit()
        }
    }
}

/// Toggle bound to one `/api/settings` key, reading its value from status.
struct SettingToggle: View {
    @EnvironmentObject var model: AppModel
    let title: String
    let value: Bool
    let patch: (Bool) -> [String: Any]

    var body: some View {
        Toggle(title, isOn: Binding(get: { value }, set: { model.setSettings(patch($0)) }))
    }
}

let allModeNames = ["STOCK", "FWD", "5050", "6040", "7030", "8020", "9010", "SPEED", "THROTTLE", "RPM", "MAP"]

func modeLabel(_ m: String) -> String {
    switch m {
    case "5050": return "50:50"
    case "6040": return "60:40"
    case "7030": return "70:30"
    case "8020": return "80:20"
    case "9010": return "90:10"
    case "FWD", "RPM", "MAP": return m == "MAP" ? "Map" : m
    case "STOCK": return "Stock"
    default: return m.capitalized
    }
}
