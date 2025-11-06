//
//  BleClient.swift
//
//  Skanuje urządzenie z usługą 0x1234, łączy i zapisuje "test" do char 0x5678.
//  Działa również jako krótka akcja po wejściu w region iBeacon (patrz BeaconMonitor).
//
//  Wymagania projektu (Capabilities / Info.plist):
//  - Background Modes: Uses Bluetooth LE accessories (bluetooth-central)
//  - (dla iBeacon) Background Modes: Location updates
//  - Info.plist: NSBluetoothAlwaysUsageDescription (+ lokalne powiadomienia, jeśli używasz notify())
//

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

    // MARK: - Konfiguracja „Twojego” urządzenia
    // (podmień jeśli potrzebujesz inne UUID-y)
    private let targetService       = CBUUID(string: "1234")
    private let preferredTargetChar = CBUUID(string: "5678")

    // MARK: - Stan CoreBluetooth

    // Leniwa inicjalizacja – chroni przed crashem, jeśli brak usage key w Info.plist
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
                // Wspiera State Preservation & Restoration
                CBCentralManagerOptionRestoreIdentifierKey: "pl.yourcompany.ble.central"
            ]
        )
    }()

    private var peripheral: CBPeripheral?

    // Ostatnio znany identyfikator peryferium (lokalny dla iOS)
    private let lastPeripheralKey = "LastPeripheralUUID"

    // Operacyjne
    private var isScanning = false
    private let scanWindow: TimeInterval = 6.0
    private var lastConnectAttempt: Date = .distantPast
    private let connectCooldown: TimeInterval = 15.0
    private var pendingWriteValue: Data?

    // (opcjonalnie) Krótkie działania w tle podczas „ibeacon-write”
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

    /// Delikatna inicjalizacja – tylko prompt systemowy, bez skanowania
    func requestBluetoothPermissionOnly() {
        guard let c = central else { return } // brak klucza → nic nie rób
        _ = c.state // trigger init/prompt jeśli potrzeba
        update("BT state=\(c.state.rawValue) — auth=\(btAuthStatus)")
    }

    /// Krótki „manualny” skan i połączenie do urządzenia z usługą `targetService`
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
        beginScan(with: [targetService])
    }

    /// Wyzwalane po wejściu w region iBeacon – spróbuj szybko zapisać `valueToWrite`
    /// do charakterystyki 0x5678 (w serwisie 0x1234).
    func writeAfterRegionEnter(valueToWrite: Data) {
        _ = central?.state  // wymuś inicjalizację
        guard let c = central, c.state == .poweredOn else {
            update("BT nieaktywne lub central=nil")
            return
        }
        pendingWriteValue = valueToWrite
        beginBGTask(named: "ibeacon-write")
        // 1) Jeśli mamy zapamiętany CBPeripheral.identifier – spróbuj bez skanu
        if let known = retrieveKnownPeripheral() {
            update("connect known peripheral…")
            self.peripheral = known
            c.connect(known, options: nil)
            return
        }
        // 2) Jeśli urządzenie już jest połączone (np. przez system) – wykorzystaj
        if let connected = c.retrieveConnectedPeripherals(withServices: [targetService]).first {
            update("use connected peripheral")
            self.peripheral = connected
            // Jesteśmy połączeni, rusz z discoverServices
            connected.delegate = self
            connected.discoverServices([targetService])
            return
        }
        // 3) Fallback – krótki skan po usłudze
        beginScan(with: [targetService])
    }

    // MARK: - Private helpers

    private func beginScan(with services: [CBUUID]?) {
        guard let c = central, !isScanning else { return }
        isScanning = true
        lastConnectAttempt = Date()
        update("scan \(services?.map{$0.uuidString}.joined(separator: ",") ?? "any")…")
        c.scanForPeripherals(
            withServices: services,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
        DispatchQueue.main.asyncAfter(deadline: .now() + scanWindow) { [weak self] in
            self?.stopScanIfAny(reason: "timeout")
            // Jeśli skan nic nie znalazł, pozwól BG taskowi dobiec końca naturalnie
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
    }

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
        // Jeśli central jest ON i mamy obiekt peryferium (np. po restore), spróbuj połączyć
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
            // Jeśli była w toku operacja zapisu – dokończ
            if let p = self.peripheral {
                if p.state == .connected {
                    p.discoverServices([targetService])
                } else {
                    central.connect(p, options: nil)
                }
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

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        update("connected")
        notify("BLE", "Połączono z \(peripheral.name ?? "urządzeniem")")
        persistPeripheralIdentifier(peripheral)
        peripheral.delegate = self
        // Najpierw spróbuj tylko targetService...
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
        guard let services = peripheral.services, !services.isEmpty else {
            update("no services; retry all")
            peripheral.discoverServices(nil) // Fallback: odkryj wszystkie
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

        // jeśli nie znaleziono targetService, spróbuj „pierwszego lepszego”
        if !hit, let s = services.first(where: { $0.uuid == targetService }) {
            peripheral.discoverCharacteristics(nil, for: s)
        } else if !hit, let any = services.first {
            update("target svc not found, try \(any.uuid.uuidString)")
            peripheral.discoverCharacteristics(nil, for: any)
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        guard error == nil else { update("char err: \(error!.localizedDescription)"); endBGTaskIfAny(); return }
        guard let chars = service.characteristics, !chars.isEmpty else { update("no chars"); endBGTaskIfAny(); return }

        for ch in chars {
            print("[BleClient] char:", ch.uuid.uuidString, "props:", ch.properties)
        }

        // 1) preferowana 0x5678
        if let ch = chars.first(where: { $0.uuid == preferredTargetChar }) {
            writePayload(on: peripheral, to: ch); return
        }
        // 2) jakakolwiek zapisywalna
        if let writable = chars.first(where: { $0.properties.contains(.write) || $0.properties.contains(.writeWithoutResponse) }) {
            writePayload(on: peripheral, to: writable); return
        }
        update("no writable char")
        endBGTaskIfAny()
    }

    private func writePayload(on peripheral: CBPeripheral, to ch: CBCharacteristic) {
        let payload = pendingWriteValue ?? Data("test".utf8) // domyślnie „test”
        let type: CBCharacteristicWriteType =
            ch.properties.contains(.write) ? .withResponse : .withoutResponse

        peripheral.writeValue(payload, for: ch, type: type)
        update("write \(payload.count)B to \(ch.uuid.uuidString) (\(type == .withResponse ? "withResp" : "withoutResp"))")

        // Jeśli bez odpowiedzi – nie dostaniemy callbacku didWriteValueFor
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
