import Foundation
import CoreBluetooth
import UserNotifications

final class BleClient: NSObject, ObservableObject {
    static let shared = BleClient()

    @Published var stateText = "idle"

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?

    // Service/Characteristic z Twojego modułu (SVC_UUID_16 = 0xFFF0, często char = 0xFFF1)
    // Jeśli okaże się inna charakterystyka – kod poniżej i tak wybierze pierwszą zapisywalną.
    private let targetService = CBUUID(string: "0000FFF0-0000-1000-8000-00805F9B34FB")
    private let preferredTargetChar = CBUUID(string: "0000FFF1-0000-1000-8000-00805F9B34FB")

    private var isScanning = false
    private let scanWindow: TimeInterval = 6.0        // krótki skan – iOS nie lubi długich w tle
    private var lastConnectAttempt: Date = .distantPast
    private let connectCooldown: TimeInterval = 15.0   // jak na Androidzie (15 s)

    override init() {
        super.init()
        central = CBCentralManager(
            delegate: self,
            queue: .main,
            options: [
                CBCentralManagerOptionShowPowerAlertKey: true,
                CBCentralManagerRestorationIdentifierKey: "pl.yourcompany.ble.central"
            ]
        )
        requestLocalNotificationsIfNeeded()
    }

    // MARK: - Public
    func shortScanAndConnect() {
        guard central.state == .poweredOn else {
            update("BT off (\(central.state.rawValue))")
            return
        }
        guard !isScanning else { return }
        guard Date().timeIntervalSince(lastConnectAttempt) >= connectCooldown else {
            update("cooldown…")
            return
        }

        isScanning = true
        update("scanning \(targetService.uuidString)…")
        central.scanForPeripherals(withServices: [targetService],
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])

        DispatchQueue.main.asyncAfter(deadline: .now() + scanWindow) { [weak self] in
            guard let self else { return }
            self.central.stopScan()
            self.isScanning = false
            if self.peripheral == nil { self.update("no device found") }
        }
    }

    // MARK: - Helpers
    private func update(_ text: String) {
        stateText = text
        print("[BleClient] \(text)")
    }

    private func notify(_ title: String, _ body: String) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }

    private func requestLocalNotificationsIfNeeded() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
}

// MARK: - CBCentralManagerDelegate
extension BleClient: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        update("central=\(central.state.rawValue)")
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
        // cooldown – nie łącz zbyt często
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
        // prosty retry po 10 s (opcjonalnie)
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self else { return }
            if let p = self.peripheral { central.connect(p, options: nil) }
        }
    }
}

// MARK: - CBPeripheralDelegate
extension BleClient: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil else { update("svc err"); return }
        guard let services = peripheral.services, !services.isEmpty else { update("no services"); return }

        for s in services {
            print("[BleClient] service:", s.uuid.uuidString)
            if s.uuid == targetService {
                peripheral.discoverCharacteristics(nil, for: s) // odkryj wszystkie, wybierzemy właściwą
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        guard error == nil else { update("char err"); return }
        guard let chars = service.characteristics, !chars.isEmpty else { update("no chars"); return }

        // Log wszystkich znalezionych charów + właściwości
        for ch in chars {
            print("[BleClient] char:", ch.uuid.uuidString, "props:", ch.properties)
        }

        // 1) jeśli mamy preferowaną (FFF1) – użyj jej
        if let ch = chars.first(where: { $0.uuid == preferredTargetChar }) {
            writeDemoPayload(to: ch)
            return
        }

        // 2) inaczej użyj pierwszej zapisywalnej
        if let writable = chars.first(where: { $0.properties.contains(.write) || $0.properties.contains(.writeWithoutResponse) }) {
            writeDemoPayload(to: writable)
            return
        }

        update("no writable char")
    }

    private func writeDemoPayload(to ch: CBCharacteristic) {
        // —— DOPASUJ payload do trybu modułu ——
        // a) Akcja offline (GPIO): "test"
        // let payload = Data("test".utf8)

        // b) Konfiguracja JSON (gdy expecting_json==true w urządzeniu):
        // let json = #"{"ssid":"TwojaSiec","pass":"Haslo123","name":"MojeESP"}"#
        // let payload = Data(json.utf8)

        // c) Wiadomość base64 (gdy expecting_json==false):
        // let raw = "hello world".data(using: .utf8)!
        // let payload = raw.base64EncodedData()

        // Domyślnie: pokażemy 'test' (możesz zmienić wg. scenariusza)
        let payload = Data("test".utf8)

        peripheral.writeValue(payload, for: ch, type: .withResponse)
        update("wrote \(payload.count)B to \(ch.uuid.uuidString)")
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
