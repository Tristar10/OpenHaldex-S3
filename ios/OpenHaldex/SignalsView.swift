import SwiftUI

/// One-glance check of which signal-carrying CAN frames the board is
/// receiving. Green = seen in the last 2 s, amber = seen earlier, red = never.
struct SignalsView: View {
    @EnvironmentObject var model: AppModel
    @State private var data = JSON(nil)
    @State private var error: String?

    private var frames: [JSON] { data["frames"].array }
    private var seenCount: Int { frames.filter { state($0) == .live }.count }

    enum SeenState { case live, stale, never }

    var body: some View {
        ThemedList {
            Section {
                HStack(spacing: 14) {
                    summary("\(seenCount)", "LIVE", Theme.cyan)
                    summary("\(frames.filter { state($0) == .stale }.count)", "STALE", .orange)
                    summary("\(frames.filter { state($0) == .never }.count)", "MISSING", Theme.pink)
                }
                .frame(maxWidth: .infinity)
                if let error {
                    Text(error).font(.footnote).foregroundStyle(Theme.pink)
                } else if data["generation"].intValue != 5 && !frames.isEmpty {
                    Text("Haldex generation is not 5: these MQB frames are only decoded on Gen 5.")
                        .font(.footnote).foregroundStyle(.orange)
                }
            }
            ThemedSection("Chassis bus") {
                ForEach(rows("chassis"), id: \.self) { i in row(frames[i]) }
            }
            ThemedSection("Haldex bus") {
                ForEach(rows("haldex"), id: \.self) { i in row(frames[i]) }
                HStack {
                    icon(data["uds"]["clutchTempValid"].boolValue ? .live : .never)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Haldex clutch temp").font(.callout)
                        Text("UDS poll, not a broadcast frame").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Section {
                Text("Red means the frame never reached this board since boot, so its signals can't be shown here or sent to RaceChrono. Those need a board on a bus that carries them.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Signals seen")
        .task {
            repeat {
                do {
                    data = try await model.get("/api/signals")
                    error = nil
                } catch {
                    self.error = "Couldn't read /api/signals (firmware v1.1.17 or newer needed)."
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            } while !Task.isCancelled
        }
    }

    private func rows(_ bus: String) -> [Int] {
        frames.indices.filter { frames[$0]["bus"].stringValue == bus }
    }

    private func state(_ f: JSON) -> SeenState {
        guard !f["ageMs"].isNull else { return .never }
        return f["ageMs"].intValue <= 2000 ? .live : .stale
    }

    private func row(_ f: JSON) -> some View {
        let st = state(f)
        return HStack(alignment: .top) {
            icon(st)
            VStack(alignment: .leading, spacing: 2) {
                Text(f["signals"].stringValue).font(.callout)
                Text("\(f["frame"].stringValue) · 0x\(String(f["id"].intValue, radix: 16, uppercase: true))")
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            Spacer()
            Text(ageText(f, st)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
    }

    private func ageText(_ f: JSON, _ st: SeenState) -> String {
        switch st {
        case .never: return "never"
        case .live: return "\(f["frames"].intValue) rx"
        case .stale:
            let s = f["ageMs"].intValue / 1000
            return s < 120 ? "\(s) s ago" : "\(s / 60) min ago"
        }
    }

    private func icon(_ st: SeenState) -> some View {
        let (name, color): (String, Color) = switch st {
        case .live: ("checkmark.circle.fill", Theme.cyan)
        case .stale: ("clock.badge.exclamationmark", .orange)
        case .never: ("xmark.circle.fill", Theme.pink)
        }
        return Image(systemName: name).foregroundStyle(color).font(.body)
    }

    private func summary(_ value: String, _ label: String, _ color: Color) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.title2.monospacedDigit().bold()).foregroundStyle(color)
            Text(label).font(.caption2.bold()).tracking(1).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}
