import SwiftUI

/// Why the board restarted, for the last boots (firmware /api/boots).
/// "Before" values come from a breadcrumb that survives a crash reset but not
/// a power cut, so a power-on entry has none.
struct BootsView: View {
    @EnvironmentObject var model: AppModel
    @State private var data = JSON(nil)
    @State private var error: String?

    var body: some View {
        ThemedList {
            Section {
                ValueRow("Boots since flash", "\(data["bootCount"].intValue)")
                ValueRow("Up for", duration(data["uptimeS"].intValue))
                if let error { Text(error).font(.footnote).foregroundStyle(Theme.pink) }
            }
            ThemedSection("Last boots, newest first") {
                ForEach(data["boots"].array.indices, id: \.self) { i in row(data["boots"][i], current: i == 0) }
            }
            Section {
                Text("Brownout = the supply dipped (often the starter cranking). Panic / watchdog = a firmware crash. Power-on = power was cut and restored, which is normal with the ignition.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Boot history")
        .refreshable { await load() }
        .task { await load() }
    }

    private func load() async {
        do {
            data = try await model.get("/api/boots")
            error = nil
        } catch {
            self.error = "Couldn't read /api/boots (firmware v1.1.20 or newer needed)."
        }
    }

    private func row(_ b: JSON, current: Bool) -> some View {
        let crash = b["crash"].boolValue
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: crash ? "exclamationmark.triangle.fill" : "power")
                    .foregroundStyle(crash ? Theme.pink : Theme.cyan)
                Text(b["reason"].stringValue.capitalized).font(.callout.bold())
                Spacer()
                Text(current ? "this boot" : "#\(b["boot"].intValue)")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            if !b["prevUptimeS"].isNull {
                Text(before(b)).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func before(_ b: JSON) -> String {
        var parts = ["previous boot ran \(duration(b["prevUptimeS"].intValue))",
                     "heap low \(b["prevMinHeap"].intValue / 1024) KB"]
        var on: [String] = []
        if b["prevChassis"].boolValue { on.append("chassis CAN") }
        if b["prevHaldex"].boolValue { on.append("Haldex CAN") }
        if b["prevWifi"].boolValue { on.append("Wi-Fi") }
        if b["prevMmi"].boolValue { on.append("MMI link") }
        parts.append(on.isEmpty ? "nothing active" : on.joined(separator: ", "))
        return parts.joined(separator: " · ")
    }

    private func duration(_ s: Int) -> String {
        if s < 120 { return "\(s) s" }
        if s < 7200 { return "\(s / 60) min" }
        return "\(s / 3600) h \(s % 3600 / 60) min"
    }
}
