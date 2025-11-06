// Sources/BleClient.swift
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

    // MARK: - Konfiguracja docelowego GATT
    // Zalecane: pełne 128-bit UUID (CoreBluetooth zawsze tak normalizuje)
    private let targetService       = CBUUID(string: "00001234-0000-1000-8000-00805F9B34FB")
    private let preferredTargetChar = CBUUID(string: "00005678-0000-1000-8000-00805F9B34FB")

    // MARK: - Central & stan
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
    private var isScanning = false
    private var pendingWriteValue: Data?

    private let scanWindow: TimeInterval = 10.0
    private var bgTask: UIBackgroundTaskIdentifier = .invalid

    var btAuthStatus: String {
        if #available(iOS 13.0, *) { return bluetoothAuthString() }
        return "n/a"
    }

    // MARK: - Init
    override init() {
        super.init()
        requestLocalNotificationsIfNeeded()
    }

    // MARK: - API

    /// Tylko wywołuje prompt uprawnień Bluetooth (bez skanu/połączenia).
    func requestBluetoothPermissionOnly() {
        guard let c = central else { return }
        _ = c.state
        update("BT state=\(c.state.rawValue) — auth=\(btAuthStatus)")
    }

    /// Główne wejście: przeskanuj i zapisz "test" w char 0x5678 (lub innej zapisywalnej) w serwisie 0x1234.
    func writeTestNow() {
        write(value: Data("test".utf8))
    }

    /// Wspólna ścieżka zapisu arbitralnej wartości (domyślnie używana przez writeTestNow).
    func write(value: Data) {
        _ = central?.state
        guard let c = central else {
            update("central=nil (brak usage key?)")
            return
        }
        guard c.state == .poweredOn else {
            update("Bluetooth nie jest włączony (state=\(c.state.rawValue))")
            return
        }

        pendingWriteValue = value
        beginBGTask(named: "ble-write")
        startScanForTargetService()
    }

    // MARK: - Prywatne

    private func hasBluetoothUsageKey() -> Bool {
        guard let v = Bundle.main.object(forInfoDictionaryKey: "NSBluetoothAlwaysUsageDescription") as? String
        else { return false }
        return !v.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func startScanForTargetService() {
        guard let c = central, !isScanning else { return }
        isScanning = true
        update("scan svc \(targetService.uuidString)…")
        c.scanForPeripherals(
            withServices: [targetService], // filtr serwisu -> trafimy dokładnie Wasz ESP
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + scanWindow) { [weak self] in
            guard let self = self else { return }
            if self.isScanning {
                self.stopScanIfAny(reason: "timeout")
                self.update("no device found")
                self.endBGTaskIfAny()
            }
        }
    }

    private func stopScanIfAny(reason: String) {
        guard let c = central, isScanning else { return }
        c.stopScan()
        isScanning = false
        update("stop scan (\(reason))")
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
        if central.state == .poweredOn, let p = peripheral {
            central.connect(p, options: nil)
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
        update("connected")
        peripheral.delegate = self
        // Szukamy tylko naszego serwisu
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
            update("no services; retry all")
            peripheral.discoverServices(nil)
            return
        }

        if let svc = services.first(where: { $0.uuid == targetService }) {
            peripheral.discoverCharacteristics(nil, for: svc)
        } else if let any = services.first {
            // Fallback diagnostyczny – pozwala zobaczyć co urządzenie faktycznie wystawia
            update("target svc not found, try \(any.uuid.uuidString)")
            peripheral.discoverCharacteristics(nil, for: any)
        } else {
            update("no services after discovery")
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

        // 1) preferowana 0x5678
        if let ch = chars.first(where: { $0.uuid == preferredTargetChar }) {
            writePending(on: peripheral, to: ch); return
        }
        // 2) jakakolwiek zapisywalna
        if let writable = chars.first(where: { $0.properties.contains(.write) || $0.properties.contains(.writeWithoutResponse) }) {
            writePending(on: peripheral, to: writable); return
        }

        update("no writable char")
        endBGTaskIfAny()
    }

    private func writePending(on peripheral: CBPeripheral, to ch: CBCharacteristic) {
        let payload = pendingWriteValue ?? Data("test".utf8)
        let type: CBCharacteristicWriteType =
            ch.properties.contains(.write) ? .withResponse : .withoutResponse

        peripheral.writeValue(payload, for: ch, type: type)
        update("write \(payload.count)B to \(ch.uuid.uuidString) (\(type == .withResponse ? "withResp" : "withoutResp"))")

        if type == .withoutResponse {
            // przy NO_RSP nie będzie callbacku — domknij BG task po chwili
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
