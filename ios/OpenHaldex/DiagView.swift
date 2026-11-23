import SwiftUI

/// Web UI Diagnostics page: controller/CAN/power/flags status plus Haldex UDS
/// (fault codes, identity, Gen 5 measured values).
struct DiagView: View {
    @EnvironmentObject var model: AppModel
    private var s: JSON { model.status }

    var body: some View {
        NavigationStack {
            List {
                Section("Control") {
                    ValueRow("Mode", modeLabel(s["mode"].stringValue))
                    ValueRow("Effective mode", modeLabel(s["effectiveMode"].stringValue))
                    ValueRow("Controller", s["disableController"].boolValue ? "disabled" : "enabled")
                    ValueRow("Standalone", s["isStandalone"].boolValue ? "yes" : "no")
                    ValueRow("Broadcast over CAN", s["effectiveBroadcastOpenHaldexOverCAN"].boolValue ? "on" : "off")
                }
                Section("Specified vs actual") {
                    ValueRow("Lock specified", "\(s["telemetry"]["spec"].intValue)%")
                    ValueRow("Lock actual", "\(s["telemetry"]["act"].intValue)%")
                    ValueRow("Haldex state", s["telemetry"]["haldexState"].display)
                    ValueRow("Engagement raw", s["telemetry"]["haldexEngagementRaw"].display)
                    ValueRow("Clutch 1 report", s["telemetry"]["clutch1Report"].display)
                    ValueRow("Clutch 2 report", s["telemetry"]["clutch2Report"].display)
                }
                Section("CAN") {
                    ValueRow("Ready", s["can"]["ready"].display)
                    ValueRow("Chassis bus", s["can"]["chassis"].display)
                    ValueRow("Haldex bus", s["can"]["haldex"].display)
                    ValueRow("Bus failure", s["can"]["busFailure"].display)
                    ValueRow("Last chassis frame", "\(s["can"]["lastChassisMs"].intValue) ms ago")
                    ValueRow("Last Haldex frame", "\(s["can"]["lastHaldexMs"].intValue) ms ago")
                }
                Section("Flags") {
                    ValueRow("Temp protection", s["telemetry"]["tempProtection"].display)
                    ValueRow("Coupling open", s["telemetry"]["couplingOpen"].display)
                    ValueRow("Speed limit", s["telemetry"]["speedLimit"].display)
                    ValueRow("Inputs mapped", s["telemetry"]["inputsMapped"].display)
                }
                Section("Haldex (UDS)") {
                    NavigationLink("Fault codes") { DtcView() }
                    NavigationLink("Identification") { IdentityView() }
                    if s["haldexGeneration"].intValue == 5 {
                        NavigationLink("Measured values (Gen 5)") { MeasuredView() }
                    }
                }
                Section("Power") {
                    ForEach(s["power"].keys, id: \.self) { k in ValueRow(k, s["power"][k].display) }
                }
                Section("System") {
                    ValueRow("Firmware", s["version"].stringValue)
                    ValueRow("Uptime", uptime)
                    NavigationLink("All status fields") { RawJSONView(title: "Status", json: s) }
                }
                if let e = model.lastError { Section { Text(e).foregroundStyle(.red).font(.footnote) } }
            }
            .navigationTitle("Diagnostics")
            .refreshable { await model.refreshStatus() }
        }
    }

    private var uptime: String {
        let sec = s["uptimeMs"].intValue / 1000
        return String(format: "%dh %02dm %02ds", sec / 3600, sec / 60 % 60, sec % 60)
    }
}

struct RawJSONView: View {
    let title: String
    let json: JSON

    var body: some View {
        List {
            ForEach(json.keys, id: \.self) { k in
                let v = json[k]
                if !v.keys.isEmpty {
                    NavigationLink(k) { RawJSONView(title: k, json: v) }
                } else if !v.array.isEmpty {
                    NavigationLink("\(k) [\(v.array.count)]") {
                        RawJSONView(title: k, json: JSON(Dictionary(uniqueKeysWithValues:
                            v.array.enumerated().map { (String(format: "%03d", $0.offset), $0.element.raw ?? NSNull()) })))
                    }
                } else {
                    ValueRow(k, v.display)
                }
            }
        }
        .navigationTitle(title)
    }
}

struct DtcView: View {
    @EnvironmentObject var model: AppModel
    @State private var result = JSON(nil)
    @State private var busy = false
    @State private var confirmClear = false

    var body: some View {
        List {
            Section {
                Button(busy ? "Reading…" : "Read fault codes") { read() }.disabled(busy)
                Button("Clear fault codes", role: .destructive) { confirmClear = true }.disabled(busy)
            }
            if !result.isNull {
                let dtc = result["dtc"]
                Section("\(dtc["dtcCount"].intValue) fault code(s)") {
                    ForEach(dtc["records"].array.indices, id: \.self) { i in
                        let r = dtc["records"][i]
                        VStack(alignment: .leading, spacing: 2) {
                            Text(r["rawDtcSpaced"].stringValue).font(.body.monospaced())
                            Text(r["odisFaultType"].stringValue).font(.caption)
                            Text(r["statusLabels"].array.map(\.stringValue).joined(separator: ", "))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    if !result["ok"].boolValue {
                        Text(result["result"]["message"].string ?? "No response").foregroundStyle(.red)
                    }
                }
            }
        }
        .navigationTitle("Fault codes")
        .confirmationDialog("Clear Haldex fault codes?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear", role: .destructive) {
                model.perform("Fault codes cleared") { try await model.post("/api/uds/clear-dtc", timeout: 30) }
            }
        }
    }

    private func read() {
        busy = true
        Task {
            defer { busy = false }
            do { result = try await model.post("/api/uds/dtc", timeout: 30) } catch {
                model.toast = "Read failed: \(error.localizedDescription)"
            }
        }
    }
}

struct IdentityView: View {
    @EnvironmentObject var model: AppModel
    @State private var result = JSON(nil)
    @State private var busy = false

    var body: some View {
        List {
            Button(busy ? "Reading…" : "Read identification") {
                busy = true
                Task {
                    defer { busy = false }
                    do { result = try await model.post("/api/uds/identity", timeout: 45) } catch {
                        model.toast = "Read failed: \(error.localizedDescription)"
                    }
                }
            }
            .disabled(busy)
            ForEach(result["records"].array.indices, id: \.self) { i in
                let r = result["records"][i]
                VStack(alignment: .leading) {
                    Text(r["label"].stringValue).font(.caption).foregroundStyle(.secondary)
                    Text(r["ok"].boolValue ? r["value"].stringValue : (r["nrcName"].string ?? r["message"].string ?? "—"))
                        .textSelection(.enabled)
                }
            }
        }
        .navigationTitle("Identification")
    }
}

/// Gen 5 measured values using the same catalog the web UI ships
/// (openhaldex-gen5-mwb-compact.json, bundled as gen5-mwb.json).
struct MeasuredView: View {
    @EnvironmentObject var model: AppModel
    @State private var rows: [(String, String)] = []
    @State private var busy = false

    private static let manifest: JSON = {
        guard let url = Bundle.main.url(forResource: "gen5-mwb", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return JSON(nil) }
        return JSON(data: data)
    }()

    var body: some View {
        List {
            Button(busy ? "Reading…" : "Read measured values") { run() }.disabled(busy)
            ForEach(rows.indices, id: \.self) { i in ValueRow(rows[i].0, rows[i].1) }
        }
        .navigationTitle("Measured values")
    }

    private func run() {
        let records = Self.manifest["records"].array
        var seen = Set<String>()
        let dids = records.compactMap { r -> String? in
            let d = r["didHex"].stringValue.replacingOccurrences(of: "0x", with: "").uppercased()
            return seen.insert(d).inserted ? d : nil
        }
        busy = true
        Task {
            defer { busy = false }
            do {
                let resp = try await model.post("/api/diag/measured", query: ["dids": dids.joined(separator: ",")],
                                                timeout: 60)
                var raw: [String: [UInt8]] = [:]
                for item in resp["items"].array where item["ok"].boolValue {
                    let did = (item["did"].string ?? item["id"].stringValue).replacingOccurrences(of: "0x", with: "").uppercased()
                    raw[did] = item["rawDataHex"].stringValue.split(separator: " ").compactMap { UInt8($0, radix: 16) }
                }
                rows = records.map { r in
                    let did = r["didHex"].stringValue.replacingOccurrences(of: "0x", with: "").uppercased()
                    return (r["label"].stringValue, decode(r, raw[did]))
                }
            } catch {
                model.toast = "Read failed: \(error.localizedDescription)"
            }
        }
    }

    private func decode(_ r: JSON, _ bytes: [UInt8]?) -> String {
        guard let bytes else { return "no response" }
        let off = r["offset"].intValue, len = max(1, r["length"].intValue)
        guard off + len <= bytes.count else { return "short response" }
        var x: UInt64 = 0
        for b in bytes[off..<(off + len)] { x = (x << 8) | UInt64(b) }
        let bitLen = r["bitLength"].int ?? len * 8
        x = (x >> UInt64(r["bitPosition"].intValue)) & (bitLen >= 64 ? .max : (1 << UInt64(bitLen)) - 1)
        var v = Double(x)
        if r["signed"].boolValue, bitLen < 64, x & (1 << UInt64(bitLen - 1)) != 0 {
            v -= Double(UInt64(1) << UInt64(bitLen))
        }
        for range in r["validity"].array where range["validity"].stringValue != "VALID" {
            if v >= range["lower"].doubleValue && v <= range["upper"].doubleValue {
                return range["label"].string ?? range["validity"].stringValue
            }
        }
        let value = r["add"].doubleValue + v * (r["scale"].double ?? 1)
        return String(format: "%.\(r["precision"].intValue)f %@", value, r["unit"].stringValue)
    }
}
