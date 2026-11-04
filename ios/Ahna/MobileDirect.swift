import Foundation
import Network
import Security

/// 같은 네트워크 직접 받기: 공유기 안에서 들어오는 직접 연결(DirectLink.swift 형식)을 받아
/// 이 기기의 아나(127.0.0.1)로 넘깁니다. Windows·Mac은 src/DirectChannel.cs 의 DirectHost가 같은 일을 합니다.
final class MobileDirectHost: @unchecked Sendable {
    static let port: UInt16 = 45853
    private final class Key {
        let id: String; let secret: Data; let token: String; let created: Date
        /// 이미 쓴 salt: 같은 연결 내용을 다시 보내는(재전송) 것을 막습니다.
        var seen = Set<Data>()
        init(id: String, secret: Data, token: String, created: Date) { self.id = id; self.secret = secret; self.token = token; self.created = created }
    }
    private let lock = NSLock()
    private var keys: [String: Key] = [:]
    private var byToken: [String: String] = [:]
    private var listening = false
    private var active = 0
    private var listener: NWListener?
    private let localPort: UInt16
    private let queue = DispatchQueue(label: "Ahna.direct.host")
    private let session: URLSession

    init(localPort: UInt16) {
        self.localPort = localPort
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 45 * 60
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.connectionProxyDictionary = [:]
        session = URLSession(configuration: config)
    }

    func start() {
        queue.async { [self] in
            guard listener == nil else { return }
            do {
                let parameters = NWParameters.tcp
                parameters.allowLocalEndpointReuse = true
                let incoming = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: Self.port)!)
                incoming.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
                incoming.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    switch state {
                    case .ready: self.setListening(true)
                    case .failed, .cancelled:
                        self.setListening(false)
                        self.queue.async { if self.listener === incoming { self.listener?.cancel(); self.listener = nil } }
                    default: break
                    }
                }
                listener = incoming
                incoming.start(queue: queue)
            } catch { listener = nil; setListening(false) }
        }
    }

    func stop() { queue.async { [self] in listener?.cancel(); listener = nil; setListening(false) } }

    private func setListening(_ value: Bool) { lock.lock(); listening = value; lock.unlock() }

    /// /api/state?direct=1 응답에 넣을 값. 같은 세션이면 30분 동안 같은 키(1시간 뒤 만료).
    func offer(token: String) -> [String: Any]? {
        guard !token.isEmpty else { return nil }
        let addrs = Self.addresses()
        lock.lock(); defer { lock.unlock() }
        guard listening, !addrs.isEmpty else { return nil }
        let now = Date()
        for (id, key) in keys where now.timeIntervalSince(key.created) > 3600 {
            keys[id] = nil
            if byToken[key.token] == id { byToken[key.token] = nil }
        }
        let key: Key
        if let id = byToken[token], let existing = keys[id], now.timeIntervalSince(existing.created) < 1800 { key = existing }
        else {
            guard keys.count < 1000 else { return nil }
            key = Key(id: Self.hex(Self.random(16)), secret: Self.random(32), token: token, created: now)
            keys[key.id] = key; byToken[token] = key.id
        }
        return ["id": key.id, "key": key.secret.base64EncodedString(), "port": Int(Self.port), "addrs": addrs]
    }

    /// 키를 찾고, 이 salt가 처음이면 기록합니다(재전송이면 nil).
    private func lookup(_ id: String, salt: Data) -> Key? {
        lock.lock(); defer { lock.unlock() }
        guard let key = keys[id], Date().timeIntervalSince(key.created) < 3600, key.seen.count < 20000, key.seen.insert(salt).inserted else { return nil }
        return key
    }

    private func accept(_ connection: NWConnection) {
        lock.lock(); let ok = active < 8; if ok { active += 1 }; lock.unlock()
        guard ok else { connection.cancel(); return }
        connection.start(queue: queue)
        let link = DirectLink.Link(connection)
        Task {
            defer { link.close(); self.lock.lock(); self.active -= 1; self.lock.unlock() }
            try? await self.serve(link)
        }
    }

    private static func allowed(method: String, path: String, length: Int64) -> Bool {
        guard path.count <= 4096, path.hasPrefix("/api/"), !path.contains("#"), !path.contains("\\"), !path.contains("//") else { return false }
        let route = path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path
        if method == "GET" { return length == 0 && (route == "/api/state" || route.hasPrefix("/api/download/")) }
        guard method == "POST", length >= 0 else { return false }
        if route == "/api/upload" { return length <= MobileHTTPHost.maxFile }
        return route.hasPrefix("/api/received/") && length <= 16384
    }

    private func serve(_ link: DirectLink.Link) async throws {
        // 15초 안에 요청 머리가 오지 않으면 끊습니다.
        let watchdog = DispatchWorkItem { link.close() }
        queue.asyncAfter(deadline: .now() + 15, execute: watchdog)
        let hello = try await link.receive(40)
        guard hello.prefix(8) == DirectLink.magic else { return }
        let id = Self.hex(hello.subdata(in: 8..<24))
        let salt = hello.subdata(in: 24..<40)
        guard let key = lookup(id, salt: salt) else { return }
        let inbound = DirectLink.Cipher(secret: key.secret, label: "c2s", salt: salt)
        let outbound = DirectLink.Cipher(secret: key.secret, label: "s2c", salt: salt)
        guard let head = try JSONSerialization.jsonObject(with: try await link.readRecord(inbound)) as? [String: Any],
              let method = head["m"] as? String, let path = head["p"] as? String,
              let length = (head["l"] as? NSNumber)?.int64Value else { return }
        watchdog.cancel()
        guard Self.allowed(method: method, path: path, length: length), let url = URL(string: "http://127.0.0.1:\(localPort)" + path) else {
            try await respond(link, outbound, status: 400, data: Data()); return
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("ahna=" + key.token, forHTTPHeaderField: "Cookie")
        if method == "POST" {
            if let type = head["t"] as? String, !type.isEmpty { request.setValue(type, forHTTPHeaderField: "Content-Type") }
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("ahna-direct-in-" + UUID().uuidString)
            guard FileManager.default.createFile(atPath: temporary.path, contents: nil) else { return }
            defer { try? FileManager.default.removeItem(at: temporary) }
            do {
                let handle = try FileHandle(forWritingTo: temporary); defer { try? handle.close() }
                var got: Int64 = 0
                while got < length {
                    let piece = try await link.readRecord(inbound)
                    guard !piece.isEmpty, got + Int64(piece.count) <= length else { return }
                    try handle.write(contentsOf: piece)
                    got += Int64(piece.count)
                }
            }
            request.setValue(String(length), forHTTPHeaderField: "Content-Length")
            let (data, response) = try await session.upload(for: request, fromFile: temporary)
            try await respond(link, outbound, status: (response as? HTTPURLResponse)?.statusCode ?? 502, data: data)
        } else {
            let (file, response) = try await session.download(for: request)
            defer { try? FileManager.default.removeItem(at: file) }
            try await respond(link, outbound, status: (response as? HTTPURLResponse)?.statusCode ?? 502, file: file)
        }
    }

    private func respond(_ link: DirectLink.Link, _ cipher: DirectLink.Cipher, status: Int, data: Data) async throws {
        try await link.send(try cipher.seal(try JSONSerialization.data(withJSONObject: ["s": status, "l": data.count])))
        var offset = 0
        while offset < data.count {
            let end = min(data.count, offset + DirectLink.recordSize)
            try await link.send(try cipher.seal(data.subdata(in: offset..<end)))
            offset = end
        }
    }

    private func respond(_ link: DirectLink.Link, _ cipher: DirectLink.Cipher, status: Int, file: URL) async throws {
        let size = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value ?? 0
        try await link.send(try cipher.seal(try JSONSerialization.data(withJSONObject: ["s": status, "l": size])))
        let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
        var sent: Int64 = 0
        while sent < size {
            guard let piece = try handle.read(upToCount: Int(min(Int64(DirectLink.recordSize), size - sent))), !piece.isEmpty else { throw DirectUnavailable() }
            try await link.send(try cipher.seal(piece))
            sent += Int64(piece.count)
        }
    }

    /// 이 기기의 공유기 안 주소(IPv4, 루프백·169.254 제외)
    static func addresses() -> [String] {
        var result: [String] = []; var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let head else { return [] }; defer { freeifaddrs(head) }
        for pointer in sequence(first: head, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_INET), entry.ifa_flags & UInt32(IFF_LOOPBACK) == 0, entry.ifa_flags & UInt32(IFF_UP) != 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                let text = String(cString: host)
                if !text.hasPrefix("169.254."), !result.contains(text) { result.append(text) }
            }
        }
        return Array(result.prefix(8))
    }

    private static func random(_ count: Int) -> Data {
        var data = Data(count: count)
        _ = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
        return data
    }
    private static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }
}
