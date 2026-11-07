import Foundation
import CoreBluetooth

// 아나 — 근처 기기(Bluetooth LE) & QR 공유 (Mac)
// 아이폰(ios/Ahna/Nearby.swift)과 같은 규약입니다. Bluetooth 부분은 같은 코드이고,
// 1회용 게스트 티켓은 Mac 수신 구성요소(TransferServer, Windows와 같은 C#)가 만듭니다.

enum MacGuest {
    /// /s/{기기 ID 32자리 16진수}/{토큰} 형식인지
    static func isGuestPath(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 4, parts[0].isEmpty, parts[1] == "s", parts[2].count == 32,
              parts[2].allSatisfy({ $0.isASCII && $0.isHexDigit }), (22...64).contains(parts[3].count),
              parts[3].allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else { return false }
        return true
    }
    /// 받은 파일 이름에서 경로 문자를 뺍니다.
    static func safeName(_ raw: String) -> String? {
        let name = raw.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != ".", name != "..", !name.hasPrefix("."), name.utf8.count <= 255 else { return nil }
        return name
    }
}

enum GuestKind: String, Sendable { case send, receive }
struct GuestFileInfo: Sendable, Equatable { let name: String; let bytes: Int64 }
/// 수신 구성요소가 알려 주는 게스트 티켓 상태
struct GuestTicketSnapshot: Sendable, Equatable {
    let token: String
    let kind: GuestKind
    /// ready · waiting · accepted · transferring · done · declined · expired
    let state: String
    let code: String?
    let expires: Date
    let files: [GuestFileInfo]
    let completed: Int
    let peer: String
    let transferred: Int64
    let total: Int64
    init?(_ object: [String: Any]) {
        guard let token = object["token"] as? String, let kind = GuestKind(rawValue: object["kind"] as? String ?? "") else { return nil }
        self.token = token; self.kind = kind
        state = object["state"] as? String ?? "ready"
        code = object["code"] as? String
        expires = Date(timeIntervalSince1970: (object["expires"] as? NSNumber)?.doubleValue ?? 0)
        files = (object["files"] as? [[String: Any]] ?? []).map { GuestFileInfo(name: $0["name"] as? String ?? "파일", bytes: ($0["bytes"] as? NSNumber)?.int64Value ?? 0) }
        completed = (object["completed"] as? NSNumber)?.intValue ?? 0
        peer = object["peer"] as? String ?? ""
        transferred = (object["transferred"] as? NSNumber)?.int64Value ?? 0
        total = (object["total"] as? NSNumber)?.int64Value ?? 0
    }
    var finished: Bool { ["done", "declined", "expired"].contains(state) }
}

enum NearbyUUID {
    static let serviceID = "A4A10001-4B2C-4F6D-9E3A-5C8B2D1F0A61"
    static let cardID = "A4A10002-4B2C-4F6D-9E3A-5C8B2D1F0A61"
    static let inboxID = "A4A10003-4B2C-4F6D-9E3A-5C8B2D1F0A61"
    static var service: CBUUID { CBUUID(string: serviceID) }
    static var card: CBUUID { CBUUID(string: cardID) }
    static var inbox: CBUUID { CBUUID(string: inboxID) }
}

enum NearbyBTState: Sendable, Equatable { case unknown, unsupported, unauthorized, off, on }

/// 근처에서 찾은 아나 기기(card를 읽은 기기만)
struct NearbyDevice: Sendable, Identifiable, Equatable {
    let id: UUID
    let name: String
    let platform: String
    let rssi: Int
    /// "아주 가까움": -60 이상이면 켜지고 -66 아래로 내려가야 꺼집니다(경계에서 깜빡이지 않게).
    let near: Bool
    var veryClose: Bool { near }
    var proximity: String { veryClose ? "아주 가까움" : "가까움" }
}

/// inbox에 쓰는 보내기 제안
struct NearbyOffer: Sendable, Equatable {
    let name: String
    let platform: String
    let code: String
    let count: Int
    let bytes: Int64
    let summary: String
    let url: String

    /// 512바이트를 넘지 않게 이름·요약을 줄여 JSON으로 만듭니다.
    var json: Data {
        func encode(_ name: String, _ summary: String) -> Data {
            let object: [String: Any] = ["v": 1, "t": "offer", "name": name, "platform": platform, "code": code, "count": count, "bytes": bytes, "summary": summary, "url": url]
            return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
        }
        var data = encode(name, summary)
        if data.count > 512 { data = encode(String(name.prefix(16)), String(summary.prefix(12))) }
        return data
    }

    static func parse(_ data: Data) -> NearbyOffer? {
        guard data.count <= 512, let input = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (input["v"] as? NSNumber)?.intValue == 1, input["t"] as? String == "offer",
              let code = input["code"] as? String, code.count == 2, code.allSatisfy({ $0.isASCII && $0.isNumber }),
              let url = input["url"] as? String, validURL(url) else { return nil }
        let count = (input["count"] as? NSNumber)?.intValue ?? 0
        let bytes = (input["bytes"] as? NSNumber)?.int64Value ?? 0
        return NearbyOffer(name: ReverseCredential.cleanName(input["name"] as? String, fallback: "근처 기기"),
                           platform: ReverseCredential.cleanName(input["platform"] as? String, fallback: ""),
                           code: code, count: max(0, min(count, 10000)), bytes: max(0, bytes),
                           summary: ReverseCredential.cleanName(input["summary"] as? String, fallback: count > 0 ? "파일 \(count)개" : "파일"), url: url)
    }

    /// https://<호스트>/s/<cid>/<token> 형식만 받습니다(계정·질의·조각 없음).
    static func validURL(_ value: String) -> Bool {
        guard value.utf8.count <= 400, let parts = URLComponents(string: value), parts.scheme?.lowercased() == "https", let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              MacGuest.isGuestPath(parts.path) else { return false }
        return true
    }
}

// MARK: - Bluetooth 라디오 (전용 큐에서만 동작)

final class NearbyRadio: NSObject, CBCentralManagerDelegate, CBPeripheralManagerDelegate, CBPeripheralDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "Ahna.mac.nearby.bluetooth")
    private var centralManager: CBCentralManager?
    private var peripheralManager: CBPeripheralManager?
    private var foreground = false
    private var advertise = false
    private var card = Data()
    private var serviceCard: Data?
    private struct Seen { var peripheral: CBPeripheral; var rssi: Double; var last: Date; var name: String?; var platform: String?; var tried: Date?; var shown = false; var near = false; var cardAt: Date? }
    private var seen: [UUID: Seen] = [:]
    private var connecting = Set<UUID>()
    private struct PendingWrite { let data: Data; let completion: @Sendable (String?) -> Void }
    private var writes: [UUID: PendingWrite] = [:]
    private var inboxBuffers: [UUID: Data] = [:]
    private var pruning = false
    private var lastPublished: [NearbyDevice] = []
    private var lastState: NearbyBTState?

    var devicesChanged: (@Sendable ([NearbyDevice]) -> Void)?
    var stateChanged: (@Sendable (NearbyBTState) -> Void)?
    var offerReceived: (@Sendable (NearbyOffer) -> Void)?

    /// foreground: 앱이 화면에 있음 · advertise: '10분 동안 모두' · card: 근처에 보일 이름 JSON
    func update(foreground: Bool, advertise: Bool, card: Data) { queue.async { [self] in
        self.foreground = foreground; self.advertise = advertise; self.card = card
        if foreground, centralManager == nil {
            centralManager = CBCentralManager(delegate: self, queue: queue, options: [CBCentralManagerOptionShowPowerAlertKey: false])
        }
        if foreground, advertise, peripheralManager == nil {
            peripheralManager = CBPeripheralManager(delegate: self, queue: queue, options: [CBPeripheralManagerOptionShowPowerAlertKey: false])
        }
        applyCentral(); applyPeripheral(); publishState()
    } }

    /// 근처 기기의 inbox에 제안을 씁니다. completion(nil)이면 전달 성공, 아니면 안내 문구.
    func send(_ data: Data, to id: UUID, completion: @escaping @Sendable (String?) -> Void) { queue.async { [self] in
        guard let centralManager, centralManager.state == .poweredOn, let entry = seen[id] else { completion("근처에서 그 기기를 찾을 수 없습니다. 상대 아나가 열려 있는지 확인하세요."); return }
        if let previous = writes.removeValue(forKey: id) { previous.completion("다시 보내는 중입니다.") }
        writes[id] = PendingWrite(data: data, completion: completion)
        if entry.peripheral.state == .connected { entry.peripheral.discoverServices([NearbyUUID.service]) }
        else { connect(id, force: true) }
        queue.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self, self.writes[id] != nil else { return }
            self.finishWrite(id, "상대 기기가 응답하지 않습니다. 더 가까이에서 다시 시도하세요.")
            if let peripheral = self.seen[id]?.peripheral { self.centralManager?.cancelPeripheralConnection(peripheral) }
        }
    } }

    // MARK: 찾기 (central)

    private func applyCentral() {
        guard let centralManager else { return }
        if foreground, centralManager.state == .poweredOn {
            if !centralManager.isScanning {
                centralManager.scanForPeripherals(withServices: [NearbyUUID.service], options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
            }
            schedulePrune()
        } else {
            if centralManager.state == .poweredOn, centralManager.isScanning { centralManager.stopScan() }
            for entry in seen.values where entry.peripheral.state != .disconnected { centralManager.cancelPeripheralConnection(entry.peripheral) }
            for id in Array(writes.keys) { finishWrite(id, "Bluetooth를 사용할 수 없습니다.") }
            seen.removeAll(); connecting.removeAll(); publishDevices()
        }
    }
    private func schedulePrune() {
        guard !pruning else { return }
        pruning = true
        queue.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            self.pruning = false
            guard self.foreground, self.centralManager?.state == .poweredOn else { return }
            let now = Date()
            for (id, entry) in self.seen where now.timeIntervalSince(entry.last) > 25 && self.writes[id] == nil {
                if entry.peripheral.state != .disconnected { self.centralManager?.cancelPeripheralConnection(entry.peripheral) }
                self.seen.removeValue(forKey: id); self.connecting.remove(id)
            }
            self.publishDevices(); self.schedulePrune()
        }
    }
    private func publishDevices() {
        // Bluetooth 신호는 몇 dB씩 출렁이므로, 한 번 보인 기기는 -88 아래로 떨어지거나 25초 동안 신호가 없을 때만 뺍니다.
        // (처음 보이는 기준은 그대로 -78 · 최근 10초) 순서도 신호 세기가 아니라 '아주 가까움' → 이름으로 고정합니다.
        let now = Date()
        var list: [NearbyDevice] = []
        for (id, var entry) in seen {
            let age = now.timeIntervalSince(entry.last)
            // 광고가 멈추면(상대가 받기를 끄면) 8초 뒤 목록에서 뺍니다.
            let keep = entry.name != nil && (entry.shown ? (age < 8 && entry.rssi >= -88) : (age < 10 && entry.rssi >= -78))
            entry.shown = keep
            entry.near = keep && (entry.near ? entry.rssi >= -66 : entry.rssi >= -60)
            seen[id] = entry
            if keep, let name = entry.name { list.append(NearbyDevice(id: id, name: name, platform: entry.platform ?? "", rssi: Int(entry.rssi.rounded()), near: entry.near)) }
        }
        // 같은 기기가 Bluetooth 주소를 바꾸며 광고하면 두 번 보일 수 있어, 이름·기기 종류가 같으면 가장 최근 것 하나만 둡니다.
        var latest: [String: (NearbyDevice, Date)] = [:]
        for device in list {
            let key = device.name + "|" + device.platform, last = seen[device.id]?.last ?? .distantPast
            if let existing = latest[key], existing.1 >= last { continue }
            latest[key] = (device, last)
        }
        list = latest.values.map { $0.0 }
        list.sort { $0.near == $1.near ? $0.name < $1.name : $0.near }
        guard list != lastPublished else { return }
        lastPublished = list; devicesChanged?(list)
    }
    private func publishState() {
        let value: NearbyBTState
        let authorization = CBManager.authorization
        if authorization == .denied || authorization == .restricted { value = .unauthorized }
        else {
            switch centralManager?.state ?? .unknown {
            case .poweredOn: value = .on
            case .poweredOff: value = .off
            case .unsupported: value = .unsupported
            case .unauthorized: value = .unauthorized
            default: value = .unknown
            }
        }
        guard value != lastState else { return }
        lastState = value; stateChanged?(value)
    }
    private func connect(_ id: UUID, force: Bool = false) {
        guard let centralManager, var entry = seen[id] else { return }
        if !force { guard !connecting.contains(id), connecting.count < 2 else { return } }
        connecting.insert(id); entry.tried = Date(); seen[id] = entry
        entry.peripheral.delegate = self
        centralManager.connect(entry.peripheral, options: nil)
        queue.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self, self.connecting.contains(id), let current = self.seen[id], current.peripheral.state != .connected else { return }
            self.connecting.remove(id); self.centralManager?.cancelPeripheralConnection(current.peripheral)
            self.finishWrite(id, "상대 기기에 연결하지 못했습니다. 더 가까이에서 다시 시도하세요.")
        }
    }
    private func finishWrite(_ id: UUID, _ error: String?) {
        if let write = writes.removeValue(forKey: id) {
            write.completion(error)
            // 보내기에 실패한 기기(받기를 끈 기기 등)는 목록에서 바로 뺍니다. 다시 광고하면 또 보입니다.
            if error != nil, var entry = seen[id] { entry.shown = false; entry.name = nil; entry.cardAt = nil; seen[id] = entry; publishDevices() }
        }
    }
    /// 이번 연결의 일이 끝났을 때: 그 사이 보내기 제안이 생겼으면 이어서 쓰고, 아니면 연결을 끊습니다.
    private func done(_ peripheral: CBPeripheral) {
        connecting.remove(peripheral.identifier)
        if writes[peripheral.identifier] != nil, peripheral.state == .connected { peripheral.discoverServices([NearbyUUID.service]) }
        else { centralManager?.cancelPeripheralConnection(peripheral) }
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) { applyCentral(); publishState() }
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let value = RSSI.doubleValue
        guard foreground, value < 0, value > -110 else { return }
        let id = peripheral.identifier
        var entry = seen[id] ?? Seen(peripheral: peripheral, rssi: value, last: Date(), name: nil, platform: nil, tried: nil)
        entry.peripheral = peripheral; entry.rssi = entry.rssi * 0.75 + value * 0.25; entry.last = Date()
        seen[id] = entry
        // 이름은 30초마다 다시 읽어, 상대가 이름을 바꾸면 목록에도 반영합니다.
        let stale = entry.name == nil || (entry.cardAt.map { Date().timeIntervalSince($0) > 30 } ?? true)
        if stale, entry.rssi >= -78, entry.tried.map({ Date().timeIntervalSince($0) > 15 }) ?? true { connect(id) }
    }
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.delegate = self
        peripheral.discoverServices([NearbyUUID.service])
    }
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        connecting.remove(peripheral.identifier)
        finishWrite(peripheral.identifier, "상대 기기에 연결하지 못했습니다.")
    }
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        connecting.remove(peripheral.identifier)
        finishWrite(peripheral.identifier, "상대 기기와 연결이 끊겼습니다.")
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil, let service = peripheral.services?.first(where: { $0.uuid == NearbyUUID.service }) else {
            finishWrite(peripheral.identifier, "상대 기기에서 아나를 찾지 못했습니다."); done(peripheral); return
        }
        peripheral.discoverCharacteristics([NearbyUUID.card, NearbyUUID.inbox], for: service)
    }
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        let characteristics = service.characteristics ?? []
        if let write = writes[peripheral.identifier] {
            guard let inbox = characteristics.first(where: { $0.uuid == NearbyUUID.inbox }) else {
                finishWrite(peripheral.identifier, "상대 기기가 지금은 받지 않습니다."); done(peripheral); return
            }
            peripheral.writeValue(write.data, for: inbox, type: .withResponse)
        } else if let card = characteristics.first(where: { $0.uuid == NearbyUUID.card }) {
            peripheral.readValue(for: card)
        } else { done(peripheral) }
    }
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == NearbyUUID.card else { return }
        if error == nil, let data = characteristic.value, data.count <= 512, let input = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           (input["v"] as? NSNumber)?.intValue == 1, var entry = seen[peripheral.identifier] {
            entry.name = ReverseCredential.cleanName(input["name"] as? String, fallback: "아나 기기")
            entry.platform = ReverseCredential.cleanName(input["platform"] as? String, fallback: "")
            entry.cardAt = Date()
            seen[peripheral.identifier] = entry; publishDevices()
        }
        done(peripheral)
    }
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == NearbyUUID.inbox else { return }
        finishWrite(peripheral.identifier, error == nil ? nil : "상대 기기에 전달하지 못했습니다. 상대가 ‘10분 동안 모두’로 받기를 켰는지 확인하세요.")
        done(peripheral)
    }

    // MARK: 받기 광고 (peripheral)

    private func applyPeripheral() {
        guard let peripheralManager, peripheralManager.state == .poweredOn else { serviceCard = nil; return }
        if foreground && advertise {
            if serviceCard != card {
                if peripheralManager.isAdvertising { peripheralManager.stopAdvertising() }
                peripheralManager.removeAllServices()
                let cardCharacteristic = CBMutableCharacteristic(type: NearbyUUID.card, properties: [.read], value: card, permissions: [.readable])
                let inboxCharacteristic = CBMutableCharacteristic(type: NearbyUUID.inbox, properties: [.write], value: nil, permissions: [.writeable])
                let service = CBMutableService(type: NearbyUUID.service, primary: true)
                service.characteristics = [cardCharacteristic, inboxCharacteristic]
                serviceCard = card
                peripheralManager.add(service)   // 광고는 didAdd에서 시작
            } else if !peripheralManager.isAdvertising {
                startAdvertising()
            }
        } else {
            if peripheralManager.isAdvertising { peripheralManager.stopAdvertising() }
            if serviceCard != nil { peripheralManager.removeAllServices(); serviceCard = nil }
            inboxBuffers.removeAll()
        }
    }
    private func startAdvertising() {
        peripheralManager?.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [NearbyUUID.service], CBAdvertisementDataLocalNameKey: "아나"])
    }
    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) { serviceCard = nil; applyPeripheral(); publishState() }
    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        if error != nil { serviceCard = nil; return }
        if foreground && advertise && !peripheral.isAdvertising { startAdvertising() }
    }
    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) { }
    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        // card는 고정 값이라 보통 여기로 오지 않습니다.
        guard request.characteristic.uuid == NearbyUUID.card, request.offset <= card.count else { peripheral.respond(to: request, withResult: .attributeNotFound); return }
        request.value = card.subdata(in: request.offset..<card.count); peripheral.respond(to: request, withResult: .success)
    }
    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        guard let first = requests.first else { return }
        guard foreground, advertise else { peripheral.respond(to: first, withResult: .writeNotPermitted); return }
        var result = CBATTError.Code.success
        var senders: [UUID] = []
        // 긴 쓰기(512바이트까지)는 offset 순서대로 이어 붙입니다.
        for request in requests.sorted(by: { $0.offset < $1.offset }) {
            guard request.characteristic.uuid == NearbyUUID.inbox, let value = request.value else { result = .writeNotPermitted; continue }
            let key = request.central.identifier
            var buffer = request.offset == 0 ? Data() : (inboxBuffers[key] ?? Data())
            guard request.offset == buffer.count, buffer.count + value.count <= 512 else { result = .invalidAttributeValueLength; continue }
            buffer.append(value); inboxBuffers[key] = buffer
            if !senders.contains(key) { senders.append(key) }
        }
        peripheral.respond(to: first, withResult: result)
        guard result == .success else { return }
        for key in senders {
            guard let buffer = inboxBuffers[key], let offer = NearbyOffer.parse(buffer) else { continue }
            inboxBuffers.removeValue(forKey: key)
            offerReceived?(offer)
        }
    }
}
