// Sources/BleClient.swift
import Foundation
import CoreBluetooth
import UserNotifications

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

    // Leniwa inicjalizacja – zabezpieczona przed crashem, gdy brak klucza w Info.plist
    private lazy var central: CBCentralManager? = {
        guard hasBluetoothUsageKey() else {
            update("Missing NSBluetoothAlwaysUsageDescription in Info.plist")
            notify("Bluetooth", "Brak klucza NSBluetoothAlwaysUsageDescription w Info.plist.")
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

    // Service FFF0 + preferowana char FFF1 (przykładowo)
    private let targetService = CBUUID(string: "0000FFF0-0000-1000-8000-00805F9B34FB")
    private let preferredTargetChar = CBUUID(string: "0000FFF1-0000-1000-8000-00805F9B34FB")

    private var isScanning = false
    private let scanWindow: TimeInterval = 6.0
    private var lastConnectAttempt: Date = .distantPast
    private let connectCooldown: TimeInterval = 15.0

    override init() {
        super.init()
        // central tworzymy leniwie (patrz wyżej)
        requestLocalNotificationsIfNeeded()
    }

    // MARK: - Public

    /// Delikatna inicjalizacja – tylko wywołuje prompt systemowy, bez skanowania
    func requestBluetoothPermissionOnly() {
        guard let c = central else { return } // brak klucza → nic nie rób
        _ = c.state // trigger init/prompt jeśli potrzeba
        update("BT state=\(c.state.rawValue) — auth=\(btAuthStatus)")
    }

    /// Krótkie skanowanie i szybki connect do urządzenia z usługą targetService
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

    // MARK: - Helpers

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
}

// MARK: - CBCentralManagerDelegate
extension BleClient: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        update("central=\(central.state.rawValue) — btAuth=\(btAuthStatus)")
        // Jeśli mieliśmy zapamiętany peripheral i BT się włączył – spróbuj połączyć
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
        guard Date().timeIntervalSince(lastConnectAttempt) >= connectCooldown else { return }
        lastConnectAttempt = Date()

        update("found \(peripheral.name ?? "device")")
        self.peripheral = peripheral
        central.stopScan()
        isScanning = false
        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        update("connected")
        notify("BLE", "Połączono z \(peripheral.name ?? "urządzeniem")")
        peripheral.delegate = self
        peripheral.discoverServices([targetService])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        update("connect failed: \(error?.localizedDescription ?? "-")")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        update("disconnected")
        // Opcjonalny auto-reconnect tylko do tego samego urządzenia
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
        guard error == nil else { update("svc err: \(error!.localizedDescription)"); return }
        guard let services = peripheral.services, !services.isEmpty else { update("no services"); return }

        for s in services {
            print("[BleClient] service:", s.uuid.uuidString)
            if s.uuid == targetService {
                peripheral.discoverCharacteristics(nil, for: s)
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        guard error == nil else { update("char err: \(error!.localizedDescription)"); return }
        guard let chars = service.characteristics, !chars.isEmpty else { update("no chars"); return }

        for ch in chars {
            print("[BleClient] char:", ch.uuid.uuidString, "props:", ch.properties)
        }

        if let ch = chars.first(where: { $0.uuid == preferredTargetChar }) {
            writeDemoPayload(on: peripheral, to: ch)
            return
        }

        if let writable = chars.first(where: { $0.properties.contains(.write) || $0.properties.contains(.writeWithoutResponse) }) {
            writeDemoPayload(on: peripheral, to: writable)
            return
        }

        update("no writable char")
    }

    private func writeDemoPayload(on peripheral: CBPeripheral, to ch: CBCharacteristic) {
        let payload = Data("test".utf8)
        let type: CBCharacteristicWriteType =
            ch.properties.contains(.write) ? .withResponse : .withoutResponse

        peripheral.writeValue(payload, for: ch, type: type)
        update("wrote \(payload.count)B to \(ch.uuid.uuidString) (\(type == .withResponse ? "withResp" : "withoutResp"))")
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let e = error {
            update("write error: \(e.localizedDescription)")
        } else {
            update("write OK")
            notify("BLE", "Write OK na \(characteristic.uuid.uuidString)")
        }
    }
}
