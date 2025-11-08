import Foundation
import CoreBluetooth
import UserNotifications
import UIKit

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
        return CBCentralManager(
            delegate: self,
            queue: .main,
            options: [
                CBCentralManagerOptionShowPowerAlertKey: true,
                CBCentralManagerOptionRestoreIdentifierKey: "pl.yourcompany.ble.central"
            ]
        )
    }()

    private var peripheral: CBPeripheral?

    /// Zapamiętany CBPeripheral.identifier (ekwiwalent MAC-a lokalny dla appki)
    private let lastPeripheralKey = "LastPeripheralUUID"

    private var isScanning = false
    private let scanWindow: TimeInterval = 6.0
    private var pendingWriteValue: Data?
    private var bgTask: UIBackgroundTaskIdentifier = .invalid

    var btAuthStatus: String {
        if #available(iOS 13.0, *) { return bluetoothAuthString() }
        return "n/a"
    }

    override init() {
        super.init()
        requestLocalNotificationsIfNeeded()
    }

    // MARK: - Public

    /// Ręczne wywołanie promptu BT (opcjonalne)
    func requestBluetoothPermissionOnly() {
        guard let c = central else { return }
        _ = c.state
        update("BT state=\(c.state.rawValue) — auth=\(btAuthStatus)")
    }

    /// KROK 1: pierwsze podłączenie przy urządzeniu.
    /// - skan po advertisedService (0xFFF0)
    /// - connect
    /// - zapisanie CBPeripheral.identifier do UserDefaults
    func initialPairingScan() {
        guard let c = central else {
            update("central=nil (brak klucza BT usage?)")
            return
        }
        guard c.state == .poweredOn else {
            update("BT off (\(c.state.rawValue)) — auth=\(btAuthStatus)")
            return
        }
        guard !isScanning else { return }
        beginScan(with: [advertisedService])
    }

    /// Dla zgodności: alias do initialPairingScan()
    func shortScanAndConnect() {
        initialPairingScan()
    }

    /// KROK 2: automatyczne połączenie po wejściu w strefę iBeacona.
    ///
    /// Scenariusz:
    /// - użyj zapamiętanego identifier (jeśli jest),
    /// - połącz,
    /// - znajdź service 0x1234, char 0x5678,
    /// - zapisz valueToWrite.
    ///
    /// Jeśli nie ma zapamiętanego urządzenia → tylko log (bez skanu w tle).
    func connectAndWriteAfterRegionEnter(valueToWrite: Data) {
        _ = central?.state
        guard let c = central else {
            update("central=nil — brak BT")
            return
        }

        guard c.state == .poweredOn else {
            update("BT nieaktywne (\(c.state.rawValue)) — nie łączę")
            return
        }

        guard let known = retrieveKnownPeripheral() else {
            update("brak zapisanego urządzenia — najpierw użyj 'Skanuj i sparuj'")
            return
        }

        pendingWriteValue = valueToWrite
        beginBGTask(named: "ibeacon-auto-write")

        update("region enter → connect known peripheral \(known.identifier.uuidString)")
        self.peripheral = known
        c.connect(known, options: nil)
    }

    // MARK: - Private helpers

    private func beginScan(with services: [CBUUID]?) {
        guard let c = central, !isScanning else { return }
        isScanning = true
        update("scan \(services?.map { $0.uuidString }.joined(separator: ",") ?? "any")…")

        c.scanForPeripherals(
            withServices: services,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )

        DispatchQueue.main.asyncAfter(deadline: .now() + scanWindow) { [weak self] in
            self?.stopScanIfAny(reason: "timeout")
        }
    }

    private func retrieveKnownPeripheral() -> CBPeripheral? {
        guard let c = central else { return nil }
        guard let uuidStr = UserDefaults.standard.string(forKey: lastPeripheralKey),
              let uuid = UUID(uuidString: uuidStr) else { return nil }
        return c.retrievePeripherals(withIdentifiers: [uuid]).first
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
        print("[BleClient] \(text)")
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
            self?.update("BG task expiring")
            self?.endBGTaskIfAny()
        }
    }

    private func endBGTaskIfAny() {
        if bgTask != .invalid {
            UIApplication.shared.endBackgroundTask(bgTask)
            bgTask = .invalid
        }
    }

    private func stopScanIfAny(reason: String) {
        guard let c = central, isScanning else { return }
        c.stopScan()
        isScanning = false
        update("stop scan (\(reason))")
    }
}

// MARK: - CBCentralManagerDelegate
extension BleClient: CBCentralManagerDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        update("central=\(central.state.rawValue) — btAuth=\(btAuthStatus)")
        // Gdy central wraca do .poweredOn i mamy peryferium (np. po restore),
        // możesz tu ewentualnie spróbować reconnect, ale nie jest to wymagane.
    }

    func centralManager(_ central: CBCentralManager,
                        willRestoreState dict: [String : Any]) {
        if let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral],
           let restored = peripherals.first {
            self.peripheral = restored
            self.peripheral?.delegate = self
            update("restored peripheral")
            if restored.state == .connected {
                restored.discoverServices([targetService])
            }
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String : Any],
                        rssi RSSI: NSNumber) {

        update("found \(peripheral.name ?? "device") rssi=\(RSSI)")
        stopScanIfAny(reason: "candidate")
        self.peripheral = peripheral
        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager,
                        didConnect peripheral: CBPeripheral) {
        update("connected to \(peripheral.name ?? "device")")
        notify("BLE", "Połączono z \(peripheral.name ?? "urządzeniem")")
        persistPeripheralIdentifier(peripheral)
        peripheral.delegate = self
        peripheral.discoverServices([targetService]) // 0x1234
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        update("connect failed: \(error?.localizedDescription ?? "-")")
        endBGTaskIfAny()
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        update("disconnected")
        endBGTaskIfAny()
    }
}

// MARK: - CBPeripheralDelegate
extension BleClient: CBPeripheralDelegate {

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverServices error: Error?) {
        guard error == nil else {
            update("svc err: \(error!.localizedDescription)")
            endBGTaskIfAny()
            return
        }
        guard let services = peripheral.services, !services.isEmpty else {
            update("no services")
            endBGTaskIfAny()
            return
        }

        var hit = false
        for s in services {
            print("[BleClient] service:", s.uuid.uuidString)
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
            update("char err: \(error!.localizedDescription)")
            endBGTaskIfAny()
            return
        }
        guard let chars = service.characteristics, !chars.isEmpty else {
            update("no chars")
            endBGTaskIfAny()
            return
        }

        for ch in chars {
            print("[BleClient] char:", ch.uuid.uuidString, "props:", ch.properties)
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
            update("write error: \(e.localizedDescription)")
        } else {
            update("write OK on \(characteristic.uuid.uuidString)")
            notify("BLE", "Write OK na \(characteristic.uuid.uuidString)")
        }
        pendingWriteValue = nil
        endBGTaskIfAny()
    }
}
