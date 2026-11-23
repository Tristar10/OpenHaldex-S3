import SwiftUI
import UIKit

/// Copy-paste reference for setting up RaceChrono's CAN-Bus channels on the
/// OpenHaldex-RC BLE device (mirrors docs/RACECHRONO_BLE.md).
struct RaceChronoSetupView: View {
    struct Channel: Identifiable {
        let name: String
        let unit: String
        let equation: String
        var id: String { name }
    }

    struct Packet: Identifiable {
        let pid: UInt32
        let title: String
        let channels: [Channel]
        var id: UInt32 { pid }
        var hex: String { String(format: "0x%08X", pid) }
        var decimal: String { String(pid) }
    }

    private let packets: [Packet] = [
        Packet(pid: 0xFFFF_0001, title: "Haldex & engine", channels: [
            Channel(name: "Haldex mode", unit: "number", equation: "H"),
            Channel(name: "Haldex lock requested", unit: "%", equation: "F"),
            Channel(name: "Haldex lock actual", unit: "%", equation: "G"),
            Channel(name: "Vehicle speed", unit: "km/h", equation: "bytesToUint(raw, 0, 2) / 100.0"),
            Channel(name: "Engine speed", unit: "rpm", equation: "bytesToUint(raw, 2, 2)"),
            Channel(name: "Accelerator", unit: "%", equation: "E * 100.0 / 255.0"),
        ]),
        Packet(pid: 0xFFFF_0002, title: "Chassis", channels: [
            Channel(name: "Steering angle (right +)", unit: "deg", equation: "bytesToInt(raw, 0, 2) / 10.0"),
            Channel(name: "Brake pressure", unit: "bar", equation: "bytesToInt(raw, 2, 2) / 10.0"),
            Channel(name: "Haldex clutch temp", unit: "°C", equation: "bytesToInt(raw, 4, 2)"),
            Channel(name: "Gear", unit: "number", equation: "G"),
            Channel(name: "ABS active", unit: "0/1", equation: "bitsToUint(raw, 56, 1)"),
            Channel(name: "ESP active", unit: "0/1", equation: "bitsToUint(raw, 57, 1)"),
            Channel(name: "EDS active", unit: "0/1", equation: "bitsToUint(raw, 58, 1)"),
            Channel(name: "Reverse", unit: "0/1", equation: "bitsToUint(raw, 59, 1)"),
        ]),
        Packet(pid: 0xFFFF_0003, title: "Wheel speeds", channels: [
            Channel(name: "Wheel speed FL", unit: "km/h", equation: "bytesToUint(raw, 0, 2) / 100.0"),
            Channel(name: "Wheel speed FR", unit: "km/h", equation: "bytesToUint(raw, 2, 2) / 100.0"),
            Channel(name: "Wheel speed RL", unit: "km/h", equation: "bytesToUint(raw, 4, 2) / 100.0"),
            Channel(name: "Wheel speed RR", unit: "km/h", equation: "bytesToUint(raw, 6, 2) / 100.0"),
        ]),
        Packet(pid: 0xFFFF_0004, title: "Engine", channels: [
            Channel(name: "Coolant temp", unit: "°C", equation: "A - 40"),
            Channel(name: "Oil temp", unit: "°C", equation: "B - 40"),
            Channel(name: "Intake air temp", unit: "°C", equation: "C - 40"),
            Channel(name: "Gearbox temp", unit: "°C", equation: "D - 40"),
            Channel(name: "Boost", unit: "bar", equation: "E * 0.02"),
            Channel(name: "Oil pressure", unit: "bar", equation: "F / 10.0"),
            Channel(name: "Gearbox input torque (DSG)", unit: "Nm", equation: "bytesToInt(raw, 6, 2)"),
        ]),
    ]

    @State private var copied: String?

    var body: some View {
        List {
            Section {
                Text("In RaceChrono: Settings → OpenHaldex-RC → CAN-Bus channels → Add. Enter the PID, pick the closest channel type, and paste the equation. Needs RaceChrono Pro.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(packets) { packet in
                Section {
                    copyRow("PID (hex)", packet.hex)
                    copyRow("PID (decimal)", packet.decimal)
                    ForEach(packet.channels) { ch in
                        Button { copy(ch.equation) } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(ch.name).foregroundStyle(.primary)
                                    Spacer()
                                    Text(ch.unit).font(.caption).foregroundStyle(.secondary)
                                }
                                HStack {
                                    Text(ch.equation).font(.caption.monospaced()).foregroundStyle(.orange)
                                    Spacer()
                                    Image(systemName: copied == ch.equation ? "checkmark" : "doc.on.doc")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                } header: {
                    Text(packet.title)
                }
            }
            Section("Mode numbers") {
                Text("0 Off · 1 FWD · 2 50:50 · 3 60:40 · 4 70:30 · 5 80:20 · 6 90:10 · 7 Speed · 8 Throttle · 9 Map · 10 RPM")
                    .font(.footnote)
            }
        }
        .navigationTitle("RaceChrono setup")
    }

    private func copyRow(_ label: String, _ value: String) -> some View {
        Button { copy(value) } label: {
            HStack {
                Text(label).foregroundStyle(.primary)
                Spacer()
                Text(value).font(.callout.monospaced()).foregroundStyle(.secondary)
                Image(systemName: copied == value ? "checkmark" : "doc.on.doc").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func copy(_ s: String) {
        UIPasteboard.general.string = s
        copied = s
    }
}
