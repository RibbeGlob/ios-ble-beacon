import Foundation
import CoreBluetooth
import UserNotifications

// Helper do czytelnego statusu autoryzacji BT (iOS 13+)
@available(iOS 13.0, *)
fileprivate func bluetoothAuthString() -> String {
    switch CBManager.authorization {
    case .allowedAlways: return "allowed"
    case .denied:         return "denied"
    case .restricted:     return "restricted"
    case .notDetermined:  return "notDetermined"
    @unknown default:     return "unknown"
    }
}

final class BleClient: NSObject, ObservableObject {
    static let shared = BleClient()

    @Published var stateText = "idle"

    // --- LAZY central (powstaje dopiero przy pierwszym użyciu) ---
    private lazy var central: CBCentralManager = {
        CBCentralManager(
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
        // Uwaga: nie twórz tutaj central – jest lazy
        requestLocalNotificationsIfNeeded()
    }

    // MARK: - Public
    func shortScanAndConnect() {
        // Odwołanie do 'central' zainicjuje go, jeśli trzeba
        guard central.state == .poweredOn else {
            update("BT off (\(central.state.rawValue)) — auth=\(btAuthStatus)")
            return
        }
        guard !isScanning else { return }
        guard Date().timeIntervalSince(lastConnectAttempt) >= connectCooldown else {
            update("cooldown…")
            return
        }

        isScanning = true
        update("scanning \(targetService.uuidString)…")
        central.scanForPeripherals(
            withServices: [targetService],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )

        DispatchQueue.main.asyncAfter(deadline: .now() + scanWindow) { [weak self] in
            guard let self = self else { return }
            self.central.stopScan()
            self.isScanning = false
            if self.peripheral == nil { self.update("no device found") }
        }
    }

    func requestBluetoothPermissionOnly() {
        _ = central.state // lazy init + trigger auth prompt jeśli potrzeba
        update("BT state=\(central.state.rawValue) — auth=\(btAuthStatus)")
    }
    // MARK: - Helpers
    private func update(_ text: String) {
        // gwarancja głównego wątku dla Published/UI
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
