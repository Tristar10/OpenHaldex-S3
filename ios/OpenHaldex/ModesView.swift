import SwiftUI

/// Web UI pages: Speed / Throttle / RPM settings and the Map editor.
struct ModesView: View {
    var body: some View {
        NavigationStack {
            List {
                Section("Presets") {
                    NavigationLink("Presets") { PresetsEditor() }
                }
                Section("Curve modes") {
                    NavigationLink("Speed") { CurveEditor(kind: .speed) }
                    NavigationLink("Throttle") { CurveEditor(kind: .throttle) }
                    NavigationLink("RPM") { CurveEditor(kind: .rpm) }
                }
                Section("Map mode") {
                    NavigationLink("Map editor") { MapEditor() }
                }
                Section("All modes") {
                    NavigationLink("Gates & release ramp") { Form { GateSettings(modeKey: nil) }.navigationTitle("Gates") }
                }
            }
            .navigationTitle("Modes")
        }
    }
}

// MARK: - Curves

enum CurveKind: String {
    case speed, throttle, rpm

    var endpoint: String { "/api/curve/\(rawValue)" }
    var title: String { rawValue == "rpm" ? "RPM" : rawValue.capitalized }
    var xUnit: String { self == .speed ? "km/h" : (self == .throttle ? "%" : "rpm") }
    var xMax: Int { self == .speed ? 300 : (self == .throttle ? 100 : 10000) }
    var step: Int { self == .rpm ? 100 : 1 }
}

struct CurvePoint: Identifiable, Equatable {
    let id = UUID()
    var x: Int
    var lock: Int
}

struct CurveEditor: View {
    @EnvironmentObject var model: AppModel
    let kind: CurveKind
    @State private var points: [CurvePoint] = []
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                ForEach($points) { $p in
                    HStack {
                        Stepper(value: $p.x, in: 0...kind.xMax, step: kind.step) {
                            Text("\(p.x) \(kind.xUnit)").monospacedDigit()
                        }
                        Divider()
                        Stepper(value: $p.lock, in: 0...100, step: 5) {
                            Text("\(p.lock)%").monospacedDigit().frame(minWidth: 44, alignment: .trailing)
                        }
                    }
                }
                .onDelete { points.remove(atOffsets: $0) }
                Button("Add point") {
                    let last = points.last ?? CurvePoint(x: 0, lock: 0)
                    points.append(CurvePoint(x: min(kind.xMax, last.x + (kind == .rpm ? 500 : 10)), lock: last.lock))
                }
                .disabled(points.count >= 16)
            } header: {
                Text("\(kind.title) → lock %")
            } footer: {
                Text("Points must be in ascending \(kind.title.lowercased()) order. Swipe to delete.")
            }
            if let error { Text(error).foregroundStyle(.red).font(.footnote) }
            Section {
                Button("Save curve") { save() }.disabled(!ascending || points.isEmpty)
                Button("Reload from controller") { Task { await load() } }
                Button("Use \(kind.title) mode now") { model.setMode(kind.rawValue.uppercased()) }
            }
            GateSettings(modeKey: kind.rawValue)
        }
        .navigationTitle(kind.title)
        .overlay { if loading { ProgressView() } }
        .task { await load() }
    }

    private var ascending: Bool { zip(points, points.dropFirst()).allSatisfy { $0.x < $1.x } }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            let j = try await model.get(kind.endpoint)
            points = j["points"].array.map { CurvePoint(x: $0["x"].intValue, lock: $0["lock"].intValue) }
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    private func save() {
        let body: [String: Any] = ["points": points.map { ["x": $0.x, "lock": $0.lock] }]
        model.perform("\(kind.title) curve saved") { try await model.post(kind.endpoint, body) }
    }
}

// MARK: - Gates (shared by curve pages and the map page)

struct GateSettings: View {
    @EnvironmentObject var model: AppModel
    /// "speed" / "throttle" / "rpm" / "map" for the per-mode disengage value, nil for global-only.
    let modeKey: String?
    @State private var disengage = 0
    @State private var disableThrottle = 0
    @State private var disableSpeed = 0
    @State private var release = 0.0
    @State private var loaded = false

    // A Section, so it can sit inside the curve/map Forms. It must be used as a
    // real child view (not via a property) so its EnvironmentObject resolves.
    var body: some View {
        Section {
            if let modeKey {
                Stepper("Disengage under \(disengage) km/h", value: $disengage, in: 0...300, step: 5)
                    .help("0 = off")
                    .onChange(of: disengage) { _, _ in } // value saved with button
                    .accessibilityIdentifier("disengage-\(modeKey)")
            }
            Stepper("Disable above throttle \(label(disableThrottle, "%"))", value: $disableThrottle, in: 0...100, step: 5)
            Stepper("Disable above speed \(label(disableSpeed, " km/h"))", value: $disableSpeed, in: 0...300, step: 5)
            Stepper("Release ramp \(release == 0 ? "instant" : "\(Int(release)) %/s")", value: $release, in: 0...500, step: 10)
            Button("Save gates") { save() }
            SettingToggle(title: "Controller enabled", value: !model.status["disableController"].boolValue) {
                ["disableController": !$0]
            }
            SettingToggle(title: "Broadcast OpenHaldex over CAN",
                          value: model.status["broadcastOpenHaldexOverCAN"].boolValue) {
                ["broadcastOpenHaldexOverCAN": $0]
            }
        } header: {
            Text("Gates & release")
        } footer: {
            Text("0 turns a gate off.")
        }
        .onAppear(perform: syncFromStatus)
    }

    private func label(_ v: Int, _ unit: String) -> String { v == 0 ? "off" : "\(v)\(unit)" }

    private func syncFromStatus() {
        guard !loaded, !model.status.isNull else { return }
        let s = model.status
        if let modeKey { disengage = s["disengageUnderSpeed"][modeKey].intValue }
        disableThrottle = s["disableThrottle"].intValue
        disableSpeed = s["disableSpeed"].intValue
        release = s["lockReleaseRatePctPerSec"].doubleValue
        loaded = true
    }

    private func save() {
        var patch: [String: Any] = [
            "disableThrottle": disableThrottle,
            "disableSpeed": disableSpeed,
            "lockReleaseRatePctPerSec": release,
        ]
        if let modeKey { patch["disengageUnderSpeed"] = [modeKey: disengage] }
        model.setSettings(patch, label: "Gates saved")
    }
}

// MARK: - Map

struct MapEditor: View {
    @EnvironmentObject var model: AppModel
    @State private var speedBins: [Int] = []
    @State private var throttleBins: [Int] = []
    @State private var table: [[Int]] = []
    @State private var maps: [JSON] = []
    @State private var current = ""
    @State private var saveName = ""
    @State private var editing: (t: Int, s: Int)?
    @State private var editValue = 0
    @State private var loading = true

    var body: some View {
        Form {
            Section {
                ScrollView(.horizontal) { grid.padding(.vertical, 4) }
                Text("Rows: throttle %. Columns: speed km/h. Tap a cell to edit.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Save active map") { saveActive() }
                Button("Use Map mode now") { model.setMode("MAP") }
            } header: { Text("Lock table (%)") }

            Section("Saved maps") {
                ForEach(maps.indices, id: \.self) { i in
                    let path = maps[i]["path"].string ?? maps[i].string ?? ""
                    HStack {
                        Text(maps[i]["name"].string ?? (path as NSString).lastPathComponent)
                        if path == current { Image(systemName: "checkmark").foregroundStyle(.orange) }
                        Spacer()
                        Button("Load") { loadMap(path) }.buttonStyle(.borderless)
                    }
                    .swipeActions {
                        Button("Delete", role: .destructive) { deleteMap(path) }
                    }
                }
                HStack {
                    TextField("Save current as…", text: $saveName)
                    Button("Save") { saveAs() }.disabled(saveName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            GateSettings(modeKey: "map")
        }
        .navigationTitle("Map")
        .overlay { if loading { ProgressView() } }
        .task { await load() }
        .sheet(isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
            if let e = editing {
                VStack(spacing: 16) {
                    Text("Throttle \(throttleBins[safe: e.t] ?? 0)% · Speed \(speedBins[safe: e.s] ?? 0) km/h")
                        .font(.headline)
                    Text("\(editValue)%").font(.system(size: 48, weight: .bold).monospacedDigit())
                    Slider(value: Binding(get: { Double(editValue) }, set: { editValue = Int($0) }), in: 0...100, step: 1)
                    Button("Set") {
                        table[e.t][e.s] = editValue
                        editing = nil
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding()
                .presentationDetents([.height(280)])
            }
        }
    }

    private var grid: some View {
        Grid(horizontalSpacing: 2, verticalSpacing: 2) {
            GridRow {
                Text("T\\S").font(.caption2).foregroundStyle(.secondary)
                ForEach(speedBins.indices, id: \.self) { s in
                    Text("\(speedBins[s])").font(.caption2.bold()).frame(width: 38)
                }
            }
            ForEach(table.indices, id: \.self) { t in
                GridRow {
                    Text("\(throttleBins[safe: t] ?? 0)%").font(.caption2.bold())
                    ForEach(table[t].indices, id: \.self) { s in
                        let v = table[t][s]
                        Text("\(v)")
                            .font(.caption.monospacedDigit())
                            .frame(width: 38, height: 30)
                            .background(Color.orange.opacity(0.1 + 0.8 * Double(v) / 100), in: RoundedRectangle(cornerRadius: 4))
                            .onTapGesture {
                                editValue = v
                                editing = (t, s)
                            }
                    }
                }
            }
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            let m = try await model.get("/api/map")
            speedBins = m["speedBins"].array.map(\.intValue)
            throttleBins = m["throttleBins"].array.map(\.intValue)
            table = m["lockTable"].array.map { $0.array.map(\.intValue) }
            let list = try await model.get("/api/maps")
            maps = list["maps"].array
            current = list["current"].stringValue
        } catch {
            model.toast = "Map load failed: \(error.localizedDescription)"
        }
    }

    private func saveActive() {
        let body: [String: Any] = ["speedBins": speedBins, "throttleBins": throttleBins, "lockTable": table]
        model.perform("Map saved") { try await model.post("/api/map", body) }
    }

    private func loadMap(_ path: String) {
        model.perform("Loaded \((path as NSString).lastPathComponent)") {
            try await model.post("/api/maps/load", ["path": path])
            await load()
        }
    }

    private func saveAs() {
        let name = saveName.trimmingCharacters(in: .whitespaces)
        model.perform("Saved \(name)") {
            try await model.post("/api/maps/save", ["name": name])
            saveName = ""
            await load()
        }
    }

    private func deleteMap(_ path: String) {
        model.perform("Deleted") {
            try await model.post("/api/maps/delete", ["path": path])
            await load()
        }
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
