import Foundation
import SwiftUI

/// Shared state: the link plus the latest `/api/status`, polled once a second
/// while connected (the web UI's home page does the same).
@MainActor
final class AppModel: ObservableObject {
    let api = BLEApi()
    @Published private(set) var status = JSON(nil)
    @Published private(set) var lastError: String?
    @Published var toast: String?
    private var pollTask: Task<Void, Never>?

    init() {
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshStatus()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    var connected: Bool { api.state == .ready || Mock.enabled }

    func refreshStatus() async {
        guard connected else { return }
        do {
            status = try await get("/api/status")
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    // Thin wrappers so the simulator can run against canned data.
    func get(_ path: String, query: [String: String] = [:]) async throws -> JSON {
        if Mock.enabled { return Mock.response(path) }
        return try await api.get(path, query: query)
    }

    @discardableResult
    func post(_ path: String, _ body: Any? = nil, query: [String: String] = [:],
              timeout: TimeInterval = 20) async throws -> JSON {
        if Mock.enabled { return JSON(["ok": true]) }
        return try await api.call("POST", path, query: query, body: body, timeout: timeout)
    }

    func text(_ path: String, query: [String: String] = [:]) async throws -> String {
        if Mock.enabled { return "mock log line 1\nmock log line 2\n" }
        return try await api.text(path, query: query)
    }

    /// Runs a write and reports the outcome as a toast; refreshes status after.
    func perform(_ label: String, _ work: @escaping () async throws -> Void) {
        Task {
            do {
                try await work()
                toast = "\(label) ✓"
                await refreshStatus()
            } catch {
                toast = "\(label) failed: \(error.localizedDescription)"
            }
        }
    }

    func setSettings(_ patch: [String: Any], label: String = "Saved") {
        perform(label) { try await self.post("/api/settings", patch) }
    }

    func setMode(_ mode: String) {
        perform("Mode \(mode)") { try await self.post("/api/mode", ["mode": mode]) }
    }
}

/// Canned responses for running the UI in the iOS Simulator (no Bluetooth).
enum Mock {
    static var enabled: Bool {
        #if targetEnvironment(simulator)
        return true
        #else
        return false
        #endif
    }

    static func response(_ path: String) -> JSON {
        switch path {
        case "/api/status":
            return JSON([
                "version": "v1.1.4", "mode": "7030", "effectiveMode": "7030", "haldexGeneration": 5,
                "disableController": false, "isStandalone": false, "broadcastOpenHaldexOverCAN": true,
                "disableThrottle": false, "disableSpeed": false, "lockReleaseRatePctPerSec": 50,
                "uptimeMs": 123456, "canviewCaptureMode": false,
                "can": ["ready": true, "chassis": true, "haldex": true, "busFailure": false,
                        "lastChassisMs": 4, "lastHaldexMs": 9],
                "telemetry": ["speed": 42, "rpm": 3100, "throttle": 18.5, "spec": 40, "act": 37,
                              "haldexState": 0, "tempProtection": false, "couplingOpen": false,
                              "speedLimit": false, "inputsMapped": true],
                "experimental": ["enabled": true, "reverseAutoSwitchEnabled": true,
                                 "reverseAutoSwitchMode": "FWD", "haldexThermalProtectionEnabled": true,
                                 "haldexThermalProtectionThresholdC": 90, "haldexThermalProtectionMode": "STOCK",
                                 "haldexClutchTempC": 48, "haldexClutchTempValid": true],
                "logging": ["masterEnabled": true, "enabled": true, "canEnabled": false, "errorEnabled": true,
                            "serialEnabled": true, "debugFirmwareEnabled": false, "debugNetworkEnabled": false,
                            "debugCanEnabled": false],
                "learn": ["active": false, "tableValid": true, "progress": 0, "currentCF": 0],
                "modeTrigger": ["enabled": false, "signal": "", "operator": "EQ", "value": 1, "mode": "5050"],
                "disengageUnderSpeed": ["map": 0, "speed": 0, "throttle": 0, "rpm": 0],
                "power": ["lowPower": false, "sleepEnabled": false],
            ])
        case "/api/curve/speed", "/api/curve/throttle", "/api/curve/rpm":
            return JSON(["count": 4, "points": [["x": 0, "lock": 80], ["x": 40, "lock": 60],
                                                  ["x": 100, "lock": 30], ["x": 160, "lock": 10]]])
        case "/api/map":
            return JSON(["speedBins": [0, 20, 40, 60, 80, 100, 140, 180],
                         "throttleBins": [0, 10, 20, 40, 60, 80, 100],
                         "lockTable": (0..<7).map { t in (0..<8).map { s in max(0, 20 + t * 12 - s * 4) } }])
        case "/api/maps":
            return JSON(["current": "/maps/aggressive.txt", "maps": [["path": "/maps/aggressive.txt", "name": "aggressive"]]])
        case "/api/logs":
            return JSON(["files": [["path": "/logs/sys.log", "size": 2048]]])
        case "/api/wifi":
            return JSON(["ssid": "MMI-Hotspot", "staEnabled": true, "apPasswordSet": false])
        case "/api/learn/status":
            return JSON(["active": false, "progress": 0, "tableValid": true, "currentCF": 0])
        default:
            return JSON([:])
        }
    }
}
