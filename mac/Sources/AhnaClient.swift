import Foundation
import Combine
import UniformTypeIdentifiers
import Security
#if canImport(UIKit)
import UIKit
#endif

struct InboxFile: Decodable, Identifiable {
    let id: String
    let name: String
    let bytes: Int64
}
struct InboxClipboard: Decodable, Identifiable {
    let id: String
    let sender: String
    let bytes: Int
    let created: String
}
struct ServerState: Decodable {
    let id: String
    let name: String?
    let hostName: String?
    let computerID: String?
    let owner: Bool
    let items: [InboxFile]
    let clipboard: [InboxClipboard]?
}
struct PendingFile: Identifiable {
    let id = UUID()
    let url: URL
    let path: String
    let bytes: Int64
}
enum AhnaError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

@MainActor enum DeviceIdentity {
    static var defaultName: String {
        #if canImport(UIKit)
        return UIDevice.current.userInterfaceIdiom == .pad ? "나의 iPad" : "나의 iPhone"
        #else
        return "나의 Mac"
        #endif
    }
    static var savedName: String {
        if Bundle.main.object(forInfoDictionaryKey: "NSExtension") != nil,
           let name = try? ComputerVault.deviceName() { return name }
        return UserDefaults.standard.string(forKey: "deviceDisplayName") ?? defaultName
    }
    static func validate(_ value: String) throws -> String {
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
        guard !name.isEmpty, name.utf16.count <= 40, name.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw AhnaError.message("기기 이름은 1~40자로 입력하세요.")
        }
        return name
    }
}

struct ComputerProfile: Codable, Identifiable, Equatable {
    var id: UUID
    var address: String
    var hostName: String
    var computerID: String? = nil
    var token: String?
}

/// 연결 코드 한 번으로 양쪽을 연결할 때 주고받는, 연결을 요청한 기기 쪽 연결 정보(/api/pair 본문의 "reverse").
/// 받은 기기는 이것을 그 기기를 직접 추가한 것과 같은 연결로 저장합니다. 예전(1.0.x) 앱은 이 값을 무시합니다.
struct ReverseCredential: Equatable, Sendable {
    /// 그 기기가 연결된 NAS HTTPS 주소
    let address: String
    /// 그 기기 수신 쪽의 ID(X-Ahna-Computer)
    let computerID: String
    /// 그 기기에 만들어 둔 연결의 인증 값(ahna 쿠키)
    let token: String
    let name: String
    var json: [String: Any] { ["address": address, "computerID": computerID, "token": token, "name": name] }
    /// 받은 값을 검사합니다. 하나라도 형식이 맞지 않으면 nil(예전처럼 한쪽만 연결).
    static func validated(_ object: Any?) -> ReverseCredential? {
        guard let input = object as? [String: Any], let address = nasOrigin(input["address"] as? String),
              let identity = (input["computerID"] as? String)?.trimmingCharacters(in: .whitespaces), identity.count == 32, identity.allSatisfy({ $0.isASCII && $0.isHexDigit }),
              let token = (input["token"] as? String)?.trimmingCharacters(in: .whitespaces), (32...256).contains(token.count),
              token.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else { return nil }
        return ReverseCredential(address: address, computerID: identity.lowercased(), token: token, name: cleanName(input["name"] as? String, fallback: "기기"))
    }
    /// NAS HTTPS 주소(경로·질의·계정 정보 없음)를 끝의 / 없이 돌려줍니다.
    static func nasOrigin(_ value: String?) -> String? {
        guard let value, var components = URLComponents(string: value.trimmingCharacters(in: .whitespacesAndNewlines)), components.scheme?.lowercased() == "https",
              let host = components.host, !host.isEmpty, components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil, components.path.isEmpty || components.path == "/" else { return nil }
        components.path = ""
        return components.string
    }
    static func cleanName(_ value: String?, fallback: String) -> String {
        let visible = String((value ?? "").unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
        let name = String(visible.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        return name.isEmpty ? fallback : name
    }
}

/// 올리는 동안 보낸 바이트를 알려 줍니다(진행 막대).
final class UploadProgress: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let sent: @Sendable (Int64) -> Void
    init(_ sent: @escaping @Sendable (Int64) -> Void) { self.sent = sent }
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) { sent(totalBytesSent) }
}

final class NoAPIRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // Explicit per-PC cookies must never follow a redirect to a different server.
        completionHandler(nil)
    }
}

private struct SharedConfiguration: Codable, Equatable {
    var profiles: [ComputerProfile]
    var deviceName: String?
    /// 아나 서버 연결 토큰. 공유 메뉴가 근처 기기로 보낼 때 파일을 서버에 맡기는 데 씁니다.
    var memberToken: String?
}

// The containing app owns configuration; the share extension reads the same item.
// Never delete the old per-bundle entry during migration or silently fall back to
// separate storage if the installed signature lacks the shared access group.
enum ComputerVault {
    private static let cache = ConfigurationCache<SharedConfiguration>(read: {
        guard let data = try read(query) else { return nil }
        return try JSONDecoder().decode(SharedConfiguration.self, from: data)
    }, write: writeToKeychain)
    static func beginShareOperation() { cache.invalidate() }
    private static var legacyQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: (Bundle.main.bundleIdentifier ?? "아나") + ".computers",
         kSecAttrAccount as String: "paired-computers"]
    }
    private static var query: [String: Any] {
        get throws {
            return [kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: "Ahna.Mac.Configuration.v1",
                    kSecAttrAccount as String: "configuration"]
        }
    }
    private static func read(_ query: [String: Any]) throws -> Data? {
        var lookup = query
        lookup[kSecReturnData as String] = true
        var result: CFTypeRef?
        let code = SecItemCopyMatching(lookup as CFDictionary, &result)
        if code == errSecItemNotFound { return nil }
        guard code == errSecSuccess, let data = result as? Data else { throw AhnaError.message("공유 연결을 읽을 수 없습니다. 설치 서명의 공통 Keychain 권한 또는 기기 잠금 상태를 확인해 주세요. (\(code))") }
        return data
    }
    private static func configuration() throws -> SharedConfiguration? { try cache.value() }
    static func deviceName() throws -> String? { try configuration()?.deviceName }
    static func load() throws -> [ComputerProfile] {
        if let existing = try configuration() { return existing.profiles }
        // Only the containing app migrates its previous configuration. A share
        // extension opened first must not overwrite it with its old private list.
        if Bundle.main.object(forInfoDictionaryKey: "NSExtension") != nil { return [] }
        let profiles = try read(legacyQuery).map { try JSONDecoder().decode([ComputerProfile].self, from: $0) } ?? []
        try cache.update(default: SharedConfiguration(profiles: profiles, deviceName: UserDefaults.standard.string(forKey: "deviceDisplayName"))) { _ in }
        return profiles
    }
    static func save(_ profiles: [ComputerProfile]) throws {
        try cache.update(default: SharedConfiguration(profiles: [], deviceName: nil)) { $0.profiles = profiles }
    }
    static func memberToken() -> String? { ((try? configuration()) ?? nil)?.memberToken }
    static func saveMemberToken(_ token: String) throws {
        try cache.update(default: SharedConfiguration(profiles: [], deviceName: nil)) { $0.memberToken = token }
    }
    static func saveDeviceName(_ name: String) throws {
        try cache.update(default: SharedConfiguration(profiles: [], deviceName: nil)) { $0.deviceName = name }
    }
    private static func writeToKeychain(_ configuration: SharedConfiguration) throws {
        let itemQuery = try query
        let data = try JSONEncoder().encode(configuration)
        let attributes: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var code = SecItemUpdate(itemQuery as CFDictionary, attributes as CFDictionary)
        if code == errSecItemNotFound {
            code = SecItemAdd(itemQuery.merging(attributes) { _, new in new } as CFDictionary, nil)
        }
        guard code == errSecSuccess else { throw AhnaError.message("본체와 공유 메뉴의 공통 설정을 저장하지 못했습니다. 두 타깃의 서명에 같은 Keychain Sharing 그룹이 필요합니다. (\(code))") }
    }
}

@MainActor final class AhnaClient: ObservableObject {
    @Published var deviceName = DeviceIdentity.savedName
    @Published private(set) var deviceNameStatus = ""
    @Published var address = Brand.server
    @Published var pin = ""
    @Published private(set) var connections: [AhnaConnection] = []
    @Published var selectedID: UUID?
    @Published var status = "컴퓨터마다 6자리 코드를 입력해 추가하세요."
    @Published private var connecting = false
    @Published private var renaming = false
    @Published var autoSave = UserDefaults.standard.object(forKey: "autoSaveReceivedFiles") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoSave, forKey: "autoSaveReceivedFiles"); connections.forEach { $0.autoSave = autoSave } }
    }
    @Published var savePhotos = UserDefaults.standard.object(forKey: "savePhotosToLibrary") as? Bool ?? false {
        didSet { UserDefaults.standard.set(savePhotos, forKey: "savePhotosToLibrary"); connections.forEach { $0.savePhotos = savePhotos } }
    }
    private let receive: Bool
    private let saveProfiles: ([ComputerProfile]) throws -> Void
    private let configuration: URLSessionConfiguration
    private let usesSharedStorage: Bool
    private var subscriptions: [AnyCancellable] = []
    private var storageAvailable = true
    /// 이 기기 수신 쪽의 ID(상대가 X-Ahna-Computer로 보는 값). 연결·상태 확인 때 함께 보내
    /// 상대 기기가 이 기기를 목록에 한 번만 보여 줄 수 있게 합니다. 모르면 nil(예전과 같은 요청).
    var hostIdentity: String? { didSet { connections.forEach { $0.hostIdentity = hostIdentity } } }
    /// 연결 코드로 기기를 추가할 때 이 기기 수신 쪽에 상대 기기용 연결을 만들어 함께 보냅니다(한 번의 입력으로 양쪽 연결).
    /// 수신 쪽이 없거나 NAS에 연결되지 않았으면 nil을 돌려주고 예전처럼 한쪽만 연결합니다.
    var reverseOffer: (@MainActor () async -> ReverseCredential?)?
    /// 만든 연결을 상대가 받아 저장했으면 유지하고(이름·ID 반영), 아니면 지웁니다: (token, accepted, name, computerID)
    var reverseComplete: (@MainActor (String, Bool, String, String?) -> Void)?
    /// 그 기기가 이 기기에 연결한 쪽(수신 세션)이 남아 있는지. 상대가 이 기기의 연결을 해제했을 때 판단에 씁니다.
    var inboundExists: (@MainActor (AhnaConnection) -> Bool)?
    var selected: AhnaConnection? { connections.first { $0.id == selectedID } }
    var state: ServerState? { selected?.state }
    var busy: Bool { connecting || renaming || connections.contains { $0.busy } }
    var progress: String {
        get { selected?.progress ?? status }
        set { if let selected { selected.progress = newValue } else { status = newValue } }
    }
    var pollID: String { connections.map { $0.id.uuidString }.joined(separator: ",") }
    init(receive: Bool, profiles: [ComputerProfile]? = nil, deferStorage: Bool = false, saveProfiles: @escaping ([ComputerProfile]) throws -> Void = ComputerVault.save, configuration: URLSessionConfiguration = .ephemeral) {
        self.receive = receive
        usesSharedStorage = profiles == nil
        self.saveProfiles = saveProfiles; self.configuration = configuration
        do {
            let stored = try deferStorage ? [] : (profiles ?? ComputerVault.load())
            connections = stored.map { AhnaConnection(receive: receive, profile: $0, configuration: configuration) }
            // Upgrade the old single-origin cookie without discarding its pairing.
            if receive, !deferStorage, profiles == nil, !UserDefaults.standard.bool(forKey: "multiComputerMigrationComplete"), connections.isEmpty, let url = URL(string: address),
               let cookie = HTTPCookieStorage.shared.cookies(for: url)?.first(where: { $0.name == "ahna" && ($0.expiresDate ?? .distantFuture) > Date() }) {
                let profile = ComputerProfile(id: UUID(), address: address, hostName: "기존 Windows", token: cookie.value)
                connections = [AhnaConnection(receive: receive, profile: profile, configuration: configuration)]
                try persist()
            }
            if receive, !deferStorage, profiles == nil { UserDefaults.standard.set(true, forKey: "multiComputerMigrationComplete") }
            selectedID = connections.first?.id
            observeConnections()
        } catch { storageAvailable = false; status = error.localizedDescription }
    }
    func restoreConfiguration() async {
        do {
            let (profiles, name) = try await Task.detached {
                (try ComputerVault.load(), try ComputerVault.deviceName())
            }.value
            if let name { deviceName = name; UserDefaults.standard.set(name, forKey: "deviceDisplayName") }
            connections = profiles.map { AhnaConnection(receive: receive, profile: $0, configuration: configuration) }
            selectedID = connections.first?.id; storageAvailable = true; observeConnections()
            status = "저장된 컴퓨터 연결을 불러왔습니다."
        } catch { storageAvailable = false; status = error.localizedDescription }
    }
    private func persist() throws { try saveProfiles(connections.map { $0.profile }) }
    private func observeConnections() {
        subscriptions = connections.map { connection in
            connection.hostIdentity = hostIdentity
            connection.credentialsChanged = { [weak self] in
                guard let self, self.receive else { return }
                try self.persist()
            }
            connection.revokedChanged = { [weak self, weak connection] in
                guard let self, let connection else { return }
                self.dropRevoked(connection)
            }
            return connection.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        }
    }
    func connect() async {
        guard !busy else { status = "이전 작업이 끝난 뒤 다시 눌러 주세요."; return }
        guard storageAvailable else { status = "연결 저장소를 사용할 수 없습니다. 앱을 다시 열어 주세요."; return }
        connecting = true; defer { connecting = false }
        let connection = AhnaConnection(receive: receive, configuration: configuration)
        connection.hostIdentity = hostIdentity
        status = "기기 등록 중…"
        connection.address = address.trimmingCharacters(in: .whitespacesAndNewlines); connection.pin = pin.trimmingCharacters(in: .whitespacesAndNewlines)
        // 한 번의 코드 입력으로 양쪽 모두 연결: 이 기기 쪽 연결을 함께 보냅니다. 상대가 저장했다고 답하면 유지합니다.
        var offer: ReverseCredential? = nil
        if receive, let make = reverseOffer { offer = await make() }
        connection.reverse = offer
        await connection.connect()
        let paired = connection.token != nil && connection.state != nil
        if let offer { reverseComplete?(offer.token, paired && connection.reverseAccepted, connection.hostName, connection.computerID) }
        guard paired else { status = connection.status; return }
        // Re-pairing one PC replaces only that PC's credentials.
        let duplicate = connections.firstIndex {
            if let id = $0.computerID, let incoming = connection.computerID { return id == incoming }
            return (try? $0.endpoint("/").absoluteString.lowercased()) == (try? connection.endpoint("/").absoluteString.lowercased()) && $0.computerID == connection.computerID
        }
        if let duplicate { connections[duplicate] = connection } else { connections.append(connection) }
        selectedID = connection.id; pin = ""; status = connection.status
        observeConnections()
        do { try persist() } catch { status = error.localizedDescription }
    }
    func saveDeviceName() async {
        guard !busy else { return }
        renaming = true; defer { renaming = false }
        do {
            let name = try DeviceIdentity.validate(deviceName)
            if usesSharedStorage { try ComputerVault.saveDeviceName(name) }
            deviceName = name
            UserDefaults.standard.set(name, forKey: "deviceDisplayName")
            // Update every saved PC, including ones currently offline. Polling
            // sends the new name again once that PC becomes reachable.
            connections.forEach { $0.deviceName = name }
            var pending = false
            var needsUpdate = false
            for connection in connections {
                do {
                    try await connection.refresh(updatingName: true)
                    if connection.state?.name != connection.pairingDeviceName { needsUpdate = true }
                } catch { pending = true }
            }
            if needsUpdate { deviceNameStatus = "이름을 저장했습니다. PC의 아나를 0.4.3 이상으로 업데이트하면 목록에 반영됩니다." }
            else if pending { deviceNameStatus = "이름을 저장했습니다. 오프라인 컴퓨터는 다시 연결되면 반영됩니다." }
            else { deviceNameStatus = "기기 이름을 저장했습니다." }
        } catch { deviceNameStatus = error.localizedDescription }
    }
    func forget(_ connection: AhnaConnection) async {
        guard !busy else { status = "이전 작업이 끝난 뒤 다시 눌러 주세요."; return }
        guard storageAvailable else { status = "연결 저장소를 사용할 수 없습니다. 앱을 다시 열어 주세요."; return }
        // Save first: an offline PC must never make the other saved pairings disappear.
        let remaining = connections.filter { $0.id != connection.id }
        do { try saveProfiles(remaining.map { $0.profile }) }
        catch { status = error.localizedDescription; return }
        connection.credentialsChanged = nil
        connections = remaining
        if selectedID == connection.id { selectedID = remaining.first?.id }
        observeConnections()
        await connection.disconnect()
        status = "이 컴퓨터의 연결을 삭제했습니다. 다시 추가할 때는 코드가 필요합니다."
    }
    /// 상대 기기가 이 기기에서 추가한 연결을 해제했을 때(401). 그 기기가 이 기기에 연결한 쪽이 남아 있으면 죽은 연결만
    /// 조용히 지우고 그쪽으로 주고받습니다. 없으면 오프라인과 “다시 추가하세요” 한 줄만 보입니다.
    func dropRevoked(_ connection: AhnaConnection) {
        guard receive, storageAvailable, connection.revoked, connections.contains(where: { $0 === connection }),
              inboundExists?(connection) == true else { return }
        let remaining = connections.filter { $0 !== connection }
        do { try saveProfiles(remaining.map { $0.profile }) } catch { return }
        connection.credentialsChanged = nil; connection.revokedChanged = nil
        connections = remaining
        if selectedID == connection.id { selectedID = remaining.first?.id }
        observeConnections()
    }
    /// 상대 기기가 이 기기의 연결 코드로 연결하면서 넘겨준 그 기기 쪽 연결을, 그 기기를 직접 추가한 것과 같게 저장합니다.
    /// 같은 기기(수신 ID)가 이미 있으면 그 연결의 주소·인증 값만 바꿉니다. 공유 메뉴도 같은 저장소를 읽습니다.
    func addReverse(_ credential: ReverseCredential) {
        guard receive, storageAvailable else { return }
        if let existing = connections.first(where: { ($0.computerID ?? "").lowercased() == credential.computerID }) {
            existing.address = credential.address; existing.token = credential.token
            if existing.hostName.isEmpty || existing.revoked { existing.hostName = credential.name }
            existing.markRestored()
        } else {
            let profile = ComputerProfile(id: UUID(), address: credential.address, hostName: credential.name, computerID: credential.computerID, token: credential.token)
            connections.append(AhnaConnection(receive: receive, profile: profile, configuration: configuration))
            if selectedID == nil { selectedID = connections.last?.id }
            observeConnections()
        }
        do { try persist() } catch { status = error.localizedDescription }
    }
    func poll() async {
        await withTaskGroup(of: Void.self) { group in
            for connection in connections { group.addTask { await connection.poll() } }
            await group.waitForAll()
        }
    }
    func sendClipboard(_ text: String) async throws {
        guard !busy, let selected else { throw AhnaError.message("컴퓨터를 선택하고 연결을 확인하세요.") }
        try await selected.sendClipboard(text)
    }
    @discardableResult func send(_ files: [PendingFile], completion: (() -> Void)? = nil) -> Bool { selected?.send(files, completion: completion) ?? false }
    func cancel() { connections.filter { $0.busy }.forEach { $0.cancel() } }
    func savedURL(_ file: InboxFile) -> URL? { selected?.savedURL(file) }
    func isInPhotos(_ file: InboxFile) -> Bool { selected?.isInPhotos(file) ?? false }
    @discardableResult func saveToFiles(_ file: InboxFile) async throws -> URL {
        guard let selected else { throw AhnaError.message("컴퓨터를 선택하세요.") }
        return try await selected.saveToFiles(file)
    }
}

// Both targets use one pairing, but only the containing app advertises receiving.
@MainActor final class AhnaConnection: ObservableObject, Identifiable {
    var deviceName = DeviceIdentity.savedName
    let id: UUID
    var computerID: String?
    var token: String?
    var hostName: String
    /// 이 기기 수신 쪽의 ID. 상대 기기는 이 값으로 같은 기기의 두 연결을 하나로 보여 줍니다.
    var hostIdentity: String?
    private var reportedIdentity: String? {
        guard let hostIdentity, hostIdentity.count == 32, hostIdentity.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { return nil }
        return hostIdentity.lowercased()
    }
    var credentialsChanged: (() throws -> Void)?
    /// 상대 기기가 이 연결을 해제한 것을 상태 확인에서 알았을 때 부릅니다.
    var revokedChanged: (@MainActor () -> Void)?
    /// 상대 기기에서 이 연결을 해제함(인증 값이 더 이상 맞지 않음, 401). 다시 연결되면 false.
    @Published private(set) var revoked = false
    static let revokedMessage = "상대 기기에서 연결을 해제했습니다 · 다시 추가하세요"
    /// 연결 코드로 추가할 때 함께 보낼 이 기기 쪽 연결(없으면 보내지 않음)과, 상대가 받아 저장했는지.
    var reverse: ReverseCredential?
    private(set) var reverseAccepted = false
    @Published var address: String = Brand.server
    @Published var pin = ""
    @Published var state: ServerState?
    @Published var status = "상대 기기와 연결해 주세요."
    @Published var busy = false
    @Published var progress = ""
    /// 보내는 중 진행률(0~1). 보내지 않을 때는 nil
    @Published var fraction: Double?
    @Published var autoSave = UserDefaults.standard.object(forKey: "autoSaveReceivedFiles") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoSave, forKey: "autoSaveReceivedFiles") }
    }
    @Published private(set) var savedRevision = 0
    @Published var savePhotos = UserDefaults.standard.object(forKey: "savePhotosToLibrary") as? Bool ?? false {
        didSet { UserDefaults.standard.set(savePhotos, forKey: "savePhotosToLibrary") }
    }
    private let receive: Bool
    private let session: URLSession
    private var work: Task<Void, Never>?
    private static var sharedReceivedFiles: ReceivedFileStore?
    private var receivedFiles: ReceivedFileStore? { Self.sharedReceivedFiles }
    private var pausedAutomaticReceives = Set<String>()
    init(receive: Bool, profile: ComputerProfile? = nil, configuration: URLSessionConfiguration = .ephemeral) {
        self.receive = receive
        id = profile?.id ?? UUID(); computerID = profile?.computerID
        token = profile?.token; hostName = profile?.hostName ?? "Windows"
        let config = configuration
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 45 * 60
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        // A NAS origin can host several PCs. Never share their authentication cookies.
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        session = URLSession(configuration: config, delegate: NoAPIRedirects(), delegateQueue: nil)
        if let profile { address = profile.address }
        if receive { do { _ = try fileStore() } catch { progress = "자동 저장 준비 실패 · \(error.localizedDescription)" } }
    }
    // 큰 파일 나눠 올리기: Cloudflare 같은 프록시는 요청 하나를 100MB로 제한합니다.
    // 첫 조각에 X-Ahna-Total(전체 크기)을 붙이면 서버가 받는 기기로는 한 파일처럼 이어 보내고, 나머지는 /_ahna/chunk로 받습니다.
    static let chunkSize: Int64 = 50 * 1024 * 1024
    private func uploadChunked(_ first: URLRequest, file: URL, bytes: Int64, sent: ((Int64) -> Void)? = nil) async throws -> (Data, URLResponse) {
        let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
        var offset: Int64 = 0, upload = ""
        while true {
            try Task.checkCancellation()
            let piece = try handle.read(upToCount: Int(min(Self.chunkSize, bytes - offset))) ?? Data()
            guard !piece.isEmpty else { throw AhnaError.message("파일을 끝까지 읽지 못했습니다.") }
            var request: URLRequest
            if offset == 0 { request = first; request.setValue(String(bytes), forHTTPHeaderField: "X-Ahna-Total") }
            else {
                request = try self.request("/_ahna/chunk/" + upload); request.httpMethod = "PUT"
                request.setValue(String(offset), forHTTPHeaderField: "X-Ahna-Offset")
                request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            }
            request.setValue(String(piece.count), forHTTPHeaderField: "Content-Length")
            let (data, response) = try await session.upload(for: request, from: piece)
            offset += Int64(piece.count); sent?(offset)
            if offset >= bytes { return (data, response) }
            guard (response as? HTTPURLResponse)?.statusCode == 202,
                  let id = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["upload"] as? String else {
                try verify(response, data: data); throw AhnaError.message("서버가 큰 파일 나눠 올리기를 지원하지 않습니다. 서버를 업데이트하세요.")
            }
            upload = id
        }
    }
    func endpoint(_ path: String) throws -> URL {
        guard var components = URLComponents(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              components.path.isEmpty || components.path == "/" else { throw AhnaError.message("서버의 HTTPS 주소를 입력하세요.") }
        let octets = host.split(separator: ".").compactMap { Int($0) }
        let privateIPv4 = octets.count == 4 && octets.allSatisfy { (0...255).contains($0) } && (octets[0] == 10 || octets[0] == 192 && octets[1] == 168 || octets[0] == 172 && (16...31).contains(octets[1]))
        let local = host == "localhost" || host.hasSuffix(".local") || privateIPv4
        guard components.scheme == "https" else { throw AhnaError.message("외부 연결에는 HTTPS 주소가 필요합니다.") }
        components.path = "/"
        guard let base = components.url, let result = URL(string: path, relativeTo: base)?.absoluteURL,
              result.host == base.host, result.scheme == base.scheme, result.port == base.port else { throw AhnaError.message("올바르지 않은 주소입니다.") }
        return result
    }
    private func request(_ path: String, authenticated: Bool = true) throws -> URLRequest {
        var result = URLRequest(url: try endpoint(path))
        if let computerID { result.setValue(computerID, forHTTPHeaderField: "X-Ahna-Computer") }
        if authenticated, let token { result.setValue("ahna=" + token, forHTTPHeaderField: "Cookie") }
        return result
    }
    var profile: ComputerProfile { ComputerProfile(id: id, address: address, hostName: hostName, computerID: computerID, token: token) }
    private func verify(_ response: URLResponse, data: Data? = nil) throws {
        guard let response = response as? HTTPURLResponse else { throw AhnaError.message("서버 응답을 읽을 수 없습니다.") }
        guard (200..<300).contains(response.statusCode) else {
            if response.statusCode == 401 {
                state = nil
                if token != nil { revoked = true; throw AhnaError.message(Self.revokedMessage) }
                throw AhnaError.message("연결 코드를 확인하거나 다시 연결해 주세요.")
            }
            if response.statusCode == 503 || response.statusCode == 502 || response.statusCode == 504 { state = nil; throw AhnaError.message("서버가 상대 기기로 요청을 전달하지 못했습니다. (HTTP \(response.statusCode)) 상대 기기와 서버 연결을 확인하세요.") }
            let text = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] }?["error"]
            throw AhnaError.message(text ?? "요청 실패 (\(response.statusCode))")
        }
    }
    func connect() async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        do {
            guard pin.count == 6, pin.allSatisfy(\.isNumber) else { throw AhnaError.message("상대 기기의 6자리 연결 코드를 입력하세요.") }
            deviceName = try DeviceIdentity.validate(deviceName)
            var request = try request("/api/pair", authenticated: false)
            request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            var pairing: [String: Any] = ["pin": pin, "name": pairingDeviceName, "native": true, "canReceive": receive]
            if let reportedIdentity { pairing["computerID"] = reportedIdentity }
            if let reverse { pairing["reverse"] = reverse.json }
            request.httpBody = try JSONSerialization.data(withJSONObject: pairing)
            let (data, response) = try await session.data(for: request)
            try verify(response, data: data)
            guard let http = response as? HTTPURLResponse,
                  let cookieHeader = http.value(forHTTPHeaderField: "Set-Cookie"),
                  let url = http.url,
                  let cookie = HTTPCookie.cookies(withResponseHeaderFields: ["Set-Cookie": cookieHeader], for: url).first(where: { $0.name == "ahna" })
            else { throw AhnaError.message("연결 인증을 저장할 수 없습니다.") }
            token = cookie.value
            let paired = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let identity = (paired?["computerID"] as? String) ?? http.value(forHTTPHeaderField: "X-Ahna-Computer")
            if let identity, identity.count == 32, identity.allSatisfy({ $0.isASCII && $0.isHexDigit }) { computerID = identity }
            reverseAccepted = reverse != nil && (paired?["reverse"] as? Bool) == true
            UserDefaults.standard.set(address.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "server")
            pin = ""; try credentialsChanged?(); try await refresh()
        } catch { status = error.localizedDescription }
    }
    var pairingDeviceName: String {
        deviceName
    }
    func refresh(updatingName: Bool = false) async throws {
        var stateRequest = try request("/api/state")
        var components = URLComponents(url: stateRequest.url!, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "receiving", value: receive ? "true" : "false")]
        // A share window already open during a rename must not publish its stale
        // cached name over the containing app's newly saved configuration.
        if receive || updatingName { components.queryItems?.append(URLQueryItem(name: "deviceName", value: pairingDeviceName)) }
        // Older hosts ignore this; newer ones learn which of their paired devices this is.
        if receive, let reportedIdentity { components.queryItems?.append(URLQueryItem(name: "computerID", value: reportedIdentity)) }
        stateRequest.url = components.url
        let (data, response) = try await session.data(for: stateRequest)
        try verify(response, data: data)
        let result = try JSONDecoder().decode(ServerState.self, from: data)
        guard !result.owner else { throw AhnaError.message("iPhone에는 일반 기기 연결을 사용하세요.") }
        let previousProfile = profile
        hostName = result.hostName ?? "Windows"
        if let identity = result.computerID, identity.count == 32, identity.allSatisfy({ $0.isASCII && $0.isHexDigit }) { computerID = identity }
        else if let http = response as? HTTPURLResponse { computerID = http.value(forHTTPHeaderField: "X-Ahna-Computer") ?? computerID }
        if profile != previousProfile { try credentialsChanged?() }
        state = result; status = "연결됨 · \(hostName)"; revoked = false
    }
    /// 새 인증 값을 받은 뒤: 해제 표시를 지우고 다음 상태 확인에서 다시 연결합니다.
    func markRestored() { revoked = false; status = "연결 확인 중…" }
    func poll() async {
        while !Task.isCancelled {
            do {
                if !busy { try await refresh(); await receiveAutomatically() }
            } catch is CancellationError { return } catch {
                state = nil
                if revoked { status = Self.revokedMessage; revokedChanged?() }
                else { status = error.localizedDescription + " · 자동 재연결 대기" }
            }
            do { try await Task.sleep(nanoseconds: 3_000_000_000) } catch { return }
        }
    }
    func sendClipboard(_ text: String) async throws {
        guard !busy, state != nil else { throw AhnaError.message("컴퓨터 연결을 확인한 뒤 다시 시도하세요.") }
        guard state?.clipboard != nil else { throw AhnaError.message("컴퓨터의 아나를 0.4.8 이상으로 업데이트하세요.") }
        guard !text.isEmpty, !text.contains("\0"), text.utf8.count <= 65536 else { throw AhnaError.message("보낼 글자를 붙여넣어 주세요. 최대 64 KB까지 보낼 수 있습니다.") }
        busy = true; defer { busy = false }
        var request = try request("/api/upload?kind=clipboard&batch=" + UUID().uuidString)
        request.httpMethod = "POST"; request.httpBody = Data(text.utf8)
        request.setValue("text/plain; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue(String(text.utf8.count), forHTTPHeaderField: "Content-Length")
        let (data, response) = try await session.data(for: request)
        try verify(response, data: data)
        progress = "\(hostName)에 글자를 보냈습니다. 컴퓨터의 클립보드 창에서 ‘복사’를 누르세요."
    }
    func clipboardText(_ item: InboxClipboard) async throws -> String {
        guard state?.clipboard?.contains(where: { $0.id == item.id }) == true else { throw AhnaError.message("받은 글자를 다시 확인하세요.") }
        let (data, response) = try await session.data(for: request("/api/download/" + item.id + "?kind=clipboard"))
        try verify(response, data: data)
        guard data.count <= 65536, data.count == item.bytes, let text = String(data: data, encoding: .utf8), !text.isEmpty, !text.contains("\0") else { throw AhnaError.message("받은 글자를 읽을 수 없습니다.") }
        return text
    }
    @discardableResult func send(_ files: [PendingFile], completion: (() -> Void)? = nil) -> Bool {
        guard !busy, state != nil, !files.isEmpty else { return false }
        busy = true
        fraction = 0
        let total = Double(max(1, files.reduce(Int64(0)) { $0 + max($1.bytes, 1) }))
        work = Task {
            defer { busy = false; work = nil; fraction = nil }
            do {
                let batch = UUID().uuidString
                var done: Int64 = 0
                for (index, file) in files.enumerated() {
                    try Task.checkCancellation()
                    progress = "\(index + 1)/\(files.count) · \(file.path)"
                    var components = URLComponents(url: try endpoint("/api/upload"), resolvingAgainstBaseURL: false)!
                    components.queryItems = [URLQueryItem(name: "batch", value: batch), URLQueryItem(name: "path", value: file.path)]
                    var request = try request("/api/upload")
                    request.url = components.url!
                    request.httpMethod = "POST"
                    request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
                    request.setValue(String(file.bytes), forHTTPHeaderField: "Content-Length")
                    let base = done
                    let watcher = UploadProgress { [weak self] sent in
                        Task { @MainActor in self?.fraction = min(1, Double(base + sent) / total) }
                    }
                    let (data, response) = file.bytes > Self.chunkSize
                        ? try await uploadChunked(request, file: file.url, bytes: file.bytes) { [weak self] sent in self?.fraction = min(1, Double(base + sent) / total) }
                        : try await session.upload(for: request, fromFile: file.url, delegate: watcher)
                    try verify(response, data: data)
                    done += max(file.bytes, 1); fraction = min(1, Double(done) / total)
                }
                progress = "\(files.count)개 파일을 \(hostName)에 저장했습니다."
                completion?()
            } catch is CancellationError { progress = "전송을 중단했습니다. 완료된 파일은 유지됩니다." }
            catch let error as URLError where error.code == .cancelled { progress = "전송을 중단했습니다. 완료된 파일은 유지됩니다." }
            catch { progress = error.localizedDescription }
        }
        return true
    }
    func cancel() {
        if let state { for file in state.items { if let key = try? receiptKey(file) { pausedAutomaticReceives.insert(key) } } }
        work?.cancel(); session.getAllTasks { tasks in for task in tasks { task.cancel() } }
    }
    private func fileStore() throws -> ReceivedFileStore {
        let documents = ReceiveFolder.currentURL()
        if let receivedFiles, receivedFiles.directory.standardizedFileURL == documents.standardizedFileURL { return receivedFiles }
        try ReceiveFolder.prepare(documents, isDefault: UserDefaults.standard.string(forKey: ReceiveFolder.preferenceKey) == nil)
        let metadata = try ReceiveFolder.metadataURL(for: documents)
        let store = try ReceivedFileStore(directory: documents, metadata: metadata)
        Self.sharedReceivedFiles = store
        return store
    }
    private func receiptKey(_ file: InboxFile) throws -> String {
        guard let state else { throw AhnaError.message("Windows에 먼저 연결해 주세요.") }
        return try endpoint("/").absoluteString.lowercased() + "|" + state.id + "|" + file.id
    }
    func savedURL(_ file: InboxFile) -> URL? {
        guard let key = try? receiptKey(file) else { return nil }
        return receivedFiles?.savedURL(for: key)
    }
    private func receiveAutomatically() async {
        guard receive, autoSave, !busy, let state else { return }
        for file in state.items {
            guard autoSave, !Task.isCancelled else { return }
            do {
                let key = try receiptKey(file)
                let store = try fileStore()
                if pausedAutomaticReceives.contains(key) { continue }
                if store.hasReceived(key) {
                    if let url = store.savedURL(for: key) { await acknowledge(file, key: key, url: url) }
                    continue
                }
                _ = try await saveToFiles(file)
            } catch is CancellationError { return }
            catch let error as URLError where error.code == .cancelled { progress = "수신을 중단했습니다. ‘지금 저장’으로 다시 받을 수 있습니다."; return }
            catch { progress = "자동 저장 실패 · \(error.localizedDescription)"; return }
        }
    }
    @discardableResult func saveToFiles(_ file: InboxFile) async throws -> URL {
        guard receive, !busy else { throw AhnaError.message("현재 전송이 끝난 뒤 다시 시도해 주세요.") }
        let key = try receiptKey(file)
        let store = try fileStore()
        busy = true; defer { busy = false }
        if let existing = store.savedURL(for: key) {
            await finishSaving(file, key: key, url: existing)
            return existing
        }
        progress = "받는 중 · \(file.name)"
        let (temporary, response) = try await session.download(for: request("/api/download/" + file.id))
        defer { try? FileManager.default.removeItem(at: temporary) }
        try verify(response)
        try Task.checkCancellation()
        let destination = try store.save(temporary: temporary, name: file.name, bytes: file.bytes, key: key)
        ReceiveHistory.shared.record(id: key, url: destination, source: hostName)
        savedRevision += 1
        pausedAutomaticReceives.remove(key)
        progress = "저장 완료 · \(destination.path)"
        await finishSaving(file, key: key, url: destination)
        return destination
    }
    func isInPhotos(_ file: InboxFile) -> Bool {
        guard let key = try? receiptKey(file) else { return false }
        return receivedFiles?.photosSaved(key) == true
    }
    private func finishSaving(_ file: InboxFile, key: String, url: URL) async {
        do {
            let store = try fileStore()
            if savePhotos, PhotoLibrarySaver.isMedia(url), !store.photosSaved(key) {
                try Task.checkCancellation()
                try await PhotoLibrarySaver.save(url)
                try store.markPhotosSaved(key)
                savedRevision += 1
                progress = "사진 앱에 저장 완료 · \(file.name)"
            }
        } catch { progress = "파일 저장 완료 · 사진 앱 추가 실패\n\(error.localizedDescription)" }
        await acknowledge(file, key: key, url: url)
    }
    private func acknowledge(_ file: InboxFile, key: String, url: URL) async {
        do {
            let store = try fileStore()
            let destination = store.photosSaved(key) ? "photos" : "files"
            guard store.acknowledgedStatus(key) != destination else { return }
            var request = try request("/api/received/" + file.id)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["destination": destination])
            let (data, response) = try await session.data(for: request)
            try verify(response, data: data)
            try store.markAcknowledged(key, status: destination)
        } catch {
            // Local file/Photos storage succeeded; retry the receipt on a later poll.
            // A Windows/NAS update is needed if the old server returns 404.
        }
    }
    func disconnect() async {
        do {
            var request = try request("/api/logout"); request.httpMethod = "POST"; request.httpBody = Data("{}".utf8)
            _ = try await session.data(for: request)
        } catch { }
        state = nil; status = "연결 해제됨"
    }
}

enum FilePreparation {
    static let maxFile: Int64 = 4 * 1024 * 1024 * 1024
    static func collect(_ urls: [URL]) throws -> [PendingFile] {
        var files: [PendingFile] = []; var count = 0
        func walk(_ url: URL, path: String, depth: Int) throws {
            count += 1
            guard count <= 10000, depth <= 64 else { throw AhnaError.message("폴더 항목이 너무 많거나 깊습니다.") }
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .isRegularFileKey])
            guard values.isSymbolicLink != true else { throw AhnaError.message("심볼릭 링크는 전송할 수 없습니다.") }
            if values.isDirectory == true {
                for child in try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) {
                    try walk(child, path: path + "/" + child.lastPathComponent, depth: depth + 1)
                }
            } else {
                guard values.isRegularFile == true else { throw AhnaError.message("일반 파일만 보낼 수 있습니다.") }
                let bytes = Int64(values.fileSize ?? 0)
                guard bytes <= maxFile else { throw AhnaError.message("파일 한 개는 최대 4 GiB까지 보낼 수 있습니다.") }
                files.append(PendingFile(url: url, path: path, bytes: bytes))
            }
        }
        for url in urls { try walk(url, path: url.lastPathComponent, depth: 0) }
        guard !files.isEmpty else { throw AhnaError.message("전송할 파일이 없습니다. 빈 폴더는 전송하지 않습니다.") }
        return files
    }
}
