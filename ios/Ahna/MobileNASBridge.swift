import Foundation
import CryptoKit

/// Native outbound WebSocket bridge, compatible with nas/Common/Wire.cs.
/// The administrator's 서버 key stays in this phone's Keychain, never in a build archive.
final class MobileNASBridge: @unchecked Sendable {
    let host: MobileHTTPHost
    let origin: URL
    let key: String
    let changed: @Sendable (String) -> Void
    /// 서버 관리자 화면에 보일 기기 종류(iPhone·iPad)
    var platform = "iPhone"
    /// 서버가 보낸 알림(action: limit·message·rejoin·blocked, text)
    var notice: (@Sendable (String, String) -> Void)?
    /// 서버에 연결될 때마다(공지를 다시 받아 갈 때)
    var connected: (@Sendable () -> Void)?
    private let session: URLSession
    private let gate = NSLock()
    private var sockets: [URLSessionWebSocketTask] = []
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var supervisor: Task<Void, Never>?
    private var stopped = false
    static func validate(_ address: String, key: String) throws {
        guard let parts = URLComponents(string: address.trimmingCharacters(in: .whitespacesAndNewlines)), parts.scheme == "https", parts.host != nil, parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil, parts.path.isEmpty || parts.path == "/", Brand.isMemberToken(key) || (key.count >= 64 && key.count <= 256 && key.allSatisfy({ $0.isASCII && $0.isHexDigit })) else { throw AhnaError.message("서버 HTTPS 주소와 64자리 이상의 연결 키를 확인하세요.") }
    }
    init(host: MobileHTTPHost, address: String, key: String, changed: @escaping @Sendable (String) -> Void) throws {
        try Self.validate(address, key: key); self.host = host; self.origin = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines))!; self.key = key; self.changed = changed
        let config = URLSessionConfiguration.ephemeral; config.httpCookieStorage = nil; config.httpShouldSetCookies = false; config.timeoutIntervalForRequest = 60; config.timeoutIntervalForResource = 45 * 60
        session = URLSession(configuration: config, delegate: NoAPIRedirects(), delegateQueue: nil)
    }
    private func socket(_ path: String, control: Bool = false) throws -> URLSessionWebSocketTask {
        var parts = URLComponents(url: origin, resolvingAgainstBaseURL: false)!; parts.scheme = "wss"; parts.path = path
        var request = URLRequest(url: parts.url!); request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        if control {
            request.setValue(host.identity, forHTTPHeaderField: "X-Ahna-Computer")
            request.setValue("notice,notices", forHTTPHeaderField: "X-Ahna-Features")
            request.setValue(host.name.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "", forHTTPHeaderField: "X-Ahna-Name")
            request.setValue(platform, forHTTPHeaderField: "X-Ahna-Platform")
            request.setValue(SHA256.hash(data: Data(host.pin.utf8)).map { String(format: "%02X", $0) }.joined(), forHTTPHeaderField: "X-Ahna-Pin-Hash")
        }
        let task = session.webSocketTask(with: request); task.maximumMessageSize = 65536
        gate.lock(); if stopped { gate.unlock(); throw CancellationError() }; sockets.append(task); gate.unlock(); task.resume(); return task
    }
    private func remove(_ socket: URLSessionWebSocketTask) { gate.lock(); sockets.removeAll { $0 === socket }; gate.unlock(); socket.cancel(with: .goingAway, reason: nil) }
    func start() {
        supervisor = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do { try await self.connect() } catch { if Task.isCancelled { return }; self.changed("서버 재연결 대기 · 주소·연결 키·인증서를 확인하세요.") }
                do { try await Task.sleep(nanoseconds: 4_000_000_000) } catch { return }
            }
        }
    }
    private func connect() async throws {
        changed("서버 연결 중…"); let control = try socket("/_bridge/control", control: true); defer { remove(control) }
        try await control.send(.string("{\"type\":\"ping\"}")); changed("서버 연결됨 · 원격 전송 가능"); connected?()
        let ping = Task { do { while !Task.isCancelled { try await Task.sleep(nanoseconds: 15_000_000_000); try await control.send(.string("{\"type\":\"ping\"}")) } } catch { control.cancel(with: .goingAway, reason: nil) } }; defer { ping.cancel() }
        while !Task.isCancelled {
            let message = try await json(control)
            if message["type"] as? String == "notice" { notice?(message["action"] as? String ?? "", message["text"] as? String ?? ""); continue }
            guard let id = message["id"] as? String, Self.validID(id) else { throw AhnaError.message("올바르지 않은 중계 요청") }
            launch(id)
        }
    }
    private func launch(_ id: String) {
        gate.lock(); defer { gate.unlock() }; guard !stopped, tasks.count < 6 else { return }
        let jobID = UUID()
        tasks[jobID] = Task { [weak self] in
            guard let self else { return }; defer { self.jobEnded(jobID) }
            do { try await self.handle(id) } catch { }
        }
    }
    private func jobEnded(_ id: UUID) { gate.lock(); tasks.removeValue(forKey: id); gate.unlock() }
    private static func validID(_ id: String) -> Bool { id.count == 32 && id.allSatisfy { $0.isASCII && $0.isHexDigit } }
    private static func allowed(_ method: String, _ path: String) -> Bool {
        guard path.utf8.count <= 4096, path.hasPrefix("/"), !path.hasPrefix("//"), !path.contains("#"), !path.contains("\\"), path.rangeOfCharacter(from: .controlCharacters) == nil else { return false }
        let part = String(path.split(separator: "?", maxSplits: 1)[0])
        // 아나 1.2 게스트 경로 /s/{cid}/{token}[/info|/status|/file/N|/decline|/request|/upload] — nas/Common/Wire.cs와 같은 목록
        if part.hasPrefix("/s/") { return MobileHTTPHost.guestAllowed(method, part) }
        return method == "GET" && (part == "/api/state" || part.hasPrefix("/api/download/") && validID(String(part.dropFirst(14)))) || method == "POST" && (["/api/pair", "/api/upload", "/api/logout"].contains(part) || part.hasPrefix("/api/received/") && validID(String(part.dropFirst(14))))
    }
    /// 큰 본문(최대 4 GiB)을 받을 수 있는 경로: 기존 /api/upload와 게스트 올리기(/s/…/upload)
    private static func largeBody(_ path: String) -> Bool {
        let part = String(path.split(separator: "?", maxSplits: 1)[0])
        return part == "/api/upload" || part.hasPrefix("/s/") && MobileHTTPHost.guestParts(part)?.rest == "upload"
    }
    private func json(_ socket: URLSessionWebSocketTask) async throws -> [String: Any] {
        guard case .string(let text) = try await socket.receive(), text.utf8.count <= 32768, let result = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { throw AhnaError.message("올바르지 않은 중계 응답") }; return result
    }
    private func sendJSON(_ value: [String: Any], _ socket: URLSessionWebSocketTask) async throws {
        try await socket.send(.string(String(decoding: JSONSerialization.data(withJSONObject: value), as: UTF8.self)))
    }
    private func handle(_ id: String) async throws {
        let socket = try self.socket("/_bridge/data/" + id); defer { remove(socket) }
        let timeout = Task { do { try await Task.sleep(nanoseconds: 45 * 60 * 1_000_000_000); socket.cancel(with: .goingAway, reason: nil) } catch { } }; defer { timeout.cancel() }
        let head = try await json(socket)
        guard let method = head["Method"] as? String, let path = head["Path"] as? String, let size = head["Length"] as? NSNumber, size.int64Value >= 0, size.int64Value <= MobileHTTPHost.maxFile, Self.allowed(method, path), Self.largeBody(path) || size.int64Value <= 16384 else {
            try await sendJSON(["Status": 400, "Length": 0], socket); _ = try await json(socket); return
        }
        guard let local = URL(string: "http://127.0.0.1:\(host.port)" + path) else { throw AhnaError.message("올바르지 않은 중계 경로") }
        var request = URLRequest(url: local)
        request.httpMethod = method
        let cookie = head["Cookie"] as? String ?? "", type = head["ContentType"] as? String ?? "application/octet-stream"
        guard !cookie.contains("\r"), !cookie.contains("\n"), !type.contains("\r"), !type.contains("\n") else { throw AhnaError.message("올바르지 않은 요청 헤더") }
        request.setValue(cookie, forHTTPHeaderField: "Cookie"); request.setValue(type, forHTTPHeaderField: "Content-Type")
        var upload: URL?
        defer { if let upload { try? FileManager.default.removeItem(at: upload) } }
        if method == "POST" {
            let part = FileManager.default.temporaryDirectory.appendingPathComponent("ahna-nas-" + UUID().uuidString)
            FileManager.default.createFile(atPath: part.path, contents: nil); upload = part
            let file = try FileHandle(forWritingTo: part); defer { try? file.close() }
            try await sendJSON(["Status": 100], socket)
            var left = size.int64Value
            while left > 0 {
                guard case .data(let bytes) = try await socket.receive(), !bytes.isEmpty, bytes.count <= 65536, Int64(bytes.count) <= left else { throw AhnaError.message("중계 파일이 중단되었습니다.") }
                try file.write(contentsOf: bytes); left -= Int64(bytes.count)
            }
            try file.close(); request.setValue(String(size.int64Value), forHTTPHeaderField: "Content-Length")
        } else { try await sendJSON(["Status": 100], socket) }
        let responseURL: URL; let response: URLResponse
        if let upload {
            // POST replies are small JSON; no received file data is ever held in memory.
            let (data, raw) = try await session.upload(for: request, fromFile: upload)
            guard data.count <= 2 * 1024 * 1024 else { throw AhnaError.message("응답이 너무 큽니다.") }
            let part = FileManager.default.temporaryDirectory.appendingPathComponent("ahna-nas-response-" + UUID().uuidString); try data.write(to: part); responseURL = part; response = raw
        } else { (responseURL, response) = try await session.download(for: request) }
        defer { try? FileManager.default.removeItem(at: responseURL) }
        guard let http = response as? HTTPURLResponse else { throw AhnaError.message("수신 응답을 읽을 수 없습니다.") }
        let length = (try responseURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard Int64(length) <= MobileHTTPHost.maxFile else { throw AhnaError.message("응답 파일이 너무 큽니다.") }
        var headers: [String: [String]] = [:]
        for field in ["Content-Type", "Content-Disposition", "Content-Security-Policy", "Cache-Control", "Set-Cookie", "X-Ahna-Computer"] { if let value = http.value(forHTTPHeaderField: field) { headers[field] = [value] } }
        try await sendJSON(["Status": http.statusCode, "Length": length, "Headers": headers], socket)
        let input = try FileHandle(forReadingFrom: responseURL); defer { try? input.close() }
        while let bytes = try input.read(upToCount: 65536), !bytes.isEmpty { try Task.checkCancellation(); try await socket.send(.data(bytes)) }
        guard (try await json(socket))["received"] as? Bool == true else { throw AhnaError.message("중계 수신 확인 실패") }
    }
    func stop() {
        gate.lock(); stopped = true; let current = sockets; let jobs = Array(tasks.values); sockets.removeAll(); tasks.removeAll(); gate.unlock()
        supervisor?.cancel(); supervisor = nil; for task in jobs { task.cancel() }; for socket in current { socket.cancel(with: .goingAway, reason: nil) }; session.invalidateAndCancel()
    }
    deinit { stop() }
}
