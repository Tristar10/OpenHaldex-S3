import SwiftUI

/// Mirrors the web UI home page: mode buttons, lock ratio, status flags.
struct HomeView: View {
    @EnvironmentObject var model: AppModel
    @State private var rearBias: Double = 50
    @State private var editingBias = false

    private var s: JSON { model.status }
    private var mode: String { s["mode"].stringValue }
    private var effective: String { s["effectiveMode"].stringValue }

    private static let lockModes = ["5050": 50, "6040": 40, "7030": 30, "8020": 20, "9010": 10, "FWD": 0]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    HStack { ConnectionBadge(); Spacer() }

                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
                        modeButton("Lock", active: Self.lockModes[mode] != nil) { model.setMode(lockMode(for: rearBias)) }
                        modeButton("Throttle", active: mode == "THROTTLE") { model.setMode("THROTTLE") }
                        modeButton("Speed", active: mode == "SPEED") { model.setMode("SPEED") }
                        modeButton("Map", active: mode == "MAP") { model.setMode("MAP") }
                        modeButton("Off", active: mode == "STOCK") { model.setMode("STOCK") }
                        modeButton("RPM", active: mode == "RPM") { model.setMode("RPM") }
                    }

                    ratioCard
                    flagsRow
                    haldexCard
                    if s["canviewCaptureMode"].boolValue {
                        Label("CAN View capture is active — controller held in safe state", systemImage: "exclamationmark.triangle")
                            .font(.footnote).foregroundStyle(.yellow)
                    }
                }
                .padding()
            }
            .navigationTitle("OpenHaldex")
            .refreshable { await model.refreshStatus() }
        }
        .onChange(of: mode) { _, m in
            if !editingBias, let r = Self.lockModes[m] { rearBias = Double(r) }
        }
        .onAppear { if let r = Self.lockModes[mode] { rearBias = Double(r) } }
    }

    private var ratioCard: some View {
        let rear = Self.lockModes[effective].map(Double.init) ?? rearBias
        return VStack(spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 18) {
                ratioNumber(Int(100 - rear), "FRONT")
                Text(":").font(.largeTitle.bold()).foregroundStyle(.secondary)
                ratioNumber(Int(rear), "REAR")
            }
            Slider(value: $rearBias, in: 0...50, step: 10) { editing in
                editingBias = editing
                if !editing { model.setMode(lockMode(for: rearBias)) }
            }
            Text("Slide to set the Lock ratio (applies Lock mode)")
                .font(.caption).foregroundStyle(.secondary)
            if effective != mode && !effective.isEmpty {
                Text("Effective mode: \(modeLabel(effective)) (trigger/protection override)")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        .card()
    }

    private var flagsRow: some View {
        HStack(spacing: 10) {
            flag("TMP", on: s["telemetry"]["tempProtection"].boolValue, onColor: .red)
            flag("CAN", on: s["can"]["ready"].boolValue && !s["can"]["busFailure"].boolValue, onColor: .green,
                 offColor: .red)
            flag("AWD", on: s["telemetry"]["act"].intValue > 0, onColor: .orange)
        }
    }

    private var haldexCard: some View {
        VStack(spacing: 8) {
            ValueRow("Mode", modeLabel(mode))
            ValueRow("Setting", settingText)
            ValueRow("Lock target", "\(s["telemetry"]["spec"].intValue)%")
            ValueRow("Lock actual", "\(s["telemetry"]["act"].intValue)%")
            ValueRow("Haldex temp", s["experimental"]["haldexClutchTempValid"].boolValue
                     ? "\(s["experimental"]["haldexClutchTempC"].intValue) °C" : "—")
            ValueRow("Coupling open", s["telemetry"]["couplingOpen"].boolValue ? "yes" : "no")
        }
        .card()
    }

    private var settingText: String {
        if let r = Self.lockModes[mode] { return "\(100 - r) / \(r)" }
        return modeLabel(mode)
    }

    private func lockMode(for rear: Double) -> String {
        let r = Int(rear)
        if r >= 50 { return "5050" }
        if r >= 40 { return "6040" }
        if r >= 30 { return "7030" }
        if r >= 20 { return "8020" }
        if r >= 10 { return "9010" }
        return "FWD"
    }

    private func ratioNumber(_ v: Int, _ label: String) -> some View {
        VStack(spacing: 0) {
            Text(verbatim: String(v)).font(.system(size: 52, weight: .bold, design: .rounded).monospacedDigit())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func modeButton(_ title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 64)
                .background(active ? Color.orange : Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
                .foregroundStyle(active ? .black : .white)
        }
        .buttonStyle(.plain)
    }

    private func flag(_ t: String, on: Bool, onColor: Color, offColor: Color = .gray) -> some View {
        Text(t)
            .font(.caption.bold())
            .frame(maxWidth: .infinity, minHeight: 32)
            .background((on ? onColor : offColor).opacity(on ? 0.85 : 0.25), in: RoundedRectangle(cornerRadius: 8))
    }
}

extension View {
    func card() -> some View {
        padding()
            .frame(maxWidth: .infinity)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
    }
}
