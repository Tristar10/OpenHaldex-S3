import CoreBluetooth
import Foundation

/// BLE link to the OpenHaldex controller. Today it speaks the RaceChrono DIY
/// service the firmware already exposes (0x1FF8): subscribe to the CAN-data
/// characteristic and ask for the decoded OpenHaldex PID 0xFFFF0001.
///
/// Note: firmware currently serves one BLE central at a time, so while this
/// app is connected RaceChrono cannot be (and vice versa).
@MainActor
final class HaldexLink: NSObject, ObservableObject {
    enum State: Equatable {
        case bluetoothOff
        case unauthorized
        case scanning
        case connecting(String)
        case connected(String)
        case demo
    }

    nonisolated static let serviceUUID = CBUUID(string: "1FF8")
    nonisolated static let canDataUUID = CBUUID(string: "0001")
    nonisolated static let canFilterUUID = CBUUID(string: "0002")
    nonisolated static let deviceName = "OpenHaldex-RC"

    @Published private(set) var state: State = .bluetoothOff
    @Published private(set) var telemetry = Telemetry()
    @Published private(set) var sampleRateHz: Double = 0

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var filterChar: CBCharacteristic?
    private var demoTimer: Timer?
    private var demoPhase: Double = 0
    private var sampleTimes: [Date] = []

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    var isLive: Bool {
        Date().timeIntervalSince(telemetry.receivedAt) < 1.0
    }

    // MARK: Demo mode (simulator / no car)

    func setDemo(_ on: Bool) {
        demoTimer?.invalidate()
        demoTimer = nil
        if on {
            disconnect()
            state = .demo
            demoTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.demoTick() }
            }
        } else {
            state = .scanning
            startScan()
        }
    }

    private func demoTick() {
        demoPhase += 0.05
        // A crude 2nd-gear pull: rpm sweeps 3000 → 7200 then "shifts".
        let cycle = demoPhase.truncatingRemainder(dividingBy: 4.0) / 4.0
        var t = Telemetry()
        t.rpm = Int(3000 + cycle * 4400)
        t.speedKmh = 40 + cycle * 60
        t.pedalPercent = cycle < 0.95 ? 100 : 0
        t.lockTarget = 70
        t.lockActual = Int(55 + 15 * sin(demoPhase * 3))
        t.mode = HaldexMode.m7030.rawValue
        t.receivedAt = Date()
        ingest(t)
    }

    // MARK: BLE

    func startScan() {
        guard central.state == .poweredOn, state != .demo else { return }
        state = .scanning
        central.scanForPeripherals(withServices: [Self.serviceUUID])
    }

    func disconnect() {
        if let p = peripheral { central.cancelPeripheralConnection(p) }
        peripheral = nil
        filterChar = nil
    }

    private func ingest(_ t: Telemetry) {
        telemetry = t
        let now = t.receivedAt
        sampleTimes.append(now)
        sampleTimes.removeAll { now.timeIntervalSince($0) > 2 }
        sampleRateHz = Double(sampleTimes.count) / 2.0
    }

    private func subscribeOpenHaldex(on p: CBPeripheral) {
        guard let filter = filterChar else { return }
        p.writeValue(RaceChronoFrame.denyAll, for: filter, type: .withResponse)
        p.writeValue(RaceChronoFrame.allowPid(RaceChronoFrame.openHaldexPid, intervalMs: 50),
                     for: filter, type: .withResponse)
    }
}

extension HaldexLink: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            guard self.state != .demo else { return }
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
            guard self.peripheral == nil, self.state != .demo else { return }
            central.stopScan()
            self.peripheral = peripheral
            peripheral.delegate = self
            self.state = .connecting(peripheral.name ?? Self.deviceName)
            central.connect(peripheral)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            self.state = .connected(peripheral.name ?? Self.deviceName)
            peripheral.discoverServices([Self.serviceUUID])
        }
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
            self.filterChar = nil
            if self.state != .demo { self.startScan() }
        }
    }
}

extension HaldexLink: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == HaldexLink.serviceUUID }) else { return }
        peripheral.discoverCharacteristics([HaldexLink.canDataUUID, HaldexLink.canFilterUUID], for: service)
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService,
                                error: Error?) {
        let chars = service.characteristics ?? []
        Task { @MainActor in
            for c in chars {
                if c.uuid == Self.canDataUUID { peripheral.setNotifyValue(true, for: c) }
                if c.uuid == Self.canFilterUUID { self.filterChar = c }
            }
            self.subscribeOpenHaldex(on: peripheral)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic,
                                error: Error?) {
        guard let data = characteristic.value,
              let frame = RaceChronoFrame.parse(data),
              frame.pid == RaceChronoFrame.openHaldexPid,
              let t = Telemetry.decode(payload: frame.payload) else { return }
        Task { @MainActor in self.ingest(t) }
    }
}
