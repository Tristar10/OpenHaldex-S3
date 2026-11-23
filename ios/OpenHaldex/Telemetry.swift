import Foundation

/// OpenHaldex modes as reported by `openhaldexEffectiveMode()` in firmware
/// (byte 7 of the 0xFFFF0001 decoded telemetry packet).
enum HaldexMode: Int, CaseIterable, Identifiable {
    // Must match `openhaldex_mode_t` in include/functions/core/state.h.
    case stock = 0
    case fwd = 1
    case m5050 = 2
    case m6040 = 3
    case m7030 = 4
    case m8020 = 5
    case m9010 = 6
    case speed = 7
    case throttle = 8
    case map = 9
    case rpm = 10

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .stock: "STOCK"
        case .fwd: "FWD"
        case .m5050: "50:50"
        case .m6040: "60:40"
        case .m7030: "70:30"
        case .m8020: "80:20"
        case .m9010: "90:10"
        case .speed: "SPEED"
        case .throttle: "THROTTLE"
        case .map: "MAP"
        case .rpm: "RPM"
        }
    }

    static func label(for raw: Int) -> String {
        HaldexMode(rawValue: raw)?.label ?? "MODE \(raw)"
    }
}

/// One decoded OpenHaldex telemetry sample.
struct Telemetry: Equatable {
    var speedKmh: Double = 0
    var rpm: Int = 0
    var pedalPercent: Double = 0
    var lockTarget: Int = 0
    var lockActual: Int = 0
    var mode: Int = 0
    var receivedAt: Date = .distantPast

    /// Decodes the 8-byte payload of PID 0xFFFF0001 (see
    /// `queueDecodedTelemetry()` in racechrono_ble.cpp). Multi-byte fields
    /// are big-endian.
    static func decode(payload: Data) -> Telemetry? {
        guard payload.count >= 8 else { return nil }
        let b = [UInt8](payload.prefix(8))
        var t = Telemetry()
        t.speedKmh = Double(UInt16(b[0]) << 8 | UInt16(b[1])) / 100.0
        t.rpm = Int(UInt16(b[2]) << 8 | UInt16(b[3]))
        t.pedalPercent = Double(b[4]) / 2.55
        t.lockTarget = Int(b[5])
        t.lockActual = Int(b[6])
        t.mode = Int(b[7])
        t.receivedAt = Date()
        return t
    }
}

/// RaceChrono DIY BLE wire format: 4-byte little-endian PID, then up to 8
/// data bytes.
enum RaceChronoFrame {
    static let openHaldexPid: UInt32 = 0xFFFF_0001

    static func parse(_ data: Data) -> (pid: UInt32, payload: Data)? {
        guard data.count >= 4 else { return nil }
        let b = [UInt8](data)
        let pid = UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24
        return (pid, data.subdata(in: 4..<data.count))
    }

    /// Filter command 2: allow one PID at `intervalMs`.
    static func allowPid(_ pid: UInt32, intervalMs: UInt16) -> Data {
        Data([2, UInt8(intervalMs >> 8), UInt8(intervalMs & 0xFF),
              UInt8(pid >> 24 & 0xFF), UInt8(pid >> 16 & 0xFF),
              UInt8(pid >> 8 & 0xFF), UInt8(pid & 0xFF)])
    }

    /// Filter command 0: deny all.
    static let denyAll = Data([0])
}
