import Foundation

// Runs on a Mac without touching real 서버 settings, Photos or the pairing Keychain.
final class MockComputers: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    static var offline = Set<String>()
    static var tokens = ["pc1": "token1", "pc2": "token2"]
    static var pairs = 0
    static var names: [String: String] = [:]
    static var requests: [(String, String, String)] = []
    static var clipboardUploads: [String: String] = [:]
    static var legacyClipboard = false
    static let clipboardText = "Windows 한글 🐱\r\n둘째 줄  "
    private func requestData() -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var result = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
        while true { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; result.append(contentsOf: buffer.prefix(count)) }
        return result
    }
    // 실제 서버처럼 기기 ID는 32자리 16진수로 주고받습니다(0.6.1부터 앱이 형식을 검사함).
    static func wire(_ name: String) -> String { name.isEmpty ? "" : String(repeating: name == "pc1" ? "a" : "b", count: 32) }
    static func name(_ wire: String) -> String { wire == String(repeating: "a", count: 32) ? "pc1" : wire == String(repeating: "b", count: 32) ? "pc2" : wire }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "ahna-test.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        let path = request.url!.path
        var computer = Self.name(request.value(forHTTPHeaderField: "X-Ahna-Computer") ?? "")
        let cookie = request.value(forHTTPHeaderField: "Cookie") ?? ""
        var code = 200
        var headers = ["Content-Type": "application/json"]
        var body: [String: Any] = [:]
        if path == "/api/pair" {
            var data = request.httpBody ?? Data()
            if data.isEmpty, let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 4096)
                while true { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; data.append(contentsOf: buffer.prefix(n)) }
            }
            let input = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            computer = input?["pin"] as? String == "111111" ? "pc1" : "pc2"
            Self.pairs += 1
            Self.names[computer] = input?["name"] as? String
            headers["Set-Cookie"] = "ahna=\(Self.tokens[computer]!); Path=/; Max-Age=2592000; Secure; HttpOnly, ahna-computer=\(computer); Path=/; Secure; HttpOnly"
        } else if Self.offline.contains(computer) { code = 503 }
        else if cookie != "ahna=\(Self.tokens[computer] ?? "missing")" { code = 401 }
        if path == "/api/state" {
            if let name = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "deviceName" })?.value, code == 200 {
                Self.names[computer] = name
            }
            body = ["id": "phone-" + computer, "name": Self.names[computer] ?? "", "hostName": computer, "owner": false, "items": []]
            if !Self.legacyClipboard { body["clipboard"] = [["id": "11111111111111111111111111111111", "sender": computer, "bytes": Self.clipboardText.utf8.count, "created": "2026-10-20T00:00:00Z"]] }
        }
        var responseData: Data?
        if code == 200, path == "/api/upload", request.url?.query?.contains("kind=clipboard") == true {
            Self.clipboardUploads[computer] = String(data: requestData(), encoding: .utf8)
            body = ["id": "22222222222222222222222222222222"]
        }
        if code == 200, path == "/api/download/11111111111111111111111111111111", request.url?.query == "kind=clipboard" {
            responseData = Data(Self.clipboardText.utf8); headers["Content-Type"] = "text/plain; charset=utf-8"
        }
        headers["X-Ahna-Computer"] = Self.wire(computer)
        Self.requests.append((computer, path, cookie))
        let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: responseData ?? (try! JSONSerialization.data(withJSONObject: body)))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
    static func setOffline(_ value: Bool, _ id: String) {
        lock.lock(); defer { lock.unlock() }
        if value { offline.insert(id) } else { offline.remove(id) }
    }
    static func pairCount() -> Int { lock.lock(); defer { lock.unlock() }; return pairs }
    static func uploadedClipboard(_ computer: String) -> String? { lock.lock(); defer { lock.unlock() }; return clipboardUploads[computer] }
    static func useLegacyClipboard(_ value: Bool) { lock.lock(); defer { lock.unlock() }; legacyClipboard = value }
}

@main struct ConnectionChecks {
    @MainActor static func main() async throws {
        let previousName = UserDefaults.standard.object(forKey: "deviceDisplayName")
        defer {
            if let previousName { UserDefaults.standard.set(previousName, forKey: "deviceDisplayName") }
            else { UserDefaults.standard.removeObject(forKey: "deviceDisplayName") }
        }
        var checks = 0
        func check(_ value: Bool, _ name: String) {
            precondition(value, name); checks += 1; print("PASS: " + name)
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockComputers.self]
        var saved: [ComputerProfile] = []
        let client = AhnaClient(receive: false, profiles: [], saveProfiles: { saved = $0 }, configuration: config)
        client.address = "https://ahna-test.invalid"
        client.pin = "111111"; await client.connect()
        check(client.connections.count == 1 && client.state?.hostName == "pc1", "First PC pairs and restores its own cookie")
        client.pin = "222222"; await client.connect()
        check(client.connections.count == 2 && client.state?.hostName == "pc2", "Second PC on the same 서버 keeps the first connection")
        check(saved.count == 2 && Set(saved.compactMap { $0.token }).count == 2, "Independent credentials persist for both PCs")
        let clipboard = "아이폰 글자 🐱\n 둘째 줄 "
        try await client.sendClipboard(clipboard)
        check(MockComputers.uploadedClipboard("pc2") == clipboard && MockComputers.uploadedClipboard("pc1") == nil, "Clipboard uploads only to the selected PC using its own credentials")
        let inbox = client.state!.clipboard!.first!
        let receivedText = try await client.selected!.clipboardText(inbox)
        check(receivedText == MockComputers.clipboardText, "Received clipboard preserves Unicode and line endings")
        do { try await client.sendClipboard(String(repeating: "한", count: 22000)); preconditionFailure("Oversized clipboard accepted") }
        catch { check(MockComputers.uploadedClipboard("pc2") == clipboard, "Oversized UTF-8 clipboard is rejected before sending") }
        MockComputers.useLegacyClipboard(true); try await client.selected!.refresh()
        check(client.state?.clipboard == nil && client.state?.hostName == "pc2", "Older server state still decodes without clipboard support")
        do { try await client.sendClipboard(clipboard); preconditionFailure("Legacy server clipboard accepted") }
        catch { check(client.state != nil, "Unsupported clipboard leaves existing file pairing intact") }
        MockComputers.useLegacyClipboard(false); try await client.selected!.refresh()
        let beforeRenamePairs = MockComputers.pairCount()
        client.deviceName = "거실 아이패드"; await client.saveDeviceName()
        check(client.connections.allSatisfy { $0.state?.name == "거실 아이패드" } && MockComputers.pairCount() == beforeRenamePairs, "Custom name updates every existing PC without another PIN")
        client.deviceName = "   "; await client.saveDeviceName()
        check(DeviceIdentity.savedName == "거실 아이패드" && client.connections.allSatisfy { $0.deviceName == "거실 아이패드" }, "An empty name never replaces the saved valid identity")
        let decoded = try JSONDecoder().decode([ComputerProfile].self, from: JSONEncoder().encode(saved))
        check(decoded == saved, "Computer identity and credentials survive serialization")
        let firstID = client.connections[0].id
        client.pin = "111111"; await client.connect()
        check(client.connections.count == 2 && client.selected?.computerID == MockComputers.wire("pc1") && client.selectedID != firstID, "Re-pairing replaces only the selected PC profile")
        let restored = AhnaClient(receive: false, profiles: saved, saveProfiles: { saved = $0 }, configuration: config)
        let polling = Task { await restored.poll() }
        try await Task.sleep(nanoseconds: 200_000_000)
        check(restored.connections.allSatisfy { $0.state != nil }, "All saved PCs reconnect on app launch")
        let pairCount = MockComputers.pairCount()
        MockComputers.setOffline(true, "pc1")
        try await Task.sleep(nanoseconds: 3_200_000_000)
        check(restored.connections.first { $0.computerID == MockComputers.wire("pc1") }?.state == nil && restored.connections.first { $0.computerID == MockComputers.wire("pc2") }?.state != nil, "An offline PC does not block polling the other PC")
        check(saved.count == 2, "Temporary disconnect retains both saved pairings")
        MockComputers.setOffline(false, "pc1")
        try await Task.sleep(nanoseconds: 3_200_000_000)
        check(restored.connections.allSatisfy { $0.state != nil } && MockComputers.pairCount() == pairCount, "PC comes back online without a new PIN or pairing request")
        polling.cancel(); await polling.value
        MockComputers.setOffline(true, "pc1")
        let first = restored.connections.first { $0.computerID == MockComputers.wire("pc1") }!
        await restored.forget(first)
        check(saved.count == 1 && saved[0].computerID == MockComputers.wire("pc2"), "Deleting an offline PC preserves the other PC credentials")
        let blocked = AhnaClient(receive: false, profiles: saved, saveProfiles: { _ in throw AhnaError.message("Synthetic storage error") }, configuration: config)
        await blocked.forget(blocked.connections[0])
        check(blocked.connections.count == 1, "Storage failure never silently drops a saved connection")
        print("\(checks) connection checks passed")
    }
}
