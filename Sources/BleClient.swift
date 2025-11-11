import Foundation
import CoreBluetooth
import UserNotifications
import UIKit

// MARK: - Wspólny logger

final class DebugLog: ObservableObject {
    static let shared = DebugLog()

    @Published private(set) var lines: [String] = []

    private let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    func add(_ tag: String, _ msg: String) {
        let time = dateFormatter.string(from: Date())
        let line = "[\(time)] [\(tag)] \(msg)"

        DispatchQueue.main.async {
            self.lines.append(line)
            if self.lines.count > 500 {
                self.lines.removeFirst(self.lines.count - 500)
            }
            print(line)
        }
    }

    var joined: String {
        lines.joined(separator: "\n")
    }
}

// MARK: - BLE Client

@available(iOS 13.0, *)
fileprivate func bluetoothAuthString() -> String {
    switch CBManager.authorization {
    case .allowedAlways: return "allowed"
    case .denied:        return "denied"
    case .restricted:    return "restricted"
    case .notDetermined: return "notDetermined"
    @unknown default:    return "unknown"
    }
}

final class BleClient: NSObject, ObservableObject {
    static let shared = BleClient()

    @Published var stateText = "idle"

    // MARK: - Konfiguracja

    private let advertisedService = CBUUID(string: "FFF0")
    private let targetService = CBUUID(string: "1234")
    private let preferredTargetChar = CBUUID(string: "5678")

    // MARK: - CoreBluetooth

    private lazy var central: CBCentralManager? = {
        guard hasBluetoothUsageKey() else {
            update("Missing NSBluetoothAlwaysUsageDescription in Info.plist")
            notify("Bluetooth", "Brak klucza NSBluetoothAlwaysUsageDescription.")
            return nil
        }

        let manager = CBCentralManager(
            delegate: self,
            queue: .main,
            options: [
                CBCentralManagerOptionShowPowerAlertKey: true,
                CBCentralManagerOptionRestoreIdentifierKey: "pl.yourcompany.ble.central"
            ]
        )
        update("CBCentralManager init, state=\(manager.state.rawValue)")
        return manager
    }()

    private var peripheral: CBPeripheral?

    // Zapamiętany CBPeripheral.identifier
    private let lastPeripheralKey = "LastPeripheralUUID"

    private var isScanning = false
    private let scanWindow: TimeInterval = 6.0
    private var pendingWriteValue: Data?
    private var bgTask: UIBackgroundTaskIdentifier = .invalid

    // iBeacon-triggered akcje oczekujące na gotowy BT
    private var pendingAutoScan = false
    private var pendingAutoConnect = false

    // Co ile sekund robimy cykl: connect -> write -> disconnect -> czekaj -> connect...
    private let reconnectInterval: TimeInterval = 30
    private var reconnectTimer: Timer?

    // Anti-spam dla auto-scanów
    private let autoScanCooldown: TimeInterval = 5
    private var lastAutoScanDate: Date?

    var btAuthStatus: String {
        if #available(iOS 13.0, *) { return bluetoothAuthString() }
        return "n/a"
    }

    override init() {
        super.init()
        requestLocalNotificationsIfNeeded()
        DebugLog.shared.add("BLE", "BleClient init")
    }

    // MARK: - Public: ręczne parowanie (UI)

    func initialPairingScan() {
        cancelPeriodicReconnect()

        guard let c = central else {
            update("initialPairingScan: central=nil (brak klucza BT usage?)")
            return
        }
        guard c.state == .poweredOn else {
            update("initialPairingScan: BT off (\(c.state.rawValue)) — auth=\(btAuthStatus)")
            return
        }
        guard !isScanning else {
            update("initialPairingScan: scan already in progress — skip")
            return
        }

        pendingWriteValue = Data("test".utf8)
        beginBGTask(named: "pairing-scan")
        beginScan(with: [advertisedService])
    }

    func shortScanAndConnect() {
        initialPairingScan()
    }

    // MARK: - Public: wywoływane z BeaconMonitor

    /// Główna logika z iBeacona:
    /// - jeśli znamy peripheral: connect -> write -> disconnect -> za 30s znowu
    /// - jeśli nie znamy: fallback do autoScanFromBeacon (tylko przy pierwszym razie)
    func autoConnectFromBeacon(reason: String = "beacon") {
        guard let c = central else {
            update("autoConnectFromBeacon[\(reason)]: central=nil")
            return
        }

        cancelPeriodicReconnect() // nowy cykl, czyści poprzedni timer

        switch c.state {
        case .poweredOn:
            if let known = retrieveKnownPeripheral() {
                update("autoConnectFromBeacon[\(reason)]: known peripheral \(known.identifier)")
                peripheral = known
                known.delegate = self
                beginBGTask(named: "auto-\(reason)-connect-known")
                c.connect(known, options: nil)
            } else {
                update("autoConnectFromBeacon[\(reason)]: no known peripheral, fallback to autoScanFromBeacon")
                autoScanFromBeacon(reason: reason)
            }

        case .resetting, .unknown:
            pendingAutoConnect = true
            update("autoConnectFromBeacon[\(reason)]: state=\(c.state.rawValue), pendingAutoConnect=true")

        case .poweredOff, .unauthorized, .unsupported:
            update("autoConnectFromBeacon[\(reason)]: state=\(c.state.rawValue), cannot connect")

        @unknown default:
            pendingAutoConnect = true
            update("autoConnectFromBeacon[\(reason)]: unknown state, pendingAutoConnect=true")
        }
    }

    /// Fallback: scan po iBeaconie (pierwsze parowanie).
    func autoScanFromBeacon(reason: String = "beacon-scan") {
        guard let c = central else {
            update("autoScanFromBeacon[\(reason)]: central=nil")
            return
        }

        let now = Date()
        if let last = lastAutoScanDate,
           now.timeIntervalSince(last) < autoScanCooldown {
            update("autoScanFromBeacon[\(reason)]: skip — cooldown")
            return
        }

        if isScanning {
            update("autoScanFromBeacon[\(reason)]: already scanning")
            return
        }

        switch c.state {
        case .poweredOn:
            lastAutoScanDate = now
            pendingWriteValue = Data("test".utf8)
            beginBGTask(named: "auto-\(reason)")
            beginScan(with: [advertisedService])
            update("autoScanFromBeacon[\(reason)]: started scan (poweredOn)")

        case .resetting, .unknown:
            pendingAutoScan = true
            update("autoScanFromBeacon[\(reason)]: state=\(c.state.rawValue), pendingAutoScan=true")

        case .poweredOff, .unauthorized, .unsupported:
            update("autoScanFromBeacon[\(reason)]: state=\(c.state.rawValue), cannot scan")

        @unknown default:
            pendingAutoScan = true
            update("autoScanFromBeacon[\(reason)]: unknown state, pendingAutoScan=true")
        }
    }

    func requestBluetoothPermissionOnly() {
        guard let c = central else {
            update("requestBluetoothPermissionOnly: central=nil")
            return
        }
        _ = c.state
        update("BT state=\(c.state.rawValue) — auth=\(btAuthStatus)")
    }

    // MARK: - Periodic reconnect

    private func schedulePeriodicReconnect() {
        cancelPeriodicReconnect()

        reconnectTimer = Timer.scheduledTimer(withTimeInterval: reconnectInterval,
                                              repeats: false) { [weak self] _ in
            guard let self = self else { return }
            self.update("periodicReconnect: timer fired, autoConnectFromBeacon(periodic-timer)")
            self.autoConnectFromBeacon(reason: "periodic-timer")
        }

        if let timer = reconnectTimer {
            RunLoop.main.add(timer, forMode: .common)
        }

        update("periodicReconnect: scheduled in \(Int(reconnectInterval))s")
    }

    private func cancelPeriodicReconnect() {
        reconnectTimer?.invalidate()
        reconnectTimer = nil
    }

    // MARK: - Private helpers (scan / bg task / storage)

    private func beginScan(with services: [CBUUID]?) {
        guard let c = central else {
            update("beginScan: central=nil")
            return
        }
        guard !isScanning else {
            update("beginScan: already scanning")
            return
        }

        isScanning = true

        let svcDesc = services?.map { $0.uuidString }.joined(separator: ",") ?? "any"
        update("scan start for services: \(svcDesc)")

        c.scanForPeripherals(
            withServices: services,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )

        DispatchQueue.main.asyncAfter(deadline: .now() + scanWindow) { [weak self] in
            self?.stopScanIfAny(reason: "timeout")
        }
    }

    private func retrieveKnownPeripheral() -> CBPeripheral? {
        guard let c = central else {
            update("retrieveKnownPeripheral: central=nil")
            return nil
        }
        guard
            let uuidStr = UserDefaults.standard.string(forKey: lastPeripheralKey),
            let uuid = UUID(uuidString: uuidStr)
        else {
            update("retrieveKnownPeripheral: no stored UUID")
            return nil
        }

        let result = c.retrievePeripherals(withIdentifiers: [uuid]).first
        update("retrieveKnownPeripheral: \(result != nil ? "found" : "not found")")
        return result
    }

    private func persistPeripheralIdentifier(_ p: CBPeripheral) {
        UserDefaults.standard.setValue(p.identifier.uuidString, forKey: lastPeripheralKey)
        update("saved peripheral id \(p.identifier.uuidString)")
    }

    private func hasBluetoothUsageKey() -> Bool {
        guard let v = Bundle.main
            .object(forInfoDictionaryKey: "NSBluetoothAlwaysUsageDescription") as? String
        else { return false }
        return !v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func update(_ text: String) {
        if Thread.isMainThread {
            self.stateText = text
        } else {
            DispatchQueue.main.async { self.stateText = text }
        }
        DebugLog.shared.add("BLE", text)
    }

    private func notify(_ title: String, _ body: String) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(
                identifier: UUID().uuidString,
                content: c,
                trigger: nil
            )
        )
    }

    private func requestLocalNotificationsIfNeeded() {
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    private func beginBGTask(named: String) {
        endBGTaskIfAny()
        bgTask = UIApplication.shared.beginBackgroundTask(withName: named) { [weak self] in
            self?.update("BG task expiring (\(named))")
            self?.endBGTaskIfAny()
        }
        update("BG task begin: \(named)")
    }

    private func endBGTaskIfAny() {
        if bgTask != .invalid {
            UIApplication.shared.endBackgroundTask(bgTask)
            update("BG task end")
            bgTask = .invalid
        }
    }

    private func stopScanIfAny(reason: String) {
        guard let c = central else {
            update("stopScanIfAny: central=nil")
            isScanning = false
            endBGTaskIfAny()
            return
        }
        guard isScanning else {
            update("stopScanIfAny: not scanning (\(reason))")
            return
        }
        c.stopScan()
        isScanning = false
        update("stop scan (\(reason))")
        endBGTaskIfAny()
    }
}

// MARK: - CBCentralManagerDelegate

extension BleClient: CBCentralManagerDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        update("central state changed=\(central.state.rawValue) — btAuth=\(btAuthStatus)")

        guard central.state == .poweredOn else { return }

        if pendingAutoConnect {
            pendingAutoConnect = false
            update("centralDidUpdateState: handling pendingAutoConnect")
            autoConnectFromBeacon(reason: "pendingAutoConnect")
            return
        }

        if pendingAutoScan, !isScanning {
            pendingAutoScan = false
            lastAutoScanDate = Date()
            pendingWriteValue = Data("test".utf8)
            beginBGTask(named: "pending-auto-scan")
            beginScan(with: [advertisedService])
            update("centralDidUpdateState: run pendingAutoScan")
        }
    }

    func centralManager(_ central: CBCentralManager,
                        willRestoreState dict: [String : Any]) {
        if let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral],
           let restored = peripherals.first {
            self.peripheral = restored
            self.peripheral?.delegate = self
            update("willRestoreState: restored peripheral \(restored.identifier.uuidString)")
            if restored.state == .connected {
                update("restored peripheral already connected — discover services")
                restored.discoverServices([targetService])
            }
        } else {
            update("willRestoreState: no peripherals")
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String : Any],
                        rssi RSSI: NSNumber) {

        update("didDiscover: \(peripheral.name ?? "device") rssi=\(RSSI)")
        stopScanIfAny(reason: "candidate")
        self.peripheral = peripheral
        peripheral.delegate = self
        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager,
                        didConnect peripheral: CBPeripheral) {
        update("didConnect: \(peripheral.name ?? "device")")
        notify("BLE", "Połączono z \(peripheral.name ?? "urządzeniem")")
        persistPeripheralIdentifier(peripheral)
        peripheral.delegate = self
        peripheral.discoverServices([targetService])
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        update("didFailToConnect: \(error?.localizedDescription ?? "-")")
        endBGTaskIfAny()
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        update("didDisconnect: \(error?.localizedDescription ?? "no error")")
        endBGTaskIfAny()
        // Uwaga: NIE kasujemy tutaj timera reconnect.
        // Jeśli disconnect był po udanym write, timer już jest ustawiony.
    }
}

// MARK: - CBPeripheralDelegate

extension BleClient: CBPeripheralDelegate {

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverServices error: Error?) {
        guard error == nil else {
            update("didDiscoverServices error: \(error!.localizedDescription)")
            endBGTaskIfAny()
            return
        }
        guard let services = peripheral.services, !services.isEmpty else {
            update("didDiscoverServices: no services")
            endBGTaskIfAny()
            return
        }

        var hit = false
        for s in services {
            DebugLog.shared.add("BLE", "service: \(s.uuid.uuidString)")
            if s.uuid == targetService {
                hit = true
                peripheral.discoverCharacteristics(nil, for: s)
            }
        }

        if !hit {
            update("target svc 0x1234 not found")
            endBGTaskIfAny()
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        guard error == nil else {
            update("didDiscoverCharacteristics error: \(error!.localizedDescription)")
            endBGTaskIfAny()
            return
        }
        guard let chars = service.characteristics, !chars.isEmpty else {
            update("didDiscoverCharacteristics: no chars")
            endBGTaskIfAny()
            return
        }

        for ch in chars {
            DebugLog.shared.add("BLE", "char: \(ch.uuid.uuidString) props: \(ch.properties)")
        }

        // wybierz preferowaną lub jakąkolwiek zapisywalną i wykonaj pojedynczy write
        if let ch = chars.first(where: { $0.uuid == preferredTargetChar }) {
            writePayloadAndScheduleReconnect(on: peripheral, to: ch)
            return
        }

        if let writable = chars.first(where: {
            $0.properties.contains(.write) || $0.properties.contains(.writeWithoutResponse)
        }) {
            writePayloadAndScheduleReconnect(on: peripheral, to: writable)
            return
        }

        update("no writable char")
        endBGTaskIfAny()
    }

    /// Pojedynczy write, po którym:
    /// - przy sukcesie: rozłączamy się
    /// - ustawiamy timer na ponowny connect za reconnectInterval
    private func writePayloadAndScheduleReconnect(on peripheral: CBPeripheral,
                                                  to ch: CBCharacteristic) {
        let payload = pendingWriteValue ?? Data("test".utf8)
        let type: CBCharacteristicWriteType =
            ch.properties.contains(.write) ? .withResponse : .withoutResponse

        pendingWriteValue = payload

        peripheral.writeValue(payload, for: ch, type: type)
        update("write \(payload.count)B to \(ch.uuid.uuidString) (\(type == .withResponse ? "withResp" : "withoutResp"))")

        if type == .withoutResponse {
            // Brak callbacku -> zakładamy sukces i robimy to samo co przy OK po krótkiej chwili
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self = self else { return }
                self.update("noResp write assumed OK, disconnect & schedule reconnect")
                self.pendingWriteValue = nil
                self.schedulePeriodicReconnect()
                if let c = self.central {
                    c.cancelPeripheralConnection(peripheral)
                }
                self.endBGTaskIfAny()
            }
        }
        // Jeśli withResponse -> rozłączenie i timer w didWriteValueFor
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didWriteValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        if let e = error {
            update("didWriteValue error: \(e.localizedDescription)")
            pendingWriteValue = nil
            // przy błędzie: nie ustawiamy cyklicznego reconnect (ew. można)
        } else {
            update("didWriteValue OK on \(characteristic.uuid.uuidString)")
            notify("BLE", "Write OK na \(characteristic.uuid.uuidString)")
            pendingWriteValue = nil

            // tutaj robimy dokładnie to, czego chciałeś:
            // 1) rozłącz
            // 2) ustaw timer na ponowny connect
            schedulePeriodicReconnect()
            if let c = central {
                c.cancelPeripheralConnection(peripheral)
            }
        }

        endBGTaskIfAny()
    }
}
