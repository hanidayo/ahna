import Foundation

// Runs on a Mac without touching real NAS settings, Photos or the pairing Keychain.
final class MockComputers: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    static var offline = Set<String>()
    static var tokens = ["pc1": "token1", "pc2": "token2"]
    static var uploads = 0
    static var failUploadAt = 0
    static var pairs = 0
    static var names: [String: String] = [:]
    static var requests: [(String, String, String)] = []
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "ahna-test.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        let path = request.url!.path
        var computer = request.value(forHTTPHeaderField: "X-Ahna-Computer") ?? ""
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
        }
        if path == "/api/upload" { Self.uploads += 1; if Self.uploads == Self.failUploadAt { code = 500 } }
        headers["X-Ahna-Computer"] = computer
        Self.requests.append((computer, path, cookie))
        let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: body))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
    static func setOffline(_ value: Bool, _ id: String) {
        lock.lock(); defer { lock.unlock() }
        if value { offline.insert(id) } else { offline.remove(id) }
    }
    static func pairCount() -> Int { lock.lock(); defer { lock.unlock() }; return pairs }
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
        let beforeRenamePairs = MockComputers.pairCount()
        client.deviceName = "거실 아이패드"; await client.saveDeviceName()
        check(client.connections.allSatisfy { $0.state?.name == "거실 아이패드" } && MockComputers.pairCount() == beforeRenamePairs, "Custom name updates every existing PC without another PIN")
        client.deviceName = "   "; await client.saveDeviceName()
        check(DeviceIdentity.savedName == "거실 아이패드" && client.connections.allSatisfy { $0.deviceName == "거실 아이패드" }, "An empty name never replaces the saved valid identity")
        let decoded = try JSONDecoder().decode([ComputerProfile].self, from: JSONEncoder().encode(saved))
        check(decoded == saved, "Computer identity and credentials survive serialization")
        let probe = AhnaConnection(receive: false, profile: saved[0], configuration: config)
        var credentialNotifications = 0
        probe.credentialsChanged = { credentialNotifications += 1 }
        for _ in 0..<100 { try await probe.refresh() }
        check(credentialNotifications == 0, "100 unchanged state refreshes never request credential persistence")
        let firstID = client.connections[0].id
        client.pin = "111111"; await client.connect()
        check(client.connections.count == 2 && client.selected?.computerID == "pc1" && client.selectedID != firstID, "Re-pairing replaces only the selected PC profile")
        let restored = AhnaClient(receive: false, profiles: saved, saveProfiles: { saved = $0 }, configuration: config)
        let background = BackgroundPolling(client: restored)
        background.start()
        check(background.started, "Receiver starts without constructing any app window")
        try await Task.sleep(nanoseconds: 200_000_000)
        check(restored.connections.allSatisfy { $0.state != nil }, "All saved PCs reconnect on app launch")
        let pairCount = MockComputers.pairCount()
        MockComputers.setOffline(true, "pc1")
        try await Task.sleep(nanoseconds: 3_200_000_000)
        check(restored.connections.first { $0.computerID == "pc1" }?.state == nil && restored.connections.first { $0.computerID == "pc2" }?.state != nil, "An offline PC does not block polling the other PC")
        check(saved.count == 2, "Temporary disconnect retains both saved pairings")
        MockComputers.setOffline(false, "pc1")
        try await Task.sleep(nanoseconds: 3_200_000_000)
        check(restored.connections.allSatisfy { $0.state != nil } && MockComputers.pairCount() == pairCount, "PC comes back online without a new PIN or pairing request")
        background.stop()
        check(!background.started, "Background receiver can be stopped explicitly")
        MockComputers.setOffline(true, "pc1")
        let first = restored.connections.first { $0.computerID == "pc1" }!
        await restored.forget(first)
        check(saved.count == 1 && saved[0].computerID == "pc2", "Deleting an offline PC preserves the other PC credentials")
        let blocked = AhnaClient(receive: false, profiles: saved, saveProfiles: { _ in throw AhnaError.message("Synthetic storage error") }, configuration: config)
        await blocked.forget(blocked.connections[0])
        check(blocked.connections.count == 1, "Storage failure never silently drops a saved connection")
        // A share sheet closes only through this callback, after all responses.
        let uploadClient = AhnaClient(receive: false, profiles: [], saveProfiles: { _ in }, configuration: config)
        uploadClient.address = "https://ahna-test.invalid"; uploadClient.pin = "222222"
        await uploadClient.connect()
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("share test".utf8).write(to: temporary)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let file = PendingFile(url: temporary, path: "test.txt", bytes: 10)
        var callbacks = 0
        func waitForUpload() async throws {
            for _ in 0..<200 {
                if !uploadClient.busy { return }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            throw AhnaError.message("Upload test timed out")
        }
        check(uploadClient.send([file]) { callbacks += 1 }, "Single-file upload starts")
        try await waitForUpload()
        check(callbacks == 1 && MockComputers.uploads == 1, "Single-file success closes once after response")
        check(uploadClient.send([file, file]) { callbacks += 1 }, "Multi-file upload starts")
        try await waitForUpload()
        check(callbacks == 2 && MockComputers.uploads == 3, "Multi-file success closes once after both responses")
        MockComputers.failUploadAt = 5
        check(uploadClient.send([file, file]) { callbacks += 1 }, "Partial-failure upload starts")
        try await waitForUpload()
        check(callbacks == 2 && MockComputers.uploads == 5, "Second-file failure keeps share sheet open")
        MockComputers.failUploadAt = 0
        check(uploadClient.send([file, file]) { callbacks += 1 }, "Failed batch can be retried")
        try await waitForUpload()
        check(callbacks == 3 && MockComputers.uploads == 7, "Retry success closes once after all responses")
        // Exercise URLSession download, destination switching and acknowledgement.
        let previousFolder = UserDefaults.standard.object(forKey: ReceiveFolder.preferenceKey)
        defer {
            if let previousFolder { UserDefaults.standard.set(previousFolder, forKey: ReceiveFolder.preferenceKey) }
            else { UserDefaults.standard.removeObject(forKey: ReceiveFolder.preferenceKey) }
        }
        let receiveRoot = FileManager.default.temporaryDirectory.appendingPathComponent("ahna-receive-" + UUID().uuidString)
        let receiveA = receiveRoot.appendingPathComponent("A"), receiveB = receiveRoot.appendingPathComponent("B")
        for directory in [receiveA,receiveB] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        defer { try? FileManager.default.removeItem(at: receiveRoot) }
        try ReceiveFolder.choose(receiveA)
        let receiving = AhnaConnection(receive: true, profile: saved[0], configuration: config)
        receiving.state = ServerState(id: "phone-pc2", name: "Test Mac", hostName: "pc2", computerID: nil, owner: false, items: [], clipboard: nil)
        receiving.savePhotos = false
        let receivedOne = try await receiving.saveToFiles(InboxFile(id: "receive-a", name: "received.txt", bytes: 2))
        check(receivedOne.deletingLastPathComponent().path == receiveA.path, "URLSession download lands in chosen folder A")
        try ReceiveFolder.choose(receiveB)
        let receivedTwo = try await receiving.saveToFiles(InboxFile(id: "receive-b", name: "received.txt", bytes: 2))
        check(receivedTwo.deletingLastPathComponent().path == receiveB.path, "Next download uses changed folder B without restart")
        let one = try Data(contentsOf: receivedOne), two = try Data(contentsOf: receivedTwo)
        check(one == Data("{}".utf8) && two == one, "Both downloaded files retain exact server content")
        check(MockComputers.requests.contains { $0.1 == "/api/received/receive-b" }, "Windows receives acknowledgement after saving to selected folder")
        print("\(checks) connection checks passed")
    }
}
