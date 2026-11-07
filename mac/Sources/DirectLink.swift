import Foundation
import Network
import CryptoKit
import Security

// 같은 네트워크(같은 공유기)면 서버를 거치지 않고 기기끼리 바로 주고받기.
// Windows·Mac 수신 쪽 src/DirectChannel.cs, Android DirectLink.java 와 같은 방식입니다.
// 이 파일은 mac/Sources/DirectLink.swift 와 같은 파일이어야 합니다.
//
// 받는 기기가 서버를 거친(=인증된) /api/state?direct=1 응답에 키·포트·주소를 알려 주면,
// 보내는 기기는 그 주소로 TCP 연결해 요청 하나를 AES-256-GCM으로 암호화해 보냅니다.
//   → "AHNADR01" + 키 id(16) + salt(16), 이후 레코드 [길이 u32 BE][암호문+태그16] (본문 최대 1 MiB)
//   키: 보내는 쪽 HMAC-SHA256(key, "c2s"+salt), 받는 쪽 HMAC-SHA256(key, "s2c"+salt), nonce = 0×4 + 레코드 번호 u64 BE
//   첫 레코드 {"m","p","l","t"} → 본문 / 응답 첫 레코드 {"s","l"} → 본문

struct DirectInfo: Decodable, Equatable, Sendable {
    let id: String
    let key: String
    let port: Int
    let addrs: [String]
    var usable: Bool {
        id.count == 32 && id.allSatisfy { $0.isASCII && $0.isHexDigit } && Data(base64Encoded: key)?.count == 32 && (1...65535).contains(port)
            && addrs.contains { IPv4Address($0) != nil }
    }
}

/// 직접 연결이 안 되거나 도중에 끊김: 서버를 거쳐 다시 보내면 됩니다.
struct DirectUnavailable: Error {}
/// 파일 본문은 다 보냈는데 결과를 못 받음: 상대가 이미 저장했을 수 있어 서버로 다시 보내지 않습니다.
struct DirectDelivered: LocalizedError {
    var errorDescription: String? { "상대 기기의 저장 결과를 받지 못했습니다. 상대 기기에서 파일을 확인하세요." }
}

enum DirectLink {
    static let recordSize = 1 << 20
    static let magic = Data("AHNADR01".utf8)
    /// 레코드 하나를 주고받는 최대 시간(상대가 사라져도 멈춰 있지 않게), 본문을 다 보낸 뒤 응답을 기다리는 최대 시간.
    static let idle: TimeInterval = 60
    static let reply: TimeInterval = 45 * 60

    final class Cipher: @unchecked Sendable {
        private let key: SymmetricKey
        private var counter: UInt64 = 0
        init(secret: Data, label: String, salt: Data) {
            let code = HMAC<SHA256>.authenticationCode(for: Data(label.utf8) + salt, using: SymmetricKey(data: secret))
            key = SymmetricKey(data: Data(code))
        }
        private func nonce() throws -> AES.GCM.Nonce {
            var bytes = Data(count: 4)
            for shift in stride(from: 56, through: 0, by: -8) { bytes.append(UInt8(truncatingIfNeeded: counter >> UInt64(shift))) }
            counter += 1
            return try AES.GCM.Nonce(data: bytes)
        }
        func seal(_ plain: Data) throws -> Data {
            let box = try AES.GCM.seal(plain, using: key, nonce: nonce())
            let length = UInt32(plain.count + 16)
            var frame = Data([UInt8(length >> 24), UInt8((length >> 16) & 0xff), UInt8((length >> 8) & 0xff), UInt8(length & 0xff)])
            frame.append(box.ciphertext); frame.append(box.tag)
            return frame
        }
        func open(_ frame: Data) throws -> Data {
            let bytes = Data(frame)
            let box = try AES.GCM.SealedBox(nonce: nonce(), ciphertext: bytes.prefix(bytes.count - 16), tag: bytes.suffix(16))
            return try AES.GCM.open(box, using: key)
        }
    }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock(); private var done = false
        func fire() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
    }

    final class Link: @unchecked Sendable {
        let connection: NWConnection
        init(_ connection: NWConnection) { self.connection = connection }
        /// 정해진 시간 안에 끝나지 않거나 작업이 취소되면 연결을 끊습니다(그러면 기다리던 쪽이 오류로 깨어남).
        private func guarded<T>(_ seconds: TimeInterval, _ body: () async throws -> T) async throws -> T {
            let connection = connection
            let timer = DispatchWorkItem { connection.cancel() }
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds, execute: timer)
            defer { timer.cancel() }
            return try await withTaskCancellationHandler { try await body() } onCancel: { connection.cancel() }
        }
        func send(_ data: Data) async throws {
            try await guarded(DirectLink.idle) {
                try await withCheckedThrowingContinuation { (k: CheckedContinuation<Void, Error>) in
                    connection.send(content: data, completion: .contentProcessed { error in
                        if let error { k.resume(throwing: error) } else { k.resume() }
                    })
                }
            }
        }
        func receive(_ count: Int, wait: TimeInterval = DirectLink.idle) async throws -> Data {
            try await guarded(wait) {
                var result = Data()
                while result.count < count {
                    try Task.checkCancellation()
                    let want = count - result.count
                    let piece: Data = try await withCheckedThrowingContinuation { k in
                        connection.receive(minimumIncompleteLength: 1, maximumLength: want) { data, _, complete, error in
                            if let error { k.resume(throwing: error) }
                            else if let data, !data.isEmpty { k.resume(returning: data) }
                            else if complete { k.resume(throwing: DirectUnavailable()) }
                            else { k.resume(returning: Data()) }
                        }
                    }
                    result.append(piece)
                }
                return result
            }
        }
        func readRecord(_ cipher: Cipher, wait: TimeInterval = DirectLink.idle) async throws -> Data {
            let head = try await receive(4, wait: wait)
            let length = head.reduce(0) { $0 << 8 | Int($1) }
            guard length >= 16, length <= DirectLink.recordSize + 16 else { throw DirectUnavailable() }
            return try cipher.open(try await receive(length))
        }
        func close() { connection.cancel() }
    }

    private static func open(_ address: String, port: Int) async throws -> Link {
        guard let host = IPv4Address(address), let port = NWEndpoint.Port(rawValue: UInt16(port)) else { throw DirectUnavailable() }
        let connection = NWConnection(host: .ipv4(host), port: port, using: .tcp)
        let link = Link(connection)
        let queue = DispatchQueue(label: "ahna.direct.connect")
        let once = Once()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (k: CheckedContinuation<Link, Error>) in
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready: if once.fire() { k.resume(returning: link) }
                    case .failed, .waiting, .cancelled: if once.fire() { connection.cancel(); k.resume(throwing: DirectUnavailable()) }
                    default: break
                    }
                }
                connection.start(queue: queue)
                queue.asyncAfter(deadline: .now() + 0.9) { if once.fire() { connection.cancel(); k.resume(throwing: DirectUnavailable()) } }
            }
        } onCancel: { connection.cancel() }
    }

    /// 알려 준 주소들에 동시에 연결해 보고 먼저 된 것을 씁니다(0.9초 안에 안 되면 실패).
    private static func connect(_ info: DirectInfo) async throws -> Link {
        let addresses = Array(info.addrs.filter { IPv4Address($0) != nil }.prefix(8))
        return try await withThrowingTaskGroup(of: Link?.self) { group in
            for address in addresses { group.addTask { try? await open(address, port: info.port) } }
            var winner: Link?
            for try await link in group {
                guard let link else { continue }
                if winner == nil { winner = link; group.cancelAll() } else { link.close() }
            }
            guard let winner else { throw DirectUnavailable() }
            return winner
        }
    }

    struct Response: Sendable {
        let status: Int
        let length: Int64
        let link: Link
        let cipher: Cipher
        /// 짧은 응답(JSON 등)을 모두 읽습니다.
        func data(limit: Int64 = 4 * 1024 * 1024) async throws -> Data {
            guard length <= limit else { throw DirectUnavailable() }
            var result = Data(); result.reserveCapacity(Int(length))
            while Int64(result.count) < length {
                let piece = try await link.readRecord(cipher)
                guard !piece.isEmpty, Int64(result.count + piece.count) <= length else { throw DirectUnavailable() }
                result.append(piece)
            }
            return result
        }
        /// 본문을 임시 파일에 받습니다.
        func file(progress: (@Sendable (Int64) -> Void)? = nil) async throws -> URL {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("ahna-direct-" + UUID().uuidString)
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw DirectUnavailable() }
            do {
                let handle = try FileHandle(forWritingTo: url); defer { try? handle.close() }
                var got: Int64 = 0
                while got < length {
                    try Task.checkCancellation()
                    let piece = try await link.readRecord(cipher)
                    guard !piece.isEmpty, got + Int64(piece.count) <= length else { throw DirectUnavailable() }
                    try handle.write(contentsOf: piece)
                    got += Int64(piece.count); progress?(got)
                }
                return url
            } catch { try? FileManager.default.removeItem(at: url); throw error }
        }
    }

    /// 요청 하나: 머리 → 본문(write에 쓰기 함수를 넘겨 줌) → 응답 머리까지. 실패는 CancellationError 아니면 모두 DirectUnavailable.
    static func perform(_ info: DirectInfo, method: String, path: String, length: Int64, contentType: String?,
                        body: ((_ write: (Data) async throws -> Void) async throws -> Void)? = nil) async throws -> Response {
        guard info.usable, let secret = Data(base64Encoded: info.key), let id = hexData(info.id) else { throw DirectUnavailable() }
        let link = try await connect(info)
        var delivered = false
        do {
            var salt = Data(count: 16)
            guard salt.withUnsafeMutableBytes({ SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }) == errSecSuccess else { throw DirectUnavailable() }
            try await link.send(magic + id + salt)
            let outbound = Cipher(secret: secret, label: "c2s", salt: salt)
            var head: [String: Any] = ["m": method, "p": path, "l": length]
            if let contentType { head["t"] = contentType }
            try await link.send(try outbound.seal(try JSONSerialization.data(withJSONObject: head)))
            var sent: Int64 = 0
            if let body {
                try await body { piece in
                    var offset = 0
                    while offset < piece.count {
                        let part = piece.subdata(in: offset..<min(piece.count, offset + recordSize))
                        sent += Int64(part.count)
                        guard sent <= length else { throw DirectUnavailable() }
                        try await link.send(try outbound.seal(part))
                        offset += part.count
                    }
                }
            }
            guard sent == length else { throw DirectUnavailable() }
            delivered = length > 0
            let inbound = Cipher(secret: secret, label: "s2c", salt: salt)
            let reply = try await link.readRecord(inbound, wait: DirectLink.reply)
            guard let object = try JSONSerialization.jsonObject(with: reply) as? [String: Any],
                  let status = (object["s"] as? NSNumber)?.intValue, let bodyLength = (object["l"] as? NSNumber)?.int64Value,
                  (100...599).contains(status), bodyLength >= 0 else { throw DirectUnavailable() }
            // 401: 연결 정보가 바뀌었을 수 있으니(저장되지 않음) 서버를 거쳐 다시 확인합니다.
            if status == 401 { delivered = false; throw DirectUnavailable() }
            return Response(status: status, length: bodyLength, link: link, cipher: inbound)
        } catch is CancellationError {
            link.close(); throw CancellationError()
        } catch {
            link.close(); throw delivered ? DirectDelivered() : DirectUnavailable()
        }
    }

    /// 파일 하나를 올립니다. progress에는 보낸 바이트 수를 알려 줍니다.
    static func upload(_ info: DirectInfo, path: String, file: URL, bytes: Int64, contentType: String, progress: (@Sendable (Int64) -> Void)? = nil) async throws -> (Int, Data) {
        let response = try await perform(info, method: "POST", path: path, length: bytes, contentType: contentType) { write in
            let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
            var done: Int64 = 0
            while done < bytes {
                try Task.checkCancellation()
                guard let piece = try handle.read(upToCount: Int(min(Int64(recordSize), bytes - done))), !piece.isEmpty else { throw DirectUnavailable() }
                try await write(piece)
                done += Int64(piece.count); progress?(done)
            }
        }
        defer { response.link.close() }
        do { return (response.status, try await response.data()) } catch is CancellationError { throw CancellationError() } catch { throw bytes > 0 ? DirectDelivered() : DirectUnavailable() }
    }

    /// 짧은 요청(GET, 작은 POST).
    static func data(_ info: DirectInfo, method: String, path: String, body: Data? = nil, contentType: String? = nil) async throws -> (Int, Data) {
        let payload = body ?? Data()
        let response = try await perform(info, method: method, path: path, length: Int64(payload.count), contentType: contentType, body: payload.isEmpty ? nil : { write in try await write(payload) })
        defer { response.link.close() }
        do { return (response.status, try await response.data()) } catch is CancellationError { throw CancellationError() } catch { throw DirectUnavailable() }
    }

    /// GET으로 받은 본문을 임시 파일로. 성공이 아니면 본문 대신 빈 파일.
    static func download(_ info: DirectInfo, path: String) async throws -> (Int, URL, Int64) {
        let response = try await perform(info, method: "GET", path: path, length: 0, contentType: nil)
        defer { response.link.close() }
        do {
            if !(200..<300).contains(response.status) {
                _ = try? await response.data()
                let empty = FileManager.default.temporaryDirectory.appendingPathComponent("ahna-direct-" + UUID().uuidString)
                FileManager.default.createFile(atPath: empty.path, contents: nil)
                return (response.status, empty, 0)
            }
            return (response.status, try await response.file(), response.length)
        } catch is CancellationError { throw CancellationError() } catch { throw DirectUnavailable() }
    }

    private static func hexData(_ text: String) -> Data? {
        guard text.count % 2 == 0 else { return nil }
        var result = Data(); var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            guard let byte = UInt8(text[index..<next], radix: 16) else { return nil }
            result.append(byte); index = next
        }
        return result
    }
}
