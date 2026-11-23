import SwiftUI

/// Mirrors the web UI home page: presets, drivetrain, modes, lock ratio.
/// Landscape shows a "pit board" layout for a phone mount.
struct HomeView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var api: BLEApi
    @EnvironmentObject var presets: PresetStore
    @Environment(\.verticalSizeClass) private var vSize
    @State private var rearBias: Double = 50
    @State private var editingBias = false

    private var s: JSON { model.status }
    // Prefer the 5 Hz live channel; fall back to the last /api/status.
    private var live: LiveStatus? { api.live }
    private var mode: String { live?.mode ?? s["mode"].stringValue }
    private var effective: String { live?.effectiveMode ?? s["effectiveMode"].stringValue }
    private var lockTarget: Int { live?.lockTarget ?? s["telemetry"]["spec"].intValue }
    private var lockActual: Int { live?.lockActual ?? s["telemetry"]["act"].intValue }
    private var tempProtection: Bool { live?.tempProtection ?? s["telemetry"]["tempProtection"].boolValue }
    private var canOk: Bool {
        live.map { $0.canReady && !$0.busFailure } ?? (s["can"]["ready"].boolValue && !s["can"]["busFailure"].boolValue)
    }
    private var clutchTemp: Int? {
        if let live { return live.clutchTempValid ? live.clutchTempC : nil }
        return s["experimental"]["haldexClutchTempValid"].boolValue ? s["experimental"]["haldexClutchTempC"].intValue : nil
    }
    private var tempText: String { clutchTemp.map { "\($0) °C" } ?? "—" }
    private var captureActive: Bool { live?.captureActive ?? s["canviewCaptureMode"].boolValue }
    private var activePreset: Int? { live?.activePreset ?? presets.active }

    static let lockModes = ["5050": 50, "6040": 40, "7030": 30, "8020": 20, "9010": 10, "FWD": 0]

    var body: some View {
        NavigationStack {
            Group {
                if vSize == .compact { pitBoard } else { portrait }
            }
            .background(ThemeBackground())
            .toolbar(vSize == .compact ? .hidden : .visible, for: .navigationBar)
            .navigationTitle("OpenHaldex")
            .refreshable {
                await model.refreshStatus()
                await presets.load(model)
            }
            .task(id: api.state) {
                if model.connected { await presets.load(model) }
            }
        }
        .onChange(of: mode) { _, m in
            if !editingBias, let r = Self.lockModes[m] { rearBias = Double(r) }
        }
        .onAppear { if let r = Self.lockModes[mode] { rearBias = Double(r) } }
        // Haptics: a tap when a mode or preset lands, a warning when the
        // Haldex temperature protection kicks in.
        .sensoryFeedback(.selection, trigger: mode)
        .sensoryFeedback(.success, trigger: activePreset) { _, new in new != nil }
        .sensoryFeedback(.warning, trigger: tempProtection) { _, new in new }
    }

    // MARK: Portrait

    private var portrait: some View {
        ScrollView {
            VStack(spacing: 16) {
                statusRow
                PresetBar()
                drivetrain(carHeight: 470)
                modeStrip
                ratioCard
                haldexCard
                if captureActive {
                    Label("CAN View capture is active — controller held in safe state", systemImage: "exclamationmark.triangle")
                        .font(.footnote).foregroundStyle(.yellow)
                }
            }
            .padding()
        }
    }

    // MARK: Landscape pit board

    private var pitBoard: some View {
        GeometryReader { geo in
            HStack(spacing: 16) {
                HaldexCar(lockActual: lockActual, steeringDeg: live?.steeringDeg, off: mode == "STOCK",
                          live: model.connected, split: split, height: geo.size.height - 8)
                VStack(spacing: 12) {
                    LockGauge(actual: lockActual, target: lockTarget, live: model.connected)
                        .frame(width: min(geo.size.height * 0.62, 230), height: min(geo.size.height * 0.62, 230))
                    HStack(spacing: 18) {
                        bigStat("TARGET", "\(lockTarget)%", Theme.pink)
                        bigStat("CLUTCH", tempText, tempProtection ? Theme.pink : Theme.cyan)
                        bigStat("STEER", live?.steeringDeg.map { String(format: "%+.0f°", $0) } ?? "—", Theme.ice)
                    }
                }
                .frame(maxWidth: .infinity)
                VStack(alignment: .leading, spacing: 10) {
                    statusPills
                    Text(modeLabel(mode).uppercased())
                        .font(.system(size: 34, weight: .heavy, design: .rounded))
                    PresetBar()
                    modeGrid(columns: 3)
                }
                .frame(maxWidth: 330)
            }
            .padding(.horizontal)
            .padding(.vertical, 4)
        }
    }

    private func bigStat(_ label: String, _ value: String, _ color: Color) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.title3.monospacedDigit().bold()).foregroundStyle(color)
            Text(label).font(.caption2.bold()).tracking(1).foregroundStyle(.secondary)
        }
    }

    // MARK: Pieces

    /// Connection badge with the status pills beside it.
    private var statusRow: some View {
        HStack { ConnectionBadge(); Spacer(); statusPills }
    }

    private var statusPills: some View {
        HStack(spacing: 6) {
            pill("CAN", on: canOk, onColor: .green, offColor: Theme.pink, alwaysShow: true)
            pill("AWD", on: lockActual > 0, onColor: Theme.cyan)
            pill("TEMP", on: tempProtection, onColor: Theme.pink)
        }
    }

    private func pill(_ t: String, on: Bool, onColor: Color, offColor: Color? = nil, alwaysShow: Bool = false) -> some View {
        let color = on ? onColor : (offColor ?? Color.gray)
        let lit = on || offColor != nil
        return HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
                .shadow(color: lit ? color : .clear, radius: 3)
            Text(t).font(.caption2.bold()).tracking(1)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(color.opacity(lit ? 0.22 : 0.08), in: Capsule())
        .overlay(Capsule().stroke(lit ? color.opacity(0.6) : Theme.cardStroke, lineWidth: 1))
        .foregroundStyle(lit ? .white : .secondary)
    }

    private func drivetrain(carHeight: CGFloat) -> some View {
        HaldexVisual(lockActual: lockActual, lockTarget: lockTarget, steeringDeg: live?.steeringDeg,
                     off: mode == "STOCK", live: model.connected, split: split,
                     clutchTemp: clutchTemp, tempProtection: tempProtection, carHeight: carHeight)
            .card()
    }

    /// Front/rear split to label on the car, only where it is actually known
    /// (Lock modes have a fixed ratio).
    private var split: (front: Int, rear: Int)? {
        guard let r = Self.lockModes[effective] ?? Self.lockModes[mode] else { return nil }
        return (100 - r, r)
    }

    private var modeStrip: some View { modeGrid(columns: 6) }

    private func modeGrid(columns: Int) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: columns), spacing: 6) {
            modeButton("Lock", "lock.fill", active: Self.lockModes[mode] != nil) { model.setMode(lockMode(for: rearBias)) }
            modeButton("Throttle", "gauge.open.with.lines.needle.33percent", active: mode == "THROTTLE") { model.setMode("THROTTLE") }
            modeButton("Speed", "speedometer", active: mode == "SPEED") { model.setMode("SPEED") }
            modeButton("RPM", "gauge.with.dots.needle.67percent", active: mode == "RPM") { model.setMode("RPM") }
            modeButton("Map", "square.grid.3x3.fill", active: mode == "MAP") { model.setMode("MAP") }
            modeButton("Off", "power", active: mode == "STOCK") { model.setMode("STOCK") }
        }
    }

    private func modeButton(_ title: String, _ icon: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 17, weight: .semibold))
                Text(title).font(.caption2.bold())
            }
            .frame(maxWidth: .infinity, minHeight: 54)
            .background {
                RoundedRectangle(cornerRadius: 12)
                    .fill(active ? AnyShapeStyle(Theme.activeGradient) : AnyShapeStyle(Theme.idle))
                    .shadow(color: active ? Theme.blue.opacity(0.6) : .clear, radius: 8, y: 2)
            }
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(active ? Theme.cyan.opacity(0.7) : Theme.cardStroke, lineWidth: 1))
            .foregroundStyle(active ? .white : Theme.ice.opacity(0.75))
        }
        .buttonStyle(.plain)
    }

    private var ratioCard: some View {
        let rear = Self.lockModes[effective].map(Double.init) ?? rearBias
        return VStack(spacing: 10) {
            if Self.lockModes[mode] == nil {
                // Only Lock has a fixed ratio; Off and the curve/map modes would
                // make a ratio + slider misleading. Tap Lock to get the slider.
                Text(mode == "STOCK" ? "OFF" : modeLabel(mode).uppercased())
                    .font(.system(size: 40, weight: .heavy, design: .rounded))
                Text(modeCaption).font(.caption).foregroundStyle(.secondary)
            } else {
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
            }
            if effective != mode && !effective.isEmpty {
                Text("Effective mode: \(modeLabel(effective)) (trigger/protection override)")
                    .font(.caption).foregroundStyle(Theme.pink)
            }
        }
        .card()
    }

    private var modeCaption: String {
        switch mode {
        case "STOCK": return "Stock Haldex control"
        case "MAP": return "Lock follows the throttle × speed map"
        case "SPEED", "THROTTLE", "RPM": return "Lock follows the \(modeLabel(mode).lowercased()) curve"
        default: return ""
        }
    }

    private var haldexCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle("Haldex")
            ValueRow("Mode", modeLabel(mode))
            ValueRow("Setting", settingText)
            ValueRow("Lock target", "\(lockTarget)%")
            ValueRow("Lock actual", "\(lockActual)%")
            ValueRow("Haldex temp", tempText)
            ValueRow("Coupling open", (live?.couplingOpen ?? s["telemetry"]["couplingOpen"].boolValue) ? "yes" : "no")
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
            Text(verbatim: String(v)).font(.system(size: 52, weight: .heavy, design: .rounded).monospacedDigit())
            Text(label).font(.caption.bold()).tracking(1.5).foregroundStyle(.secondary)
        }
    }
}

extension View {
    func card() -> some View {
        padding()
            .frame(maxWidth: .infinity)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(Theme.cardStroke, lineWidth: 1))
    }
}
