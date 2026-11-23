import SwiftUI

/// Preset catalog as the firmware reports it (/api/presets).
struct PresetItem: Identifiable, Equatable {
    var id: Int
    var name: String
    var mode: String
    var map: String
    var mapLoaded: Bool = true
    var disableThrottle: Int = -1
    var disableSpeed: Int = -1
    var releaseRate: Double = -1

    init(_ j: JSON) {
        id = j["id"].intValue
        name = j["name"].stringValue
        mode = j["mode"].string ?? "STOCK"
        map = j["map"].stringValue
        mapLoaded = j["mapLoaded"].bool ?? true
        disableThrottle = j["disableThrottle"].int ?? -1
        disableSpeed = j["disableSpeed"].int ?? -1
        releaseRate = j["lockReleaseRatePctPerSec"].double ?? -1
    }

    init(id: Int) {
        self.id = id
        name = "Preset \(id)"
        mode = "5050"
        map = ""
    }

    var json: [String: Any] {
        var o: [String: Any] = ["id": id, "name": name, "mode": mode, "map": mode == "MAP" ? map : ""]
        if disableThrottle >= 0 { o["disableThrottle"] = disableThrottle }
        if disableSpeed >= 0 { o["disableSpeed"] = disableSpeed }
        if releaseRate >= 0 { o["lockReleaseRatePctPerSec"] = releaseRate }
        return o
    }

    var summary: String {
        var parts = [modeLabel(mode)]
        if mode == "MAP", !map.isEmpty { parts.append((map as NSString).lastPathComponent) }
        if !mapLoaded && !map.isEmpty { parts.append("map missing") }
        return parts.joined(separator: " · ")
    }
}

@MainActor
final class PresetStore: ObservableObject {
    @Published var items: [PresetItem] = []
    @Published var version = 0
    @Published var active: Int?
    @Published var custom = false

    func load(_ model: AppModel) async {
        guard let j = try? await model.get("/api/presets") else { return }
        items = j["presets"].array.map(PresetItem.init)
        version = j["version"].intValue
        let a = j["active"].intValue
        active = a == 255 ? nil : a
        custom = j["custom"].boolValue
    }

    func apply(_ item: PresetItem, model: AppModel) {
        model.perform(item.name) {
            let r = try await model.post("/api/presets/apply", ["id": item.id, "version": self.version])
            let a = r["active"].intValue
            self.active = a == 255 ? nil : a
        }
    }
}

/// Row of preset buttons for the Home screen.
struct PresetBar: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var api: BLEApi
    @EnvironmentObject var presets: PresetStore

    var body: some View {
        if !presets.items.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("PRESETS").font(.caption.bold()).foregroundStyle(.secondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(presets.items) { p in
                            let on = p.id == activeId
                            Button { presets.apply(p, model: model) } label: {
                                VStack(spacing: 2) {
                                    Text(p.name).font(.headline)
                                    Text(modeLabel(p.mode)).font(.caption2).opacity(0.8)
                                }
                                .padding(.horizontal, 16).padding(.vertical, 10)
                                .background(on ? Color.orange : Color.white.opacity(0.08),
                                            in: RoundedRectangle(cornerRadius: 12))
                                .foregroundStyle(on ? .black : .white)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    private var activeId: Int? { api.live?.activePreset ?? presets.active }
}

/// Modes tab: view, apply and edit the preset catalog.
struct PresetsEditor: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var presets: PresetStore
    @State private var draft: [PresetItem] = []
    @State private var maps: [String] = []
    @State private var confirmReset = false

    var body: some View {
        Form {
            Section {
                ForEach($draft) { $p in
                    NavigationLink {
                        PresetDetail(preset: $p, maps: maps)
                    } label: {
                        VStack(alignment: .leading) {
                            Text(p.name)
                            Text(p.summary).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { draft.remove(atOffsets: $0) }
                .onMove { draft.move(fromOffsets: $0, toOffset: $1) }
                Button("Add preset") {
                    let next = (0...254).first { id in !draft.contains { $0.id == id } } ?? 254
                    draft.append(PresetItem(id: next))
                }
                .disabled(draft.count >= 8)
            } header: {
                Text("Presets (\(draft.count)/8)")
            } footer: {
                Text("Shown on the MMI and on Home in this order. Names up to 16 characters. A preset only changes the settings it specifies.")
            }
            Section {
                Button("Save to controller") { save() }.disabled(!valid || draft == presets.items)
                Button("Discard changes") { draft = presets.items }.disabled(draft == presets.items)
                Button("Restore default presets", role: .destructive) { confirmReset = true }
            } footer: {
                Text(presets.custom ? "Using your saved presets." : "Using the built-in default presets.")
            }
        }
        .navigationTitle("Presets")
        .toolbar { EditButton() }
        .task {
            await presets.load(model)
            draft = presets.items
            if let j = try? await model.get("/api/maps") {
                maps = j["maps"].array.map { $0["path"].stringValue }.filter { !$0.isEmpty }
            }
        }
        .confirmationDialog("Replace your presets with the built-in defaults?", isPresented: $confirmReset,
                            titleVisibility: .visible) {
            Button("Restore defaults", role: .destructive) {
                model.perform("Defaults restored") {
                    try await model.post("/api/presets/reset")
                    await presets.load(model)
                    draft = presets.items
                }
            }
        }
    }

    private var valid: Bool {
        !draft.isEmpty && draft.allSatisfy { p in
            !p.name.trimmingCharacters(in: .whitespaces).isEmpty && p.name.count <= 16 &&
                (p.mode != "MAP" || !p.map.isEmpty)
        } && Set(draft.map(\.id)).count == draft.count
    }

    private func save() {
        let body: [String: Any] = ["presets": draft.map(\.json)]
        model.perform("Presets saved") {
            try await model.post("/api/presets", body)
            await presets.load(model)
            draft = presets.items
        }
    }
}

struct PresetDetail: View {
    @Binding var preset: PresetItem
    let maps: [String]

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $preset.name)
                    .onChange(of: preset.name) { _, v in if v.count > 16 { preset.name = String(v.prefix(16)) } }
                Picker("Mode", selection: $preset.mode) {
                    ForEach(allModeNames, id: \.self) { Text(modeLabel($0)).tag($0) }
                }
                if preset.mode == "MAP" {
                    Picker("Map", selection: $preset.map) {
                        Text("Choose…").tag("")
                        ForEach(maps, id: \.self) { Text(($0 as NSString).lastPathComponent).tag($0) }
                    }
                }
            }
            Section {
                optionalStepper("Disable above throttle", value: $preset.disableThrottle, range: 0...100, step: 5, unit: "%")
                optionalStepper("Disable above speed", value: $preset.disableSpeed, range: 0...300, step: 5, unit: " km/h")
                Toggle("Set release ramp", isOn: Binding(
                    get: { preset.releaseRate >= 0 },
                    set: { preset.releaseRate = $0 ? 50 : -1 }))
                if preset.releaseRate >= 0 {
                    Stepper("Release \(preset.releaseRate == 0 ? "instant" : "\(Int(preset.releaseRate)) %/s")",
                            value: $preset.releaseRate, in: 0...500, step: 10)
                }
            } header: {
                Text("Optional gates")
            } footer: {
                Text("Off = this preset leaves the setting as it is. 0 on a gate turns that gate off.")
            }
        }
        .navigationTitle(preset.name)
    }

    private func optionalStepper(_ title: String, value: Binding<Int>, range: ClosedRange<Int>, step: Int,
                                 unit: String) -> some View {
        Group {
            Toggle("Set \(title.lowercased())", isOn: Binding(
                get: { value.wrappedValue >= 0 },
                set: { value.wrappedValue = $0 ? 0 : -1 }))
            if value.wrappedValue >= 0 {
                Stepper("\(title) \(value.wrappedValue == 0 ? "off" : "\(value.wrappedValue)\(unit)")",
                        value: value, in: range, step: step)
            }
        }
    }
}
