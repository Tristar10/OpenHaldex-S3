import SwiftUI

/// Web UI "Signal Setup" page: generation, power, input mapping, CAN mode
/// trigger, experimental features, and Haldex calibration (learn).
struct SetupView: View {
    @EnvironmentObject var model: AppModel
    private var s: JSON { model.status }

    var body: some View {
        NavigationStack {
            ThemedForm {
                Section("Haldex generation") {
                    Picker("Generation", selection: Binding(
                        get: { s["haldexGeneration"].intValue },
                        set: { model.setSettings(["haldexGeneration": $0], label: "Generation set") })) {
                        Text("Gen 1").tag(1)
                        Text("Gen 2").tag(2)
                        Text("Gen 4").tag(4)
                        Text("Gen 5").tag(5)
                    }
                    .pickerStyle(.segmented)
                }

                Section("Power") {
                    SettingToggle(title: "Low-power sleep when parked",
                                  value: s["power"]["lowPowerSleepEnabled"].boolValue) {
                        ["lowPower": ["sleepEnabled": $0]]
                    }
                    ValueRow("Ignition", s["power"]["ignitionOn"].boolValue ? "on" : "off")
                    ValueRow("Low-power active", s["power"]["active"].boolValue ? "yes" : "no")
                }

                Section {
                    mappingRow("Speed", key: "speed")
                    mappingRow("Throttle", key: "throttle")
                    mappingRow("RPM", key: "rpm")
                    Button("Clear input mappings", role: .destructive) {
                        model.setSettings(["inputMappings": ["speed": "", "throttle": "", "rpm": ""]],
                                          label: "Mappings cleared")
                    }
                } header: {
                    Text("Mapped inputs")
                } footer: {
                    Text(s["telemetry"]["inputsMapped"].boolValue
                         ? "Inputs mapped — curve modes can run."
                         : "Inputs not mapped — curve modes fall back to stock.")
                }

                NavigationLink("CAN mode trigger") { ModeTriggerView() }
                NavigationLink("Experimental features") { ExperimentalView() }
                NavigationLink("Calibrate Haldex output") { LearnView() }
            }
            .navigationTitle("Setup")
        }
    }

    private func mappingRow(_ title: String, key: String) -> some View {
        NavigationLink {
            SignalPicker(title: "\(title) signal") { signalKey in
                model.setSettings(["inputMappings": [key: signalKey]], label: "\(title) mapped")
            }
        } label: {
            VStack(alignment: .leading) {
                Text(title)
                Text(signalLabel(s["inputMappings"][key].stringValue))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

func signalLabel(_ key: String) -> String {
    let parts = key.split(separator: "|")
    if parts.count >= 3 { return "\(parts[2]) (\(parts[0]) \(parts[1]))" }
    return key.isEmpty ? "Not mapped" : key
}

/// Lists live decoded signals from CAN View; picking one returns the firmware's
/// mapping key ("bus|0xid|name|unit", same as the web UI builds).
struct SignalPicker: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let title: String
    let onPick: (String) -> Void
    @State private var signals: [JSON] = []
    @State private var filter = ""

    var body: some View {
        List(filtered.indices, id: \.self) { i in
            let sig = filtered[i]
            Button {
                onPick(key(for: sig))
                dismiss()
            } label: {
                HStack {
                    VStack(alignment: .leading) {
                        Text(sig["name"].stringValue)
                        Text("\(sig["bus"].stringValue) 0x\(String(sig["id"].intValue, radix: 16, uppercase: true))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("\(sig["value"].display) \(sig["unit"].stringValue)").foregroundStyle(.secondary)
                }
            }
        }
        .searchable(text: $filter)
        .navigationTitle(title)
        .task { await load() }
        .refreshable { await load() }
        .overlay { if signals.isEmpty { Text("No decoded signals yet").foregroundStyle(.secondary) } }
    }

    private var filtered: [JSON] {
        filter.isEmpty ? signals : signals.filter { $0["name"].stringValue.localizedCaseInsensitiveContains(filter) }
    }

    private func key(for sig: JSON) -> String {
        let bus = sig["bus"].stringValue.lowercased()
        let id = String(sig["id"].intValue, radix: 16)
        let name = sig["name"].stringValue.replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespaces).lowercased()
        let unit = sig["unit"].stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        return "\(bus)|0x\(id)|\(name)|\(unit)"
    }

    private func load() async {
        if let j = try? await model.get("/api/canview", query: ["decoded": "300", "raw": "0", "bus": "all"]) {
            signals = j["decoded"].array.filter { $0["value"].double != nil }
        }
    }
}

struct ModeTriggerView: View {
    @EnvironmentObject var model: AppModel
    @State private var enabled = false
    @State private var mode = "5050"
    @State private var op = "eq"
    @State private var value = 1.0
    @State private var signal = ""
    @State private var broadcast = true
    @State private var loaded = false

    private let ops = ["gt": ">", "gte": "≥", "lt": "<", "lte": "≤", "eq": "=", "neq": "≠", "change": "changes"]

    var body: some View {
        let t = model.status["modeTrigger"]
        ThemedForm {
            Section {
                Toggle("Enabled", isOn: $enabled)
                NavigationLink {
                    SignalPicker(title: "Trigger signal") { signal = $0 }
                } label: {
                    VStack(alignment: .leading) {
                        Text("When signal")
                        Text(signalLabel(signal)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Picker("Is", selection: $op) {
                    ForEach(ops.keys.sorted(), id: \.self) { Text(ops[$0]!).tag($0) }
                }
                if op != "change" {
                    HStack {
                        Text("Value")
                        TextField("Value", value: $value, format: .number)
                            .keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                    }
                }
                Picker("Switch to mode", selection: $mode) {
                    ForEach(allModeNames, id: \.self) { Text(modeLabel($0)).tag($0) }
                }
                Toggle("Broadcast OpenHaldex over CAN while active", isOn: $broadcast)
                Button("Save trigger") {
                    model.setSettings(["modeTrigger": ["enabled": enabled, "signal": signal, "operator": op,
                                                       "value": value, "mode": mode,
                                                       "broadcastOpenHaldexOverCAN": broadcast]],
                                      label: "Trigger saved")
                }
            }
            Section("Live") {
                ValueRow("Active", t["active"].boolValue ? "yes" : "no")
                ValueRow("Signal seen", t["seen"].boolValue ? "yes" : "no")
                ValueRow("Last value", t["lastValue"].display)
                ValueRow("Effective mode", modeLabel(t["effectiveMode"].stringValue))
            }
        }
        .navigationTitle("CAN mode trigger")
        .onAppear {
            guard !loaded else { return }
            enabled = t["enabled"].boolValue
            mode = t["mode"].string ?? "5050"
            op = t["operator"].string ?? "eq"
            value = t["value"].doubleValue
            signal = t["signal"].stringValue
            broadcast = t["broadcastOpenHaldexOverCAN"].bool ?? true
            loaded = true
        }
    }
}

struct ExperimentalView: View {
    @EnvironmentObject var model: AppModel
    @State private var enabled = false
    @State private var reverseOn = false
    @State private var reverseMode = "FWD"
    @State private var thermalOn = false
    @State private var thermalMode = "STOCK"
    @State private var threshold = 90
    @State private var loaded = false

    var body: some View {
        let e = model.status["experimental"]
        ThemedForm {
            Section {
                Toggle("Experimental features", isOn: $enabled)
            } footer: {
                Text("Master switch. Features below only run while this is on.")
            }
            Section("Reverse auto-switch") {
                Toggle("Switch mode in reverse", isOn: $reverseOn)
                Picker("Target mode", selection: $reverseMode) {
                    ForEach(allModeNames, id: \.self) { Text(modeLabel($0)).tag($0) }
                }
                ValueRow("Reverse active", e["reverseActive"].boolValue ? "yes" : "no")
            }
            Section("Haldex thermal protection") {
                Toggle("Protect when hot", isOn: $thermalOn)
                Picker("Target mode", selection: $thermalMode) {
                    ForEach(allModeNames, id: \.self) { Text(modeLabel($0)).tag($0) }
                }
                Stepper("Threshold \(threshold) °C", value: $threshold, in: 40...150, step: 5)
                ValueRow("Clutch temp", e["haldexClutchTempValid"].boolValue ? "\(e["haldexClutchTempC"].intValue) °C" : "—")
            }
            Button("Save experimental settings") {
                model.setSettings([
                    "experimentalFeaturesEnabled": enabled,
                    "reverseAutoSwitchEnabled": reverseOn,
                    "reverseAutoSwitchMode": reverseMode,
                    "haldexThermalProtectionEnabled": thermalOn,
                    "haldexThermalProtectionMode": thermalMode,
                    "haldexThermalProtectionThresholdC": threshold,
                ], label: "Experimental saved")
            }
        }
        .navigationTitle("Experimental")
        .onAppear {
            guard !loaded else { return }
            enabled = e["enabled"].boolValue
            reverseOn = e["reverseAutoSwitchEnabled"].boolValue
            reverseMode = e["reverseAutoSwitchMode"].string ?? "FWD"
            thermalOn = e["haldexThermalProtectionEnabled"].boolValue
            thermalMode = e["haldexThermalProtectionMode"].string ?? "STOCK"
            threshold = e["haldexThermalProtectionThresholdC"].int ?? 90
            loaded = true
        }
    }
}

struct LearnView: View {
    @EnvironmentObject var model: AppModel
    @State private var learn = JSON(nil)
    @State private var confirmClear = false

    var body: some View {
        ThemedForm {
            Section {
                ValueRow("Status", learn["active"].boolValue ? "Learning…" : (learn["tableValid"].boolValue ? "Calibrated" : "Not calibrated"))
                if learn["active"].boolValue {
                    ProgressView(value: Double(learn["progress"].intValue), total: 100)
                    ValueRow("Correction factor", "\(learn["currentCF"].intValue)")
                }
            } footer: {
                Text("Sweeps output correction from 0 to 100% and records actual Haldex engagement. Use only when Haldex CAN data is live and controller output is enabled.")
            }
            Section {
                Button("Start calibration") {
                    model.perform("Calibration started") { try await model.post("/api/learn/start") }
                }
                .disabled(learn["active"].boolValue)
                Button("Cancel calibration") {
                    model.perform("Calibration cancelled") { try await model.post("/api/learn/cancel") }
                }
                .disabled(!learn["active"].boolValue)
                Button("Clear calibration table", role: .destructive) { confirmClear = true }
            }
        }
        .navigationTitle("Calibrate")
        .task {
            while !Task.isCancelled {
                if let j = try? await model.get("/api/learn/status") { learn = j }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        .confirmationDialog("Clear the learned calibration table?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear", role: .destructive) {
                model.perform("Calibration cleared") { try await model.post("/api/learn/clear") }
            }
        }
    }
}
