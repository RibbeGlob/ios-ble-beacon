import Foundation
import CoreBluetooth
import UserNotifications
import UIKit

// Czytelny status autoryzacji BT (iOS 13+)
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

    // Leniwa inicjalizacja – broni przed crashem, jeśli brak usage key w Info.plist
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

    var btAuthStatus: String {
        if #available(iOS 13.0, *) { return bluetoothAuthString() }
        return "n/a"
    }

    // PRZYKŁADOWE: service/char do własnego urządzenia
    // (podmień na swoje — np. 0x1234 / 0x5678)
    private let targetService       = CBUUID(string: "0000FFF0-0000-1000-8000-00805F9B34FB")
    private let preferredTargetChar = CBUUID(string: "0000FFF1-0000-1000-8000-00805F9B34FB")

    private var isScanning = false
    private let scanWindow: TimeInterval = 6.0
    private var lastConnectAttempt: Date = .distantPast
    private let connectCooldown: TimeInterval = 15.0

    // (opcjonalnie) krótkie działania w tle
    private var bgTask: UIBackgroundTaskIdentifier = .invalid

    override init() {
        super.init()
        requestLocalNotificationsIfNeeded()
    }

    // MARK: - Public

    /// Delikatna inicjalizacja – tylko prompt systemowy, bez skanowania
    func requestBluetoothPermissionOnly() {
        guard let c = central else { return } // brak klucza → nic nie rób
        _ = c.state // trigger init/prompt jeśli potrzeba
        update("BT state=\(c.state.rawValue) — auth=\(btAuthStatus)")
    }

    /// Krótkie skanowanie i szybkie łączenie do urządzenia z usługą `targetService`
    func shortScanAndConnect() {
        guard let c = central else {
            update("central=nil (brak klucza BT usage?)")
            return
        }
        guard c.state == .poweredOn else {
            update("BT off (\(c.state.rawValue)) — auth=\(btAuthStatus)")
            return
        }
        guard !isScanning else { return }
        guard Date().timeIntervalSince(lastConnectAttempt) >= connectCooldown else {
            update("cooldown…")
            return
        }

        isScanning = true
        update("scanning \(targetService.uuidString)…")
        c.scanForPeripherals(
            withServices: [targetService],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )

        DispatchQueue.main.asyncAfter(deadline: .now() + scanWindow) { [weak self] in
            guard let self = self, let c = self.central else { return }
            c.stopScan()
            self.isScanning = false
            if self.peripheral == nil { self.update("no device found") }
        }
    }

    /// (opcjonalnie) wywołanie po wejściu w region iBeacon – uruchamia skan i zapis
    func writeAfterRegionEnter(valueToWrite: Data) {
        _ = central?.state
        guard let c = central, c.state == .poweredOn else {
            update("BT nieaktywne lub central=nil")
            return
        }
        pendingWriteValue = valueToWrite
        beginBGTask(named: "ibeacon-write")
        startScanForTargetService()
    }

    // MARK: - Private helpers

    private var pendingWriteValue: Data?

    private func hasBluetoothUsageKey() -> Bool {
        guard let v = Bundle.main.object(forInfoDictionaryKey: "NSBluetoothAlwaysUsageDescription") as? String
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
            UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil)
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

    private func startScanForTargetService() {
        guard let c = central, !isScanning else { return }
        isScanning = true
        update("scan svc \(targetService.uuidString)…")
        c.scanForPeripherals(withServices: [targetService],
                             options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            self?.stopScanIfAny(reason: "timeout")
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
        if central.state == .poweredOn, let p = peripheral {
            central.connect(p, options: nil)
        }
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String : Any]) {
        if let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral],
           let restored = peripherals.first {
            self.peripheral = restored
            self.peripheral?.delegate = self
            update("restored peripheral")
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

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        update("connected")
        notify("BLE", "Połączono z \(peripheral.name ?? "urządzeniem")")
        peripheral.delegate = self
        peripheral.discoverServices([targetService])
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
        // prosty auto-reconnect do tego samego urządzenia (opcjonalnie)
        if peripheral.identifier == self.peripheral?.identifier {
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
                guard let self = self, let p = self.peripheral else { return }
                central.connect(p, options: nil)
            }
        }
    }
}

// MARK: - CBPeripheralDelegate
extension BleClient: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil else { update("svc err: \(error!.localizedDescription)"); endBGTaskIfAny(); return }
        guard let services = peripheral.services, !services.isEmpty else { update("no services"); endBGTaskIfAny(); return }

        if let s = services.first(where: { $0.uuid == targetService }) {
            peripheral.discoverCharacteristics(nil, for: s)
        } else {
            update("target service not found")
            endBGTaskIfAny()
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        guard error == nil else { update("char err: \(error!.localizedDescription)"); endBGTaskIfAny(); return }
        guard let chars = service.characteristics, !chars.isEmpty else { update("no chars"); endBGTaskIfAny(); return }

        // Preferuj z góry zadaną charakterystykę; jeśli brak – weź pierwszą zapisywalną
        if let ch = chars.first(where: { $0.uuid == preferredTargetChar }) {
            writeDemoPayload(on: peripheral, to: ch)
            return
        }
        if let writable = chars.first(where: { $0.properties.contains(.write) || $0.properties.contains(.writeWithoutResponse) }) {
            writeDemoPayload(on: peripheral, to: writable)
            return
        }

        update("no writable char")
        endBGTaskIfAny()
    }

    private func writeDemoPayload(on peripheral: CBPeripheral, to ch: CBCharacteristic) {
        // PODMIEŃ payload na własny – tu tylko przykład
        let payload = Data("test".utf8)
        let type: CBCharacteristicWriteType =
            ch.properties.contains(.write) ? .withResponse : .withoutResponse

        peripheral.writeValue(payload, for: ch, type: type)
        update("wrote \(payload.count)B to \(ch.uuid.uuidString) (\(type == .withResponse ? "withResp" : "withoutResp"))")

        if type == .withoutResponse {
            // brak callbacku — zamknij BG task po krótkiej chwili
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
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
        endBGTaskIfAny()
    }
}
