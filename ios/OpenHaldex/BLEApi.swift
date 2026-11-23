import CoreBluetooth
import Foundation

/// Talks to the OpenHaldex controller's JSON API over BLE. Every web UI
/// endpoint (`/api/status`, `/api/mode`, `/api/settings`, …) is reachable here
/// with the same request and response bodies. See
/// include/functions/net/ble_api.h in the firmware for the wire format.
@MainActor
final class BLEApi: NSObject, ObservableObject {
    enum LinkState: Equatable {
        case bluetoothOff, unauthorized, scanning, connecting, ready
    }

    struct ApiError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    nonisolated static let advertisedService = CBUUID(string: "1FF8")
    nonisolated static let apiService = CBUUID(string: "4f480001-0000-4c44-8000-4f70656e4844")
    nonisolated static let rxChar = CBUUID(string: "4f480002-0000-4c44-8000-4f70656e4844")
    nonisolated static let txChar = CBUUID(string: "4f480003-0000-4c44-8000-4f70656e4844")

    @Published private(set) var state: LinkState = .bluetoothOff
    @Published private(set) var deviceName: String = ""

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var rx: CBCharacteristic?
    private var rxBuffer = Data()
    private var nextId = 1
    private var pending: [Int: CheckedContinuation<(Int, Data), Error>] = [:]
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    // MARK: Public API

    /// Performs one request. `body` is JSON-encoded (dictionary/array) or sent
    /// as-is when it is a String. Returns parsed JSON, or plain text wrapped in
    /// JSON for text endpoints (logs, dumps).
    @discardableResult
    func call(_ method: String, _ path: String, query: [String: String] = [:], body: Any? = nil,
              timeout: TimeInterval = 20) async throws -> JSON {
        let (code, data) = try await raw(method, path, query: query, body: body, timeout: timeout)
        let json = JSON(data: data)
        guard (200..<300).contains(code) else {
            let msg = json["error"].string ?? String(data: data, encoding: .utf8) ?? ""
            throw ApiError(message: "HTTP \(code) \(msg)")
        }
        return json
    }

    func get(_ path: String, query: [String: String] = [:]) async throws -> JSON {
        try await call("GET", path, query: query)
    }

    func post(_ path: String, _ body: Any? = nil, timeout: TimeInterval = 20) async throws -> JSON {
        try await call("POST", path, body: body, timeout: timeout)
    }

    func text(_ path: String, query: [String: String] = [:]) async throws -> String {
        let (code, data) = try await raw("GET", path, query: query, body: nil, timeout: 30)
        let s = String(data: data, encoding: .utf8) ?? ""
        guard (200..<300).contains(code) else { throw ApiError(message: "HTTP \(code) \(s)") }
        return s
    }

    func reconnect() {
        if let p = peripheral { central.cancelPeripheralConnection(p) }
        peripheral = nil
        rx = nil
        startScan()
    }

    // MARK: Request plumbing

    private func raw(_ method: String, _ path: String, query: [String: String], body: Any?,
                     timeout: TimeInterval) async throws -> (Int, Data) {
        // The firmware handles one request at a time; keep ours in order too.
        await acquire()
        defer { release() }

        guard state == .ready, let p = peripheral, let rx else {
            throw ApiError(message: "Not connected")
        }

        var target = path
        if !query.isEmpty {
            var c = URLComponents()
            c.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
            target += "?" + (c.percentEncodedQuery ?? "")
        }
        var bodyData = Data()
        if let s = body as? String {
            bodyData = Data(s.utf8)
        } else if let body {
            bodyData = try JSONSerialization.data(withJSONObject: body)
        }

        let id = nextId
        nextId += 1
        var message = Data("\(id) \(method) \(target)\n".utf8)
        message.append(bodyData)

        let chunk = max(1, min(p.maximumWriteValueLength(for: .withResponse), 512) - 1)
        var packets: [Data] = []
        var offset = 0
        repeat {
            let end = min(offset + chunk, message.count)
            var flags: UInt8 = offset == 0 ? 0x01 : 0
            if end >= message.count { flags |= 0x02 }
            var packet = Data([flags])
            packet.append(message.subdata(in: offset..<end))
            packets.append(packet)
            offset = end
        } while offset < message.count

        // Register for the reply before sending so a fast response can't be missed.
        return try await withCheckedThrowingContinuation { cont in
            pending[id] = cont
            for packet in packets {
                p.writeValue(packet, for: rx, type: .withResponse)
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                self.pending.removeValue(forKey: id)?.resume(throwing: ApiError(message: "Timed out"))
            }
        }
    }

    private func acquire() async {
        if !busy { busy = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }

    private func handleFragment(_ data: Data) {
        guard let flags = data.first else { return }
        if flags & 0x01 != 0 { rxBuffer = Data() }
        rxBuffer.append(data.dropFirst())
        guard flags & 0x02 != 0 else { return }

        let message = rxBuffer
        rxBuffer = Data()
        guard let nl = message.firstIndex(of: 0x0A) else { return }
        let header = String(decoding: message[message.startIndex..<nl], as: UTF8.self)
        let body = message.subdata(in: (nl + 1)..<message.endIndex)
        let parts = header.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2, let id = Int(parts[0]), let code = Int(parts[1]) else { return }
        pending.removeValue(forKey: id)?.resume(returning: (code, body))
    }

    private func failAll(_ reason: String) {
        let conts = pending
        pending.removeAll()
        conts.values.forEach { $0.resume(throwing: ApiError(message: reason)) }
    }

    private func startScan() {
        guard central.state == .poweredOn else { return }
        state = .scanning
        central.scanForPeripherals(withServices: [Self.advertisedService])
    }
}

extension BLEApi: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            switch central.state {
            case .poweredOn: self.startScan()
            case .unauthorized: self.state = .unauthorized
            default: self.state = .bluetoothOff
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any], rssi RSSI: NSNumber) {
        Task { @MainActor in
            guard self.peripheral == nil else { return }
            central.stopScan()
            self.peripheral = peripheral
            self.deviceName = peripheral.name ?? "OpenHaldex"
            peripheral.delegate = self
            self.state = .connecting
            central.connect(peripheral)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([BLEApi.apiService])
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral,
                                    error: Error?) {
        Task { @MainActor in
            self.peripheral = nil
            self.startScan()
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                                    error: Error?) {
        Task { @MainActor in
            self.peripheral = nil
            self.rx = nil
            self.failAll("Disconnected")
            self.startScan()
        }
    }
}

extension BLEApi: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let s = peripheral.services?.first(where: { $0.uuid == BLEApi.apiService }) else {
            Task { @MainActor in self.state = .connecting }  // Old firmware without the API service.
            return
        }
        peripheral.discoverCharacteristics([BLEApi.rxChar, BLEApi.txChar], for: s)
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService,
                                error: Error?) {
        let chars = service.characteristics ?? []
        Task { @MainActor in
            for c in chars {
                if c.uuid == Self.rxChar { self.rx = c }
                if c.uuid == Self.txChar { peripheral.setNotifyValue(true, for: c) }
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic,
                                error: Error?) {
        Task { @MainActor in
            if characteristic.uuid == Self.txChar, characteristic.isNotifying, self.rx != nil {
                self.state = .ready
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic,
                                error: Error?) {
        guard characteristic.uuid == BLEApi.txChar, let data = characteristic.value else { return }
        Task { @MainActor in self.handleFragment(data) }
    }
}
