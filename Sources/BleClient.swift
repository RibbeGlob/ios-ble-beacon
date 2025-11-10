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

    // MARK: - Konfiguracja pod Twoje urządzenie

    /// Usługa reklamowana w Scan Response (SVC_UUID_16 = 0xFFF0)
    private let advertisedService = CBUUID(string: "FFF0")

    /// Rzeczywisty GATT Service w urządzeniu (GPIO_SERVICE_UUID = 0x1234)
    private let targetService = CBUUID(string: "1234")

    /// Rzeczywista charakterystyka (GPIO_CHARACTERISTIC_UUID = 0x5678)
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

    /// Zapamiętany CBPeripheral.identifier (lokalny odpowiednik MAC dla appki)
    private let lastPeripheralKey = "LastPeripheralUUID"

    private var isScanning = false
    private let scanWindow: TimeInterval = 6.0
    private var pendingWriteValue: Data?
    private var bgTask: UIBackgroundTaskIdentifier = .invalid

    /// Flaga: iBeacon poprosił o auto-skan, ale BT jeszcze nie był gotowy.
    private var pendingAutoScan = false
    /// Minimalny odstęp między auto-skanami, żeby nie spamować (sekundy)
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

    // MARK: - Public

    /// Tylko do ręcznego wywołania z UI: odpala skan natychmiast,
    /// jeśli BT jest gotowe.
    func initialPairingScan() {
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

    /// Auto-skan wywoływany z BeaconMonitor (wejście w region, state inside itp.).
    /// Ten wariant jest przygotowany na tło / brak foregroundu.
    func autoScanFromBeacon(reason: String = "beacon") {
        guard let c = central else {
            update("autoScanFromBeacon[\(reason)]: central=nil")
            return
        }

        // Anti-spam: nie odpalaj co sekundę przy flappującym regionie.
        let now = Date()
        if let last = lastAutoScanDate,
           now.timeIntervalSince(last) < autoScanCooldown {
            update("autoScanFromBeacon[\(reason)]: skip — cooldown")
            return
        }

        // Jeśli już skanujemy, nie dublujemy.
        if isScanning {
            update("autoScanFromBeacon[\(reason)]: already scanning")
            return
        }

        switch c.state {
        case .poweredOn:
            lastAutoScanDate = now
            pendingWriteValue = Data("test".utf8)
            beginBGTask(named: "auto-\(reason)-scan")
            beginScan(with: [advertisedService])
            update("autoScanFromBeacon[\(reason)]: started scan (state=poweredOn)")

        case .resetting, .unknown:
            // BT w przejściu – zaznacz, że jak tylko wstanie, mamy skanować
            pendingAutoScan = true
            update("autoScanFromBeacon[\(reason)]: state=\(c.state.rawValue), set pendingAutoScan=true")

        case .poweredOff, .unsupported, .unauthorized:
            // Tutaj i tak nic nie zrobimy – log do debugowania.
            update("autoScanFromBeacon[\(reason)]: state=\(c.state.rawValue), no scan")

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

    // MARK: - Private helpers

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
        guard let uuidStr = UserDefaults.standard.string(forKey: lastPeripheralKey),
              let uuid = UUID(uuidString: uuidStr) else {
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

        // Jeśli iBeacon wcześniej poprosił o auto-skan, a BT dopiero teraz wstało.
        if central.state == .poweredOn, pendingAutoScan, !isScanning {
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

    func centralManager(_ central: CBCentralManager),
                        didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        update("didDisconnect: \(error?.localizedDescription ?? "no error")")
        endBGTaskIfAny()
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

        if let ch = chars.first(where: { $0.uuid == preferredTargetChar }) {
            writePayload(on: peripheral, to: ch)
            return
        }

        if let writable = chars.first(where: {
            $0.properties.contains(.write) || $0.properties.contains(.writeWithoutResponse)
        }) {
            writePayload(on: peripheral, to: writable)
            return
        }

        update("no writable char")
        endBGTaskIfAny()
    }

    private func writePayload(on peripheral: CBPeripheral, to ch: CBCharacteristic) {
        let payload = pendingWriteValue ?? Data("test".utf8)
        let type: CBCharacteristicWriteType =
            ch.properties.contains(.write) ? .withResponse : .withoutResponse

        peripheral.writeValue(payload, for: ch, type: type)
        update("write \(payload.count)B to \(ch.uuid.uuidString) (\(type == .withResponse ? "withResp" : "withoutResp"))")

        if type == .withoutResponse {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.notify("BLE", "Write (no resp) na \(ch.uuid.uuidString)")
                self?.pendingWriteValue = nil
                self?.endBGTaskIfAny()
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didWriteValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        if let e = error {
            update("didWriteValue error: \(e.localizedDescription)")
        } else {
            update("didWriteValue OK on \(characteristic.uuid.uuidString)")
            notify("BLE", "Write OK na \(characteristic.uuid.uuidString)")
        }
        pendingWriteValue = nil
        endBGTaskIfAny()
    }
}
