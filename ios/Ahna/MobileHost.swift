import Foundation
import Network
import CryptoKit
import Security
import Darwin
#if canImport(UIKit)
import SwiftUI
import UIKit
#endif

/// A device that paired with this iPhone's receiver. `computerID` is that device's own receiver
/// identity when its app reports it (empty for 1.0.x apps), used to show each device once.
struct HostPeer: Sendable { let id: String; let name: String; let computerID: String; let online: Bool }

/// 아나 1.2 게스트 티켓(등록하지 않은 상대에게 한 번만 주거나 받는 권한). 메모리에만 있고 10분 뒤 사라집니다.
enum GuestKind: String, Sendable { case send, receive }
struct GuestFileInfo: Sendable, Equatable { let name: String; let bytes: Int64 }
struct GuestTicketSnapshot: Sendable, Equatable {
    let token: String
    let kind: GuestKind
    /// ready · waiting · accepted · transferring · done · declined · expired
    let state: String
    let code: String?
    let expires: Date
    let files: [GuestFileInfo]
    /// 보낸 파일 수(send) 또는 받은 파일 수(receive)
    let completed: Int
    /// receive: 웹 페이지에서 보내는 사람이 적은 이름
    let sender: String
    var total: Int64 { files.reduce(Int64(0)) { $0 + $1.bytes } }
    var finished: Bool { ["done", "declined", "expired"].contains(state) }
}
/// QR로 받기: 웹 페이지에서 보내기를 눌렀을 때 이 기기 주인에게 묻는 요청
struct GuestRequestInfo: Sendable, Equatable { let token: String; let sender: String; let files: [GuestFileInfo]; let code: String }

// Receives the existing 아나 protocol directly, or through the existing 서버 relay.
// Files are streamed to disk; authentication and pairing are independent of the client profiles.
final class MobileHTTPHost: @unchecked Sendable {
    struct Peer: Codable { var id: String; var name: String; var seen: Date; var receiver: Date; var computerID: String? = nil }
    struct Item { let id: String; let name: String; let url: URL; let target: String; let created: Date }
    struct Clip { let id: String; let text: String; let sender: String; let target: String; let created: Date }
    let queue = DispatchQueue(label: "Ahna.mobile.receiver")
    let identity: String
    let port: UInt16
    private(set) var pin = String(Int.random(in: 100000...999999))
    var name = "나의 iPhone"
    var received: (@Sendable (URL, String) -> Void)?
    var changed: (@Sendable () -> Void)?
    /// 이 기기와 연결한 기기가 자기 쪽 연결도 넘겨줬을 때(한 번의 코드 입력으로 양쪽 연결). 없으면 예전처럼 한쪽만 연결합니다.
    var reverseReceived: (@Sendable (ReverseCredential) -> Void)?
    /// 이 기기가 상대를 추가하는 동안 미리 만들어 둔 상대용 연결: 유효하지만 목록·저장에는 아직 넣지 않습니다.
    private var reserved = Set<String>()
    private var listener: NWListener?
    private var connections: [UUID: MobileHTTPRequest] = [:]
    private var peers: [String: Peer] = [:]
    private var items: [String: Item] = [:]
    private var clips: [String: Clip] = [:]
    private var attempts = 0
    private var attemptDate = Date.distantPast
    private let root: URL
    private let documents: URL
    private let key: SymmetricKey
    private var uploading = 0
    // MARK: 게스트 티켓 상태 (queue 안에서만 접근)
    private struct TicketFile { let name: String; let bytes: Int64; let url: URL? }
    private struct Ticket {
        let token: String; let kind: GuestKind; var state: String; var code: String?
        let created: Date; let expires: Date; var files: [TicketFile]
        var done = Set<Int>(); var sender = ""; var requested: Date? = nil; var activity = Date(); var closed: Date? = nil
    }
    private var tickets: [String: Ticket] = [:]
    private var ticking = false
    /// 티켓 상태가 바뀔 때마다 모든 티켓의 요약
    var ticketsChanged: (@Sendable ([GuestTicketSnapshot]) -> Void)?
    /// QR로 받기 요청이 들어왔을 때(주인의 확인 필요)
    var guestRequested: (@Sendable (GuestRequestInfo) -> Void)?
    /// 게스트가 올린 파일을 저장했을 때(받은 파일 기록·사진 저장용). 없으면 received를 씁니다.
    var guestReceived: (@Sendable (URL, String) -> Void)?
    static let ticketLifetime: TimeInterval = 600
    static let maxFile: Int64 = 4 * 1024 * 1024 * 1024
    static func secret(_ account: String, value: Data? = nil) throws -> Data? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "Ahna.MobileHost.v1", kSecAttrAccount as String: account]
        if let value {
            let attrs: [String: Any] = [kSecValueData as String: value, kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
            var code = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
            if code == errSecItemNotFound { code = SecItemAdd(query.merging(attrs) { _, new in new } as CFDictionary, nil) }
            guard code == errSecSuccess else { throw AhnaError.message("수신 인증을 저장하지 못했습니다. (\(code))") }; return value
        }
        var read = query; read[kSecReturnData as String] = true
        var result: CFTypeRef?; let code = SecItemCopyMatching(read as CFDictionary, &result)
        if code == errSecItemNotFound { return nil }
        guard code == errSecSuccess else { throw AhnaError.message("기기 잠금을 해제하고 다시 실행하세요. (\(code))") }; return result as? Data
    }
    init(directory: URL? = nil, receivingDirectory: URL? = nil, encryptionKey: Data? = nil, stableIdentity: String? = nil, port: UInt16 = 45851) throws {
        let fm = FileManager.default
        self.port = port
        root = try directory ?? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("AhnaMobileHost", isDirectory: true)
        documents = try receivingDirectory ?? fm.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        try fm.createDirectory(at: documents, withIntermediateDirectories: true)
        let raw: Data
        if let encryptionKey { raw = encryptionKey }
        else { raw = try Self.secret("encryption") ?? Data(SymmetricKey(size: .bits256).withUnsafeBytes { Array($0) }); _ = try Self.secret("encryption", value: raw) }
        key = SymmetricKey(data: raw)
        if let stableIdentity { identity = stableIdentity }
        else if let saved = try Self.secret("identity"), let value = String(data: saved, encoding: .utf8) { identity = value }
        else { identity = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(); _ = try Self.secret("identity", value: Data(identity.utf8)) }
        if fm.fileExists(atPath: root.appendingPathComponent("sessions.bin").path) {
            let sealed = try AES.GCM.SealedBox(combined: Data(contentsOf: root.appendingPathComponent("sessions.bin")))
            peers = try JSONDecoder().decode([String: Peer].self, from: AES.GCM.open(sealed, using: key)).filter { Date().timeIntervalSince($0.value.seen) < 30 * 86400 }
            for token in Array(peers.keys) { peers[token]?.receiver = .distantPast }
        }
        for file in try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) where file.lastPathComponent.hasPrefix("part-") || file.lastPathComponent.hasPrefix("queue-") { try? fm.removeItem(at: file) }
    }
    private func persist() throws {
        let data = try JSONEncoder().encode(peers.filter { !reserved.contains($0.key) })
        guard let sealed = try AES.GCM.seal(data, using: key).combined else { throw AhnaError.message("인증 저장 실패") }
        let destination = root.appendingPathComponent("sessions.bin")
        let temporary = root.appendingPathComponent("sessions-" + UUID().uuidString + ".tmp")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try sealed.write(to: temporary, options: .withoutOverwriting)
        guard rename(temporary.path, destination.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }
    func setDisplayName(_ value: String) { queue.async { self.name = value } }
    func start() { queue.async { [self] in
        guard listener == nil else { return }
        do {
            let parameters = NWParameters.tcp; parameters.allowLocalEndpointReuse = true
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: self.port)!)
            let incoming = try NWListener(using: parameters)
            listener = incoming
            incoming.newConnectionHandler = { [weak self] connection in
                guard let self else { connection.cancel(); return }
                guard self.connections.count < 8 else { connection.cancel(); return }
                let id = UUID(); let request = MobileHTTPRequest(connection: connection, host: self) { [weak self] in self?.connections.removeValue(forKey: id) }
                self.connections[id] = request; request.start(on: self.queue)
            }
            incoming.stateUpdateHandler = { [weak self] state in
                if case .failed = state { self?.listener?.cancel(); self?.listener = nil }
                self?.changed?()
            }
            incoming.start(queue: queue)
        } catch { listener = nil; changed?() }
    } }
    func stop() { queue.async { [self] in listener?.cancel(); listener = nil; for request in Array(connections.values) { request.finish() }; try? persist(); changed?() } }
    func snapshot(_ completion: @escaping @Sendable (Bool, [HostPeer], [URL], [(String, String)]) -> Void) {
        queue.async { [self] in
            prune()
            let files = ((try? FileManager.default.contentsOfDirectory(at: documents, includingPropertiesForKeys: nil)) ?? []).filter { !$0.lastPathComponent.hasPrefix(".") }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            // Every paired device (not only the ones receiving right now), so the app can merge and delete them.
            let list = peers.filter { !reserved.contains($0.key) }.values.sorted { $0.id < $1.id }.map { HostPeer(id: $0.id, name: $0.name, computerID: $0.computerID ?? "", online: Date().timeIntervalSince($0.receiver) < 40) }
            completion(listener != nil, list, files, clips.values.filter { $0.target == "host" }.map { ($0.sender, $0.text) })
        }
    }
    /// Drops these paired devices (and any other pairing of the same device identity) on this side.
    func forget(_ ids: [String], completed: @escaping @Sendable () -> Void = {}) { queue.async { [self] in
        let identities = Set(peers.values.filter { ids.contains($0.id) }.compactMap { $0.computerID }.filter { !$0.isEmpty })
        peers = peers.filter { !ids.contains($0.value.id) && !identities.contains($0.value.computerID ?? "") }
        try? persist(); changed?(); completed()
    } }
    /// 상대 기기를 추가할 때 함께 보낼 상대용 연결을 만듭니다(/api/pair와 같은 토큰 형식·만료·저장). 끝나면 completeReverse.
    func mintReverse(_ completion: @escaping @Sendable (String?) -> Void) { queue.async { [self] in
        guard peers.count < 100 else { completion(nil); return }
        let token = Self.id() + Self.id()
        peers[token] = Peer(id: Self.id(), name: "기기", seen: Date(), receiver: .distantPast, computerID: nil)
        reserved.insert(token); completion(token)
    } }
    /// 상대가 받아 저장했으면 유지하고(이름·ID 반영, 같은 기기의 예전 연결은 교체), 아니면 지웁니다.
    func completeReverse(_ token: String, accepted: Bool, name: String, computerID: String?) { queue.async { [self] in
        guard reserved.remove(token) != nil else { return }
        guard accepted, peers[token] != nil else { peers.removeValue(forKey: token); return }
        if let label = try? validatedName(ReverseCredential.cleanName(name, fallback: "기기")) { peers[token]?.name = label }
        if let reported = Self.peerIdentity(computerID) {
            peers[token]?.computerID = reported
            peers = peers.filter { $0.key == token || $0.value.computerID != reported }
        }
        try? persist(); changed?()
    } }
    static func peerIdentity(_ value: Any?) -> String? {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespaces), text.count == 32, text.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return nil }
        return text.lowercased()
    }
    func revoke(_ completed: @escaping @Sendable () -> Void = {}) { queue.async { [self] in for token in Array(tickets.keys) { closeTicket(token, state: "expired") }; peers.removeAll(); clips.removeAll(); for item in items.values { try? FileManager.default.removeItem(at: item.url) }; items.removeAll(); pin = String(Int.random(in: 100000...999999)); try? persist(); changed?(); completed() } }
    private func prune() {
        for item in Array(items.values) where Date().timeIntervalSince(item.created) >= 86400 { items.removeValue(forKey: item.id); try? FileManager.default.removeItem(at: item.url) }
        clips = clips.filter { Date().timeIntervalSince($0.value.created) < 86400 }
    }

    // MARK: - 게스트 티켓 (근처 기기 · QR)

    /// 32바이트 난수 base64url(43자)
    static func ticketToken() -> String {
        let bytes = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        return bytes.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    static func validTicketToken(_ value: String) -> Bool {
        (22...64).contains(value.count) && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }
    /// "/s/{cid}/{token}[/나머지]" → (cid, token, 나머지). 형식이 다르면 nil. 경로만(질의 없이) 넘기세요.
    static func guestParts(_ path: String) -> (cid: String, token: String, rest: String)? {
        let pieces = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard pieces.count >= 4, pieces[0].isEmpty, pieces[1] == "s", pieces[2].count == 32,
              pieces[2].allSatisfy({ $0.isASCII && $0.isHexDigit && !$0.isUppercase }), validTicketToken(pieces[3]) else { return nil }
        return (pieces[2], pieces[3], pieces.dropFirst(4).joined(separator: "/"))
    }
    /// 서버 중계가 넘겨도 되는 게스트 요청인지(MobileNASBridge.allowed와 nas/Common/Wire.cs 규약)
    static func guestAllowed(_ method: String, _ path: String) -> Bool {
        guard let parts = guestParts(path) else { return false }
        if method == "GET" {
            if ["", "info", "status"].contains(parts.rest) { return true }
            if parts.rest.hasPrefix("file/") { let n = parts.rest.dropFirst(5); return (1...3).contains(n.count) && n.allSatisfy { $0.isASCII && $0.isNumber } }
            return false
        }
        return method == "POST" && ["decline", "request", "upload"].contains(parts.rest)
    }
    private func ticketSnapshot(_ t: Ticket) -> GuestTicketSnapshot {
        GuestTicketSnapshot(token: t.token, kind: t.kind, state: t.state, code: t.code, expires: t.expires,
                            files: t.files.map { GuestFileInfo(name: $0.name, bytes: $0.bytes) }, completed: t.done.count, sender: t.sender)
    }
    private func publishTickets() { ticketsChanged?(tickets.values.sorted { $0.created < $1.created }.map(ticketSnapshot)) }
    /// 티켓을 끝냅니다: 파일·권한은 바로 지우고, 상태만 2분 동안 남겨 상대 페이지와 이 기기 화면이 결과를 볼 수 있게 합니다.
    private func closeTicket(_ token: String, state: String) {
        guard var ticket = tickets[token], ticket.closed == nil else { return }
        for file in ticket.files { if let url = file.url { try? FileManager.default.removeItem(at: url) } }
        ticket.files = ticket.files.map { TicketFile(name: $0.name, bytes: $0.bytes, url: nil) }
        ticket.state = state; ticket.closed = Date(); tickets[token] = ticket
    }
    private func pruneTickets() {
        let now = Date()
        for ticket in Array(tickets.values) {
            if let closed = ticket.closed { if now.timeIntervalSince(closed) > 120 { tickets.removeValue(forKey: ticket.token) }; continue }
            // 주인이 30초 안에 답하지 않은 받기 요청은 거절(앱 화면도 30초에 자동 거절합니다)
            if ticket.state == "waiting", let requested = ticket.requested, now.timeIntervalSince(requested) > 40 { closeTicket(ticket.token, state: "declined"); continue }
            // 만료: 전송 중이면 마지막 활동 뒤 2분까지 기다립니다.
            if now >= ticket.expires && !(ticket.state == "transferring" && now.timeIntervalSince(ticket.activity) < 120) { closeTicket(ticket.token, state: "expired") }
        }
    }
    private func scheduleTick() {
        guard !ticking, !tickets.isEmpty else { return }
        ticking = true
        queue.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            self.ticking = false
            let before = self.tickets.mapValues { $0.state }
            self.pruneTickets()
            if before != self.tickets.mapValues({ $0.state }) { self.publishTickets() }
            self.scheduleTick()
        }
    }
    /// 티켓을 만듭니다. send면 파일을 이 앱 안에 복사해 둡니다(원본 목록을 비워도 계속 보낼 수 있게). code는 2자리 숫자 또는 nil.
    func createTicket(kind: GuestKind, files: [PendingFile], code: String?, completion: @escaping @Sendable (GuestTicketSnapshot?, String?) -> Void) {
        queue.async { [self] in
            pruneTickets()
            guard tickets.values.filter({ $0.closed == nil }).count < 8 else { completion(nil, "진행 중인 공유가 너무 많습니다. 잠시 뒤 다시 시도하세요."); return }
            var copied: [TicketFile] = []
            do {
                if kind == .send {
                    guard !files.isEmpty, files.count <= 200 else { throw AhnaError.message("한 번에 200개까지 보낼 수 있습니다.") }
                    for file in files {
                        guard file.bytes >= 0, file.bytes <= Self.maxFile else { throw AhnaError.message("파일 한 개는 최대 4 GiB입니다.") }
                        let name = try Self.safeName(URL(fileURLWithPath: file.path).lastPathComponent)
                        let destination = root.appendingPathComponent("queue-guest-" + Self.id())
                        try FileManager.default.copyItem(at: file.url, to: destination)
                        let size = Int64((try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? Int(file.bytes))
                        copied.append(TicketFile(name: name, bytes: size, url: destination))
                    }
                }
            } catch {
                for file in copied { if let url = file.url { try? FileManager.default.removeItem(at: url) } }
                completion(nil, error.localizedDescription); return
            }
            let now = Date(); let token = Self.ticketToken()
            let ticket = Ticket(token: token, kind: kind, state: "ready", code: code, created: now, expires: now.addingTimeInterval(Self.ticketLifetime), files: copied)
            tickets[token] = ticket; publishTickets(); scheduleTick()
            completion(ticketSnapshot(ticket), nil)
        }
    }
    /// 이 기기에서 공유를 취소합니다(QR 창 닫기 · 보내기 취소 · 30초 무응답).
    func cancelTicket(_ token: String, state: String = "expired") { queue.async { [self] in
        guard tickets[token]?.closed == nil else { return }
        closeTicket(token, state: state); publishTickets()
    } }
    /// QR로 받기 요청에 대한 주인의 답
    func answerGuest(_ token: String, accept: Bool) { queue.async { [self] in
        guard let ticket = tickets[token], ticket.closed == nil, ticket.kind == .receive, ticket.state == "waiting" else { return }
        if accept { tickets[token]?.state = "accepted"; tickets[token]?.activity = Date() } else { closeTicket(token, state: "declined") }
        publishTickets()
    } }
    private func guestTicket(_ r: MobileHTTPRequest) -> (Ticket, String)? {
        guard let parts = Self.guestParts(r.path), parts.cid == identity, let ticket = tickets[parts.token] else { return nil }
        return (ticket, parts.rest)
    }
    /// 게스트 요청의 머리글을 받은 직후: 경로·크기를 검사하고 본문을 읽기 시작합니다. 맞지 않는 토큰은 늘 404.
    fileprivate func beginGuest(_ r: MobileHTTPRequest) throws {
        pruneTickets()
        guard Self.guestAllowed(r.method, r.path), let found = guestTicket(r) else { r.respond(404); return }
        let ticket = found.0, rest = found.1
        r.guestToken = ticket.token
        if r.method == "GET" { guard r.length == 0 else { r.respond(400); return }; r.readBody(); return }
        if rest == "upload" {
            guard ticket.closed == nil, ticket.kind == .receive, ["accepted", "transferring"].contains(ticket.state) else { r.respond(409); return }
            guard r.headers["content-length"] != nil else { r.respond(411); return }
            guard let index = Int(r.query["i"] ?? ""), ticket.files.indices.contains(index), !ticket.done.contains(index) else { r.respond(400); return }
            let name = try Self.safeName(r.query["name"] ?? "")
            guard name == ticket.files[index].name, r.length == ticket.files[index].bytes else { r.respond(400); return }
            guard uploading < 2 else { r.respond(429); return }
            let url = root.appendingPathComponent("part-" + Self.id()); try Data().write(to: url, options: .withoutOverwriting)
            r.fileName = name; r.guestIndex = index
            r.temporary = url; r.output = try FileHandle(forWritingTo: url); uploading += 1; r.uploadHeld = true; r.readBody(); return
        }
        guard r.length <= 16384 else { r.respond(413); return }; r.readBody()
    }
    fileprivate func completedGuest(_ r: MobileHTTPRequest) throws {
        pruneTickets()
        guard let found = guestTicket(r) else { r.respond(404); return }
        let ticket = found.0, rest = found.1, token = found.0.token
        let codeValue: Any = ticket.code.map { $0 as Any } ?? NSNull()
        let remaining = max(0, Int(ticket.expires.timeIntervalSinceNow.rounded(.down)))
        switch (r.method, rest) {
        case ("GET", ""):
            guard ticket.closed == nil else { r.respond(404, data: Data(GuestPage.gone.utf8), type: "text/html; charset=utf-8", extra: ["Content-Security-Policy": GuestPage.policy]); return }
            r.respond(200, data: Data(GuestPage.html.utf8), type: "text/html; charset=utf-8", extra: ["Content-Security-Policy": GuestPage.policy, "Referrer-Policy": "no-referrer"])
        case ("GET", "info"):
            r.respond(200, json: ["v": 1, "kind": ticket.kind.rawValue, "owner": name, "state": ticket.state, "expiresIn": ticket.closed == nil ? remaining : 0,
                                  "code": codeValue, "files": ticket.files.enumerated().map { ["i": $0.offset, "name": $0.element.name, "bytes": $0.element.bytes] as [String: Any] },
                                  "completed": ticket.done.count])
        case ("GET", "status"):
            r.respond(200, json: ["state": ticket.state, "code": codeValue, "expiresIn": ticket.closed == nil ? remaining : 0, "completed": ticket.done.count])
        case ("GET", let path) where path.hasPrefix("file/"):
            guard ticket.closed == nil, ticket.kind == .send, let index = Int(path.dropFirst(5)), ticket.files.indices.contains(index), let url = ticket.files[index].url else { r.respond(404); return }
            if ticket.state == "ready" { tickets[token]?.state = "transferring"; publishTickets() }
            tickets[token]?.activity = Date()
            try r.sendFile(url, name: ticket.files[index].name) { [weak self] in
                // 끝까지 보냈을 때만 셉니다. 모든 파일을 한 번 이상 보내면 완료.
                guard let self, var current = self.tickets[token], current.closed == nil else { return }
                current.done.insert(index); current.activity = Date(); self.tickets[token] = current
                if current.done.count >= current.files.count { self.closeTicket(token, state: "done") }
                self.publishTickets()
            }
        case ("POST", "decline"):
            guard ticket.closed == nil, ticket.kind == .send else { r.respond(409); return }
            closeTicket(token, state: "declined"); publishTickets(); r.respond(200, json: ["state": "declined"])
        case ("POST", "request"):
            guard ticket.closed == nil, ticket.kind == .receive, ticket.state == "ready" else { r.respond(409); return }
            let input = try JSONSerialization.jsonObject(with: r.body) as? [String: Any] ?? [:]
            let sender = ReverseCredential.cleanName(input["name"] as? String, fallback: "웹 브라우저")
            guard let list = input["files"] as? [[String: Any]], (1...200).contains(list.count) else { r.respond(400); return }
            var files: [TicketFile] = []
            for item in list {
                guard let bytes = (item["bytes"] as? NSNumber)?.int64Value, bytes >= 0, bytes <= Self.maxFile else { r.respond(400); return }
                files.append(TicketFile(name: try Self.safeName(item["name"] as? String ?? ""), bytes: bytes, url: nil))
            }
            let code = String(Int.random(in: 10...99))
            tickets[token]?.files = files; tickets[token]?.sender = sender; tickets[token]?.code = code
            tickets[token]?.state = "waiting"; tickets[token]?.requested = Date(); tickets[token]?.activity = Date()
            publishTickets()
            guestRequested?(GuestRequestInfo(token: token, sender: sender, files: files.map { GuestFileInfo(name: $0.name, bytes: $0.bytes) }, code: code))
            r.respond(200, json: ["state": "waiting", "code": code])
        case ("POST", "upload"):
            guard ticket.closed == nil, let index = r.guestIndex, !ticket.done.contains(index) else { r.respond(409); return }
            try r.output?.close(); r.output = nil
            guard let part = r.temporary else { r.respond(400); return }
            let destination = uniqueDestination(r.fileName)
            try FileManager.default.moveItem(at: part, to: destination); r.temporary = nil
            var current = ticket; current.done.insert(index); current.state = "transferring"; current.activity = Date(); tickets[token] = current
            (guestReceived ?? received)?(destination, current.sender)
            if current.done.count >= current.files.count { closeTicket(token, state: "done") }
            publishTickets(); changed?()
            r.respond(200, json: ["name": destination.lastPathComponent, "bytes": r.length, "state": tickets[token]?.state ?? "done"])
        default:
            r.respond(404)
        }
    }
    /// 같은 이름이 있으면 "이름 (1).확장자"처럼 겹치지 않는 이름을 고릅니다.
    private func uniqueDestination(_ name: String) -> URL {
        let original = documents.appendingPathComponent(name); var destination = original; var number = 1
        let ext = original.pathExtension; let base = ext.isEmpty ? name : original.deletingPathExtension().lastPathComponent
        while FileManager.default.fileExists(atPath: destination.path) {
            destination = documents.appendingPathComponent(base + " (\(number))" + (ext.isEmpty ? "" : "." + ext)); number += 1
        }
        return destination
    }
    func prepare(_ files: [PendingFile], target: String, completion: @escaping @Sendable (String) -> Void) {
        queue.async { [self] in
            do {
                prune(); guard peers.values.contains(where: { $0.id == target && Date().timeIntervalSince($0.receiver) < 40 }), items.count + files.count <= 100 else { throw AhnaError.message("받을 기기를 연결하거나 전송 대기 파일을 줄여 주세요.") }
                var count = 0
                for file in files {
                    guard file.bytes >= 0, file.bytes <= Self.maxFile else { throw AhnaError.message("파일 한 개는 최대 4 GiB입니다.") }
                    let name = try Self.safeName(URL(fileURLWithPath: file.path).lastPathComponent)
                    let id = Self.id(); let destination = root.appendingPathComponent("queue-" + id)
                    try FileManager.default.copyItem(at: file.url, to: destination)
                    items[id] = Item(id: id, name: name, url: destination, target: target, created: Date()); count += 1
                }
                completion("\(count)개 전송 준비 완료 · 상대 기기 저장 대기"); changed?()
            } catch { completion(error.localizedDescription) }
        }
    }
    func sendText(_ text: String, target: String) { queue.async { [self] in
        guard !text.isEmpty, !text.contains("\0"), text.utf8.count <= 65536, peers.values.contains(where: { $0.id == target && Date().timeIntervalSince($0.receiver) < 40 }) else { return }
        storeText(text, sender: name, target: target); changed?()
    } }
    private func storeText(_ text: String, sender: String, target: String) {
        prune(); let id = Self.id(); clips[id] = Clip(id: id, text: text, sender: sender, target: target, created: Date())
        if clips.count > 100, let first = clips.values.min(by: { $0.created < $1.created }) { clips.removeValue(forKey: first.id) }
    }
    static func id() -> String { UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() }
    static func safeName(_ raw: String) throws -> String {
        let value = raw.precomposedStringWithCanonicalMapping
        guard !value.isEmpty, value.utf16.count <= 240, value != ".", value != "..", !value.hasSuffix("."), !value.hasSuffix(" "), value.rangeOfCharacter(from: CharacterSet(charactersIn: "\\/:*?\"<>|").union(.controlCharacters)) == nil else { throw AhnaError.message("올바르지 않은 파일 이름입니다.") }; return value
    }
    fileprivate func authorize(_ request: MobileHTTPRequest) -> Peer? {
        let token = (request.headers["cookie"] ?? "").split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }.first { $0.hasPrefix("ahna=") }.map { String($0.dropFirst(5)) } ?? ""
        guard var peer = peers[token], Date().timeIntervalSince(peer.seen) < 30 * 86400 else { return nil }
        peer.seen = Date(); peers[token] = peer; request.token = token; return peer
    }
    fileprivate func begin(_ r: MobileHTTPRequest) throws {
        guard r.headers["origin"] == nil, r.headers["transfer-encoding"] == nil, r.headers["sec-fetch-site"] != "cross-site" else { r.respond(403); return }
        let host = (r.headers["host"] ?? "").split(separator: ":").first.map(String.init) ?? ""
        guard host == "localhost" || host.split(separator: ".").count == 4 && host.allSatisfy({ $0.isNumber || $0 == "." }) else { r.respond(400); return }
        guard r.length >= 0, r.length <= Self.maxFile else { r.respond(413); return }
        guard r.method == "POST" || r.length == 0 else { r.respond(400); return }
        // 게스트 경로(/s/…): 인증 쿠키 없이 1회용 토큰이 권한입니다.
        if r.path.hasPrefix("/s/") { try beginGuest(r); return }
        if r.path == "/api/pair", r.method == "POST" {
            if Date().timeIntervalSince(attemptDate) > 60 { attempts = 0; attemptDate = Date() }; attempts += 1
            guard attempts <= 60, peers.count < 100 else { r.respond(429); return }
            guard r.length <= 16384 else { r.respond(413); return }; r.readBody(); return
        }
        guard let peer = authorize(r) else { r.respond(401); return }; r.peer = peer
        if r.path == "/api/upload", r.method == "POST" {
            guard r.headers["content-length"] != nil else { r.respond(411); return }
            guard UUID(uuidString: r.query["batch"] ?? "") != nil else { r.respond(400); return }
            if r.query["kind"] == "clipboard" { guard r.length <= 65536 else { r.respond(413); return }; r.readBody(); return }
            let parts = (r.query["path"] ?? "").replacingOccurrences(of: "\\", with: "/").components(separatedBy: "/")
            for part in parts { _ = try Self.safeName(part) }; r.fileName = try Self.safeName(parts.last ?? "")
            guard uploading < 2 else { r.respond(429); return }
            let url = root.appendingPathComponent("part-" + Self.id()); try Data().write(to: url, options: .withoutOverwriting)
            r.temporary = url; r.output = try FileHandle(forWritingTo: url); uploading += 1; r.uploadHeld = true; r.readBody(); return
        }
        guard r.length <= 16384 else { r.respond(413); return }; r.readBody()
    }
    fileprivate func completed(_ r: MobileHTTPRequest) throws {
        if r.guestToken != nil { try completedGuest(r); return }
        if r.path == "/api/pair", r.method == "POST" {
            let input = try JSONSerialization.jsonObject(with: r.body) as? [String: Any] ?? [:]
            guard input["pin"] as? String == pin else { r.respond(401); return }
            let label = try validatedName(input["name"] as? String ?? "기기")
            let token = Self.id() + Self.id(); let reported = Self.peerIdentity(input["computerID"])
            let peer = Peer(id: Self.id(), name: label, seen: Date(), receiver: input["canReceive"] as? Bool == false ? .distantPast : Date(), computerID: reported)
            // Pairing again from the same device replaces its earlier pairing, so it is listed once.
            if let reported { peers = peers.filter { $0.value.computerID != reported } }
            peers[token] = peer; try persist()
            // 상대가 자기 쪽 연결도 넘겨줬으면 이 기기에서도 그 기기를 추가한 것으로 저장합니다(예전 앱은 보내지 않음).
            var reverse = false
            if input["native"] as? Bool == true, let accept = reverseReceived, let credential = ReverseCredential.validated(input["reverse"]), credential.computerID != identity {
                accept(credential); reverse = true
            }
            r.respond(200, json: ["id": peer.id, "name": label, "computerID": identity, "reverse": reverse], extra: ["Set-Cookie": "ahna=\(token); Path=/; HttpOnly; SameSite=Strict; Max-Age=2592000"]); changed?(); return
        }
        guard let peer = r.peer else { r.respond(401); return }
        if r.path == "/api/state", r.method == "GET" {
            if let value = r.query["deviceName"] { peers[r.token]?.name = try validatedName(value); try persist() }
            if let reported = Self.peerIdentity(r.query["computerID"]), peers[r.token]?.computerID != reported { peers[r.token]?.computerID = reported; try persist() }
            if r.query["receiving"] == nil || r.query["receiving"] == "true" { peers[r.token]?.receiver = Date() }
            prune()
            let files: [[String: Any]] = items.values.filter { $0.target == peer.id }.map { ["id": $0.id, "name": $0.name, "bytes": (try? $0.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0, "target": $0.target] }
            let texts: [[String: Any]] = clips.values.filter { $0.target == peer.id }.map { ["id": $0.id, "sender": $0.sender, "bytes": $0.text.utf8.count, "created": ISO8601DateFormatter().string(from: $0.created)] }
            r.respond(200, json: ["id": peer.id, "name": peers[r.token]?.name ?? peer.name, "hostName": name, "platform": "iOS", "computerID": identity, "owner": false, "items": files, "clipboard": texts, "devices": [], "history": [], "maxFile": Self.maxFile, "maxClipboardBytes": 65536]); changed?(); return
        }
        if r.path == "/api/logout", r.method == "POST" { peers.removeValue(forKey: r.token); try persist(); r.respond(200); return }
        if r.path == "/api/upload", r.method == "POST" {
            if r.query["kind"] == "clipboard" {
                guard let text = String(data: r.body, encoding: .utf8), !text.isEmpty, !text.contains("\0"), text.utf8.count <= 65536 else { r.respond(400); return }
                storeText(text, sender: peer.name, target: "host"); r.respond(200, json: ["id": Self.id()]); changed?(); return
            }
            try r.output?.close(); r.output = nil
            guard let part = r.temporary else { r.respond(400); return }
            let original = documents.appendingPathComponent(r.fileName); var destination = original; var number = 1
            while FileManager.default.fileExists(atPath: destination.path) { destination = original.deletingPathExtension().appendingPathExtension("\(number)." + original.pathExtension); number += 1 }
            try FileManager.default.moveItem(at: part, to: destination); r.temporary = nil
            received?(destination, peer.name)
            r.respond(200, json: ["name": destination.lastPathComponent, "bytes": r.length]); changed?(); return
        }
        if r.path.hasPrefix("/api/download/"), r.method == "GET" {
            let id = String(r.path.dropFirst(14)); prune()
            if r.query["kind"] == "clipboard" {
                guard let clip = clips[id], clip.target == peer.id else { r.respond(404); return }; r.respond(200, data: Data(clip.text.utf8)); return
            }
            guard let item = items[id], item.target == peer.id else { r.respond(404); return }; try r.sendFile(item.url); return
        }
        if r.path.hasPrefix("/api/received/"), r.method == "POST" {
            guard let item = items[String(r.path.dropFirst(14))], item.target == peer.id, r.body.count <= 4096 else { r.respond(404); return }
            let input = try JSONSerialization.jsonObject(with: r.body) as? [String: String] ?? [:]
            guard ["files", "photos"].contains(input["destination"] ?? "") else { r.respond(400); return }; r.respond(200); return
        }
        r.respond(404)
    }
    private func validatedName(_ raw: String) throws -> String {
        let label = raw.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
        guard !label.isEmpty, label.utf16.count <= 40, label.rangeOfCharacter(from: .controlCharacters) == nil else { throw AhnaError.message("기기 이름은 1~40자로 입력하세요.") }; return label
    }
    fileprivate func released(_ r: MobileHTTPRequest) { if r.uploadHeld { uploading -= 1; r.uploadHeld = false } }
}

private final class MobileHTTPRequest {
    let connection: NWConnection
    unowned let host: MobileHTTPHost
    let ended: () -> Void
    var headers: [String: String] = [:], query: [String: String] = [:]
    var method = "", path = "", token = "", fileName = ""
    var length: Int64 = 0, read: Int64 = 0
    var body = Data(), pending = Data()
    var peer: MobileHTTPHost.Peer?
    var temporary: URL?
    var output: FileHandle?
    var uploadHeld = false
    /// 게스트 요청(/s/…)이면 그 티켓 토큰과 올리는 파일 번호
    var guestToken: String?
    var guestIndex: Int?
    /// sendFile로 파일 끝까지 보냈을 때 한 번 부릅니다.
    private var streamed: (() -> Void)?
    private var headerRead = false, finished = false, responded = false
    private var timer: DispatchWorkItem?
    init(connection: NWConnection, host: MobileHTTPHost, ended: @escaping () -> Void) { self.connection = connection; self.host = host; self.ended = ended }
    func start(on queue: DispatchQueue) { connection.start(queue: queue); connection.stateUpdateHandler = { [weak self] state in if case .failed = state { self?.finish() } }; receive() }
    private func receive() {
        timer?.cancel(); let work = DispatchWorkItem { [weak self] in self?.finish() }; timer = work; host.queue.asyncAfter(deadline: .now() + (headerRead ? 60 : 15), execute: work)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            guard let self, !self.finished else { return }; self.timer?.cancel()
            if let data { self.pending.append(data) }
            do {
                if !self.headerRead {
                    guard let range = self.pending.range(of: Data("\r\n\r\n".utf8)) else { if self.pending.count > 32768 || complete || error != nil { self.finish() } else { self.receive() }; return }
                    guard range.lowerBound <= 32768, let header = String(data: self.pending[..<range.lowerBound], encoding: .ascii) else { self.respond(400); return }
                    self.pending.removeSubrange(..<range.upperBound)
                    let lines = header.components(separatedBy: "\r\n"); let first = lines[0].components(separatedBy: " ")
                    guard first.count == 3, first[1].hasPrefix("/"), !first[1].hasPrefix("//"), !first[1].contains("#"), let parts = URLComponents(string: first[1]) else { self.respond(400); return }
                    self.method = first[0]; self.path = parts.path
                    for item in parts.queryItems ?? [] { guard self.query[item.name] == nil else { self.respond(400); return }; self.query[item.name] = item.value ?? "" }
                    for line in lines.dropFirst() { guard let colon = line.firstIndex(of: ":") else { self.respond(400); return }; let key = line[..<colon].lowercased(); guard self.headers[key] == nil else { self.respond(400); return }; self.headers[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces) }
                    guard let size = Int64(self.headers["content-length"] ?? "0") else { self.respond(400); return }; self.length = size; self.headerRead = true
                    try self.host.begin(self)
                } else { self.readBody() }
            } catch { self.respond(400) }
            if (complete || error != nil) && !self.responded { self.finish() }
        }
    }
    func readBody() {
        guard !responded, !finished else { return }
        do {
            let count = Int(min(Int64(pending.count), length - read))
            if count > 0 { let data = pending.prefix(count); if let output { try output.write(contentsOf: data) } else { body.append(data) }; pending.removeFirst(count); read += Int64(count) }
            if read == length { guard pending.isEmpty else { respond(400); return }; try host.completed(self) } else { receive() }
        } catch { respond(500) }
    }
    func respond(_ status: Int, json: [String: Any]? = nil, data: Data = Data(), type: String = "application/json; charset=utf-8", extra: [String: String] = [:]) {
        guard !responded, !finished else { return }; responded = true; timer?.cancel()
        let bytes = json.flatMap { try? JSONSerialization.data(withJSONObject: $0) } ?? data
        var header = "HTTP/1.1 \(status) 아나\r\nContent-Length: \(bytes.count)\r\nContent-Type: \(type)\r\nConnection: close\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nX-Ahna-Computer: \(host.identity)\r\n"
        for (key, value) in extra { header += "\(key): \(value)\r\n" }; header += "\r\n"
        connection.send(content: Data(header.utf8) + bytes, completion: .contentProcessed { [weak self] _ in self?.finish() })
    }
    /// name을 주면 브라우저가 그 이름으로 저장하도록 Content-Disposition을 붙입니다. done은 끝까지 보냈을 때만 불립니다.
    func sendFile(_ url: URL, name: String? = nil, done: (() -> Void)? = nil) throws {
        let file = try FileHandle(forReadingFrom: url); let size = try file.seekToEnd(); try file.seek(toOffset: 0)
        guard size <= UInt64(MobileHTTPHost.maxFile) else { try file.close(); respond(413); return }
        responded = true; streamed = done
        var disposition = ""
        if let name {
            let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789!#$&+-.^_`|~")
            disposition = "Content-Disposition: attachment; filename*=UTF-8''" + (name.addingPercentEncoding(withAllowedCharacters: allowed) ?? "file") + "\r\n"
        }
        let header = Data("HTTP/1.1 200 OK\r\nContent-Length: \(size)\r\nContent-Type: application/octet-stream\r\n\(disposition)Connection: close\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nX-Ahna-Computer: \(host.identity)\r\n\r\n".utf8)
        connection.send(content: header, completion: .contentProcessed { [weak self] error in guard let self else { try? file.close(); return }; if error != nil { try? file.close(); self.finish() } else { self.stream(file, left: size) } })
    }
    private func stream(_ file: FileHandle, left: UInt64) {
        do {
            guard !finished, left > 0 else {
                try file.close()
                if !finished, left == 0, let streamed { self.streamed = nil; streamed() }
                finish(); return
            }
            guard let bytes = try file.read(upToCount: Int(min(left, 65536))), !bytes.isEmpty else { try file.close(); finish(); return }
            connection.send(content: bytes, completion: .contentProcessed { [weak self] error in guard let self else { try? file.close(); return }; if error != nil { try? file.close(); self.finish() } else { self.stream(file, left: left - UInt64(bytes.count)) } })
        } catch { try? file.close(); finish() }
    }
    func finish() {
        guard !finished else { return }; finished = true; timer?.cancel(); try? output?.close(); output = nil
        if let temporary { try? FileManager.default.removeItem(at: temporary) }; host.released(self); connection.cancel(); ended()
    }
}

#if canImport(UIKit)
@MainActor final class MobileHostModel: ObservableObject {
    @Published var peers: [HostPeer] = []
    @Published var files: [URL] = []
    @Published var clips: [(String, String)] = []
    @Published var status = "서버 수신 준비 중…"
    @Published var active = false
    @Published var remoteStatus = "서버 설정이 필요합니다."
    @Published var nasAddress = Brand.ahna ? Brand.server : UserDefaults.standard.string(forKey: "mobileNasURL") ?? ""
    @Published var nasKey = ""
    private(set) var engine: MobileHTTPHost?
    private var relay: MobileNASBridge?
    private var foreground = true
    var pin: String { engine?.pin ?? "" }
    var addresses: [String] {
        var result: [String] = []; var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let head else { return [] }; defer { freeifaddrs(head) }
        for pointer in sequence(first: head, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_INET), entry.ifa_flags & UInt32(IFF_LOOPBACK) == 0, entry.ifa_flags & UInt32(IFF_UP) != 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 { result.append("http://\(String(cString: host)):45851") }
        }; return result
    }
    init() {
        do { let host = try MobileHTTPHost(); host.name = DeviceIdentity.savedName; engine = host
            host.received = { url, source in Task { @MainActor in ReceiveHistory.shared.record(id: url.path, url: url, source: source) } }
            host.changed = { [weak self] in Task { @MainActor in self?.refresh() } }
            host.reverseReceived = { [weak self] credential in Task { @MainActor in self?.reverseReceived?(credential) } }
            host.ticketsChanged = { [weak self] list in Task { @MainActor in
                guard let self else { return }
                var map: [String: GuestTicketSnapshot] = [:]; for ticket in list { map[ticket.token] = ticket }
                if self.tickets != map { self.tickets = map }
            } }
            host.guestRequested = { [weak self] request in Task { @MainActor in self?.guestRequested?(request) } }
            host.guestReceived = { url, source in Task { @MainActor in
                // QR로 받은 파일도 평소 수신처럼: 받은 파일 기록 + (설정이 켜져 있으면) 사진 앱에도 저장
                ReceiveHistory.shared.record(id: url.path, url: url, source: source)
                let photos = UserDefaults.standard.object(forKey: "savePhotosToLibrary") as? Bool ?? true
                if photos, PhotoLibrarySaver.isMedia(url) { try? await PhotoLibrarySaver.save(url) }
            } }
        } catch { status = error.localizedDescription }
    }
    // MARK: 게스트 티켓 (근처 기기 · QR)
    /// 이 기기가 만든 공유 티켓들(토큰별). 화면은 이것으로 수락 대기·진행·완료를 봅니다.
    @Published var tickets: [String: GuestTicketSnapshot] = [:]
    /// QR로 받기에서 상대가 [보내기]를 눌렀을 때(확인 창을 띄움)
    var guestRequested: (@MainActor (GuestRequestInfo) -> Void)?
    /// 근처 기기·QR 공유는 상대가 이 기기 서버 주소로 받아 가므로 서버 수신이 연결돼 있어야 합니다.
    var guestReady: Bool { foreground && remoteStatus.contains("연결됨") && guestOrigin != nil }
    private var guestOrigin: String? { UserDefaults.standard.bool(forKey: "mobileNasEnabled") ? ReverseCredential.nasOrigin(nasAddress) : nil }
    /// 게스트 URL: https://<서버>/s/<이 기기 ID>/<토큰>
    func guestURL(_ token: String) -> String? {
        guard let origin = guestOrigin, let engine else { return nil }
        return origin + "/s/" + engine.identity + "/" + token
    }
    func createTicket(kind: GuestKind, files: [PendingFile], code: String?) async throws -> GuestTicketSnapshot {
        guard guestReady else { throw AhnaError.message("서버 설정이 필요합니다. 옵션 › 서버에서 이 기기가 서버로 받기를 연결하세요.") }
        guard let engine else { throw AhnaError.message(status) }
        let result: (GuestTicketSnapshot?, String?) = await withCheckedContinuation { continuation in
            engine.createTicket(kind: kind, files: files, code: code) { ticket, error in continuation.resume(returning: (ticket, error)) }
        }
        guard let ticket = result.0 else { throw AhnaError.message(result.1 ?? "공유를 준비하지 못했습니다.") }
        tickets[ticket.token] = ticket
        return ticket
    }
    func cancelTicket(_ token: String, state: String = "expired") { engine?.cancelTicket(token, state: state) }
    func answerGuest(_ token: String, accept: Bool) { engine?.answerGuest(token, accept: accept) }
    func start() { foreground = true; engine?.start(); connectNAS(); refresh() }
    func stop() { foreground = false; relay?.stop(); relay = nil; engine?.stop(); active = false; remoteStatus = "앱을 다시 열면 서버에 연결됩니다." }
    func refresh() { engine?.snapshot { [weak self] running, peers, files, clips in Task { @MainActor in
        guard let self else { return }; self.active = running; self.peers = peers; self.files = files; self.clips = clips; self.status = running ? "연결을 받을 수 있습니다." : "서버 수신 준비 중…"
    } } }
    /// 상대 기기가 이 기기와 연결하면서 넘겨준 그 기기 쪽 연결. 본체 앱이 추가한 기기로 저장합니다.
    var reverseReceived: (@MainActor (ReverseCredential) -> Void)?
    /// 연결 코드로 기기를 추가할 때 함께 보낼 이 기기 쪽 연결. 서버 수신이 꺼져 있으면 nil(예전처럼 한쪽만 연결).
    func reverseOffer() async -> ReverseCredential? {
        guard UserDefaults.standard.bool(forKey: "mobileNasEnabled"), let address = ReverseCredential.nasOrigin(nasAddress), let engine else { return nil }
        let token: String? = await withCheckedContinuation { continuation in engine.mintReverse { continuation.resume(returning: $0) } }
        guard let token else { return nil }
        return ReverseCredential(address: address, computerID: engine.identity, token: token, name: ReverseCredential.cleanName(DeviceIdentity.savedName, fallback: "iPhone"))
    }
    func reverseComplete(token: String, accepted: Bool, name: String, computerID: String?) {
        engine?.completeReverse(token, accepted: accepted, name: name, computerID: computerID)
    }
    func forget(_ ids: [String]) { engine?.forget(ids) { [weak self] in Task { @MainActor in self?.refresh() } } }
    func send(_ files: [PendingFile], target: String, completion: @escaping () -> Void) {
        engine?.prepare(files, target: target) { [weak self] result in Task { @MainActor in self?.status = result; completion() } }
    }
    /// 아나: 아직 서버에 가입하지 않았으면 첫 화면에서 초대 코드를 묻습니다.
    @Published var needsJoin = Brand.ahna && !Brand.isMemberToken(String(decoding: (try? MobileHTTPHost.secret("nas-key")) ?? Data(), as: UTF8.self))
    @Published var joining = false
    /// 아나 서버 가입: 초대 코드 → 이 기기 전용 토큰. 토큰은 키체인에 저장하고 바로 서버에 연결합니다.
    func join(invite: String) async {
        let code = invite.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty, let engine, let url = URL(string: Brand.server + "/_ahna/join") else { return }
        joining = true; defer { joining = false }
        var request = URLRequest(url: url); request.httpMethod = "POST"; request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["invite": code, "computer": engine.identity, "name": engine.name, "platform": UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"])
        do {
            let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            if status == 404 { remoteStatus = "서버에 초대 코드가 설정되지 않았습니다. 서버 관리자에게 알려 주세요."; return }
            if status == 429 { remoteStatus = "초대 코드를 너무 많이 시도했습니다. 10분 뒤에 다시 시도하세요."; return }
            guard status == 200, let token = body?["token"] as? String, Brand.isMemberToken(token) else { remoteStatus = (body?["error"] as? String) ?? "연결하지 못했습니다 (\(status))."; return }
            nasAddress = Brand.server; nasKey = token; configureNAS(); needsJoin = false
        } catch { remoteStatus = "서버에 연결하지 못했습니다. 인터넷 연결을 확인하세요." }
    }
    func configureNAS() {
        relay?.stop(); relay = nil
        do {
            let key = nasKey.isEmpty ? String(data: try MobileHTTPHost.secret("nas-key") ?? Data(), encoding: .utf8) ?? "" : nasKey
            try MobileNASBridge.validate(nasAddress, key: key)
            _ = try MobileHTTPHost.secret("nas-key", value: Data(key.utf8)); UserDefaults.standard.set(nasAddress, forKey: "mobileNasURL"); UserDefaults.standard.set(true, forKey: "mobileNasEnabled"); nasKey = ""; connectNAS()
        } catch { remoteStatus = error.localizedDescription }
    }
    func connectNAS() {
        guard foreground, let engine, relay == nil else { return }
        do { let key = String(data: try MobileHTTPHost.secret("nas-key") ?? Data(), encoding: .utf8) ?? ""
            // 공유 메뉴가 근처 기기로 보낼 때 쓰도록 가입 토큰을 공통 설정에도 둡니다.
            if Brand.isMemberToken(key) { try? ComputerVault.saveMemberToken(key) }
            relay = try MobileNASBridge(host: engine, address: nasAddress, key: key) { [weak self] value in Task { @MainActor in self?.remoteStatus = value } }
            relay?.platform = UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
            relay?.notice = { [weak self] action, text in Task { @MainActor in self?.serverNotice(action, text) } }
            relay?.connected = { [weak self] in Task { @MainActor in await self?.refreshNotices() } }
            relay?.start()
        } catch { remoteStatus = error.localizedDescription }
    }
    /// 서버 관리자 알림. 초기화·차단이면 연결 키를 지우고 초대 코드 화면을 띄웁니다.
    @Published var noticeText: String?
    func serverNotice(_ action: String, _ text: String) {
        if action == "notices" { Task { await refreshNotices() }; return }
        noticeText = text
        if action == "rejoin" || action == "blocked" {
            relay?.stop(); relay = nil
            _ = try? MobileHTTPHost.secret("nas-key", value: Data()); UserDefaults.standard.set(false, forKey: "mobileNasEnabled")
            remoteStatus = text; needsJoin = true
        }
    }
    // MARK: 서버 관리자 공지
    // 서버에 연결할 때마다 받아 오고, 읽음·삭제는 이 기기에 저장합니다. 읽은 공지는 3일 뒤 보이지 않습니다.
    struct Announcement: Identifiable, Equatable { let id: String; let text: String; let created: Date; let read: Bool }
    @Published private(set) var announcements: [Announcement] = []
    @Published var showNotices = false
    var unreadNotices: Int { announcements.filter { !$0.read }.count }
    private var serverNotices: [(id: String, text: String, created: Date)] = []
    private var poppedNotices = Set<String>()
    private var noticeRead: [String: Double] {
        get { UserDefaults.standard.dictionary(forKey: "noticeRead") as? [String: Double] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "noticeRead") }
    }
    private var noticeDeleted: [String] {
        get { UserDefaults.standard.stringArray(forKey: "noticeDeleted") ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: "noticeDeleted") }
    }
    private func noticeRequest(_ path: String, _ method: String) -> URLRequest? {
        let key = String(decoding: (try? MobileHTTPHost.secret("nas-key")) ?? Data(), as: UTF8.self)
        guard Brand.isMemberToken(key), let url = URL(string: Brand.server + path) else { return nil }
        var request = URLRequest(url: url); request.httpMethod = method; request.timeoutInterval = 20
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization"); return request
    }
    private func applyNotices() {
        let read = noticeRead, deleted = Set(noticeDeleted), now = Date().timeIntervalSince1970
        let next = serverNotices.filter { !deleted.contains($0.id) && !(read[$0.id].map { now - $0 > 3 * 86400 } ?? false) }
            .map { Announcement(id: $0.id, text: $0.text, created: $0.created, read: read[$0.id] != nil) }
        if next != announcements { announcements = next }
        if next.isEmpty { showNotices = false }
    }
    func refreshNotices() async {
        guard let request = noticeRequest("/_ahna/notices", "GET") else { return }
        guard let (data, response) = try? await URLSession(configuration: .ephemeral).data(for: request), (response as? HTTPURLResponse)?.statusCode == 200,
              let list = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["notices"] as? [[String: Any]] else { return }
        serverNotices = list.prefix(30).compactMap { item in
            guard let id = item["id"] as? String, let text = item["text"] as? String, !id.isEmpty, !text.isEmpty else { return nil }
            return (id, text, Date(timeIntervalSince1970: (item["created"] as? NSNumber)?.doubleValue ?? Date().timeIntervalSince1970))
        }
        // 서버에서 지운 공지의 기록은 정리
        let ids = Set(serverNotices.map(\.id))
        noticeRead = noticeRead.filter { ids.contains($0.key) }; noticeDeleted = noticeDeleted.filter { ids.contains($0) }
        applyNotices()
        // 읽지 않은 새 공지는 한 번 저절로 띄웁니다.
        let fresh = announcements.filter { !$0.read && !poppedNotices.contains($0.id) }
        if !fresh.isEmpty { fresh.forEach { poppedNotices.insert($0.id) }; showNotices = true }
    }
    func readNotice(_ id: String) {
        var read = noticeRead; guard read[id] == nil else { return }
        read[id] = Date().timeIntervalSince1970; noticeRead = read; applyNotices()
        if let request = noticeRequest("/_ahna/notices/\(id)/read", "POST") { Task { _ = try? await URLSession(configuration: .ephemeral).data(for: request) } }
    }
    func deleteNotice(_ id: String) { guard noticeRead[id] != nil else { return }; noticeDeleted = Array(Set(noticeDeleted + [id])); applyNotices() }
    func disableNAS() { UserDefaults.standard.set(false, forKey: "mobileNasEnabled"); relay?.stop(); relay = nil; remoteStatus = "서버 설정이 필요합니다." }
    func revoke() { relay?.stop(); relay = nil; engine?.revoke { [weak self] in Task { @MainActor in if UserDefaults.standard.bool(forKey: "mobileNasEnabled") { self?.connectNAS() } } } }
}
#endif
