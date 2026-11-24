import SwiftUI

struct MoreView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var api: BLEApi

    var body: some View {
        NavigationStack {
            ThemedList {
                NavigationLink { SignalsView() } label: { Label("Signals seen", systemImage: "checklist") }
                NavigationLink { BootsView() } label: { Label("Boot history", systemImage: "arrow.clockwise.circle") }
                NavigationLink("CAN View") { CanView() }
                NavigationLink("Logs") { LogsView() }
                NavigationLink("Wi-Fi (MMI hotspot)") { WifiView() }
                NavigationLink("RaceChrono setup") { RaceChronoSetupView() }
                ThemedSection("Connection") {
                    HStack { Text("Controller"); Spacer(); ConnectionBadge() }
                    Button("Reconnect") { api.reconnect() }
                }
                ThemedSection("About") {
                    ValueRow("Firmware", model.status["version"].stringValue)
                    ValueRow("App", (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "")
                    Text("Firmware updates are done over USB.").font(.footnote).foregroundStyle(.secondary)
                    Text("OpenHaldex-S3 © SpringfieldVW.com").font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("More")
        }
    }
}

// MARK: - CAN View

struct CanView: View {
    @EnvironmentObject var model: AppModel
    @State private var bus = "all"
    @State private var showRaw = false
    @State private var data = JSON(nil)
    @State private var live = true
    @State private var dump: String?

    var body: some View {
        ThemedList {
            Section {
                Picker("Bus", selection: $bus) {
                    Text("All").tag("all")
                    Text("Chassis").tag("chassis")
                    Text("Haldex").tag("haldex")
                }
                .pickerStyle(.segmented)
                Toggle("Live refresh", isOn: $live)
                Toggle("Show raw frames", isOn: $showRaw)
                SettingToggleCapture()
                Button("Get 30 s text dump") { getDump() }
            }
            ThemedSection("Decoded (\(data["decoded"].array.count))") {
                ForEach(data["decoded"].array.indices, id: \.self) { i in
                    let d = data["decoded"][i]
                    HStack {
                        VStack(alignment: .leading) {
                            Text(d["name"].stringValue).font(.callout)
                            Text("\(d["bus"].stringValue) \(d["dir"].stringValue) 0x\(String(d["id"].intValue, radix: 16, uppercase: true))")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("\(d["value"].display) \(d["unit"].stringValue)").monospacedDigit()
                    }
                }
            }
            if showRaw {
                ThemedSection("Raw (\(data["raw"].array.count))") {
                    ForEach(data["raw"].array.indices, id: \.self) { i in
                        let r = data["raw"][i]
                        Text(rawLine(r)).font(.caption.monospaced())
                    }
                }
            }
        }
        .navigationTitle("CAN View")
        .task(id: "\(bus)-\(showRaw)-\(live)") {
            repeat {
                if let j = try? await model.get("/api/canview",
                                                query: ["decoded": "200", "raw": showRaw ? "40" : "0", "bus": bus]) {
                    data = j
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            } while live && !Task.isCancelled
        }
        .sheet(item: Binding(get: { dump.map { DumpText(text: $0) } }, set: { dump = $0?.text })) { d in
            NavigationStack {
                ScrollView { Text(d.text).font(.caption2.monospaced()).textSelection(.enabled).padding() }
                    .toolbar { ShareLink(item: d.text) }
                    .navigationTitle("CAN dump")
            }
        }
    }

    private func rawLine(_ r: JSON) -> String {
        let id = String(r["id"].intValue, radix: 16, uppercase: true)
        let data = r["data"].string ?? r["bytes"].stringValue
        return "\(r["bus"].stringValue) \(r["dir"].stringValue) \(id) [\(r["dlc"].intValue)] \(data)"
    }

    private func getDump() {
        Task {
            do { dump = try await model.text("/api/canview/dump", query: ["seconds": "30", "bus": bus]) } catch {
                model.toast = "Dump failed: \(error.localizedDescription)"
            }
        }
    }
}

struct DumpText: Identifiable {
    let text: String
    var id: Int { text.hashValue }
}

struct SettingToggleCapture: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Toggle("Capture mode (controller to safe state)", isOn: Binding(
            get: { model.status["canviewCaptureMode"].boolValue },
            set: { on in model.perform(on ? "Capture on" : "Capture off") {
                try await model.post("/api/canview/capture", ["active": on])
            } }))
    }
}

// MARK: - Logs

struct LogsView: View {
    @EnvironmentObject var model: AppModel
    @State private var files: [JSON] = []
    @State private var confirmClear = false
    private var l: JSON { model.status["logging"] }

    var body: some View {
        ThemedList {
            ThemedSection("Logging") {
                SettingToggle(title: "Log events to file", value: l["enabled"].boolValue) { ["logToFileEnabled": $0] }
                SettingToggle(title: "Log CAN to file", value: l["canEnabled"].boolValue) { ["logCanToFileEnabled": $0] }
                SettingToggle(title: "Log errors to file", value: l["errorEnabled"].boolValue) { ["logErrorToFileEnabled": $0] }
                SettingToggle(title: "Serial logging", value: l["serialEnabled"].boolValue) { ["logSerialEnabled": $0] }
                SettingToggle(title: "Debug: firmware", value: l["debugFirmwareEnabled"].boolValue) { ["logDebugFirmwareEnabled": $0] }
                SettingToggle(title: "Debug: network", value: l["debugNetworkEnabled"].boolValue) { ["logDebugNetworkEnabled": $0] }
                SettingToggle(title: "Debug: CAN", value: l["debugCanEnabled"].boolValue) { ["logDebugCanEnabled": $0] }
            }
            ThemedSection("Log files") {
                ForEach(files.indices, id: \.self) { i in
                    let path = files[i]["path"].stringValue
                    NavigationLink {
                        LogFileView(path: path)
                    } label: {
                        HStack {
                            Text((path as NSString).lastPathComponent)
                            Spacer()
                            Text(ByteCountFormatter.string(fromByteCount: Int64(files[i]["size"].intValue), countStyle: .file))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .swipeActions {
                        Button("Delete", role: .destructive) {
                            model.perform("Deleted") {
                                try await model.post("/api/logs/delete", ["path": path])
                                await load()
                            }
                        }
                    }
                }
                Button("Clear all logs", role: .destructive) { confirmClear = true }
            }
        }
        .navigationTitle("Logs")
        .task { await load() }
        .refreshable { await load() }
        .confirmationDialog("Delete all log files?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear everything", role: .destructive) {
                model.perform("Logs cleared") {
                    try await model.post("/api/logs/clear", ["scope": "everything"])
                    await load()
                }
            }
        }
    }

    private func load() async {
        if let j = try? await model.get("/api/logs") { files = j["files"].array }
    }
}

struct LogFileView: View {
    @EnvironmentObject var model: AppModel
    let path: String
    @State private var text = ""

    var body: some View {
        ScrollView {
            Text(text.isEmpty ? "Loading…" : text)
                .font(.caption2.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .navigationTitle((path as NSString).lastPathComponent)
        .toolbar { if !text.isEmpty { ShareLink(item: text) } }
        .task {
            do { text = try await model.text("/api/logs/read", query: ["path": path, "max": "65536"]) } catch {
                text = "Read failed: \(error.localizedDescription)"
            }
        }
    }
}

// MARK: - Wi-Fi

struct WifiView: View {
    @EnvironmentObject var model: AppModel
    @State private var ssid = ""
    @State private var password = ""
    @State private var staEnabled = true
    @State private var mmiTarget = ""
    @State private var net = JSON(nil)

    var body: some View {
        ThemedForm {
            Section {
                Toggle("Join hotspot", isOn: $staEnabled)
                TextField("Hotspot name (SSID)", text: $ssid)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField("Password (leave blank to keep)", text: $password)
                Button("Save") {
                    var body: [String: Any] = ["ssid": ssid, "staEnabled": staEnabled]
                    if !password.isEmpty { body["password"] = password }
                    model.perform("Wi-Fi saved") { try await model.post("/api/wifi", body) }
                    password = ""
                }
            } footer: {
                Text("The controller joins the MMI's hotspot to feed the custom gauges.")
            }
            ThemedSection("Hotspot") {
                ValueRow("Joined", net["staConnected"].boolValue ? net["staSsid"].stringValue : "no")
                if net["staConnected"].boolValue {
                    ValueRow("Signal", "\(net["staRssi"].intValue) dBm")
                    ValueRow("IP", net["staIp"].stringValue)
                }
            }
            Section {
                let m = net["mmi"]
                ValueRow("Link", m["linked"].boolValue ? "up" : (net["staConnected"].boolValue ? "probing…" : "down"))
                ValueRow("Head unit", m["gateway"].stringValue.isEmpty ? "—"
                         : m["gateway"].stringValue + (m["port"].intValue > 0 ? ":\(m["port"].intValue)" : ""))
                ValueRow("Sent / acked", "\(m["sent"].intValue) / \(m["acks"].intValue)")
                ValueRow("Round trip", "\(m["rttMs"].intValue) ms (max \(m["rttMaxMs"].intValue))")
                ValueRow("Head unit received / lost", "\(m["huRx"].intValue) / \(m["huLost"].intValue)")
            } header: {
                SectionTitle("MMI gauge link")
            } footer: {
                Text("UDP to the hotspot gateway. Until the head unit answers, probes step through ports 49153–49162 (shared with wireless CarPlay); then 20 Hz on the port that answered.")
            }
            Section {
                TextField("Send to (blank = hotspot gateway)", text: $mmiTarget)
                    .keyboardType(.decimalPad).autocorrectionDisabled()
                Button("Save bench target") {
                    model.perform(mmiTarget.isEmpty ? "Target cleared" : "Target set") {
                        try await model.post("/api/wifi", ["mmiTarget": mmiTarget])
                    }
                }
            } header: {
                SectionTitle("Bench test")
            } footer: {
                Text("Only for testing without the car: send the gauge data to this IP (e.g. a Mac on the same hotspot) instead of the hotspot's gateway. Leave blank in the car.")
            }
        }
        .navigationTitle("Wi-Fi")
        .task {
            while !Task.isCancelled {
                if let j = try? await model.get("/api/network") { net = j }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
        .task {
            if let j = try? await model.get("/api/wifi") {
                ssid = j["ssid"].stringValue
                staEnabled = j["staEnabled"].bool ?? true
                mmiTarget = j["mmiTarget"].stringValue
            }
        }
    }
}
