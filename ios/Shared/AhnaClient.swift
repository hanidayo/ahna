import Foundation
import Combine
import UniformTypeIdentifiers
import Security
import ImageIO
#if os(macOS)
import CryptoKit
#endif
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
    static var savedName: String { (try? ComputerVault.deviceName()) ?? UserDefaults.standard.string(forKey: "deviceDisplayName") ?? defaultName }
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
    /// 그 기기가 연결된 서버 HTTPS 주소
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
    /// 서버 HTTPS 주소(경로·질의·계정 정보 없음)를 끝의 / 없이 돌려줍니다.
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

final class NoAPIRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // Explicit per-PC cookies must never follow a redirect to a different server.
        completionHandler(nil)
    }
}

private struct SharedConfiguration: Codable {
    var profiles: [ComputerProfile]
    var deviceName: String?
    /// 사진을 JPG로 보내기 (없으면 켜짐). 본체 앱이 저장하고 공유 메뉴도 읽습니다.
    var photosAsJPG: Bool?
    /// 아나 서버 가입 토큰. 공유 메뉴가 근처 기기로 보낼 때 파일을 서버에 맡기는 데 씁니다.
    var memberToken: String?
}

/// 아이폰 HEIC 사진을 어느 컴퓨터에서나 열리는 JPG로 바꿉니다(촬영 정보·방향 유지). HEIC가 아니면 그대로 돌려줍니다.
enum PhotoJPEG {
    static func isHEIC(_ url: URL) -> Bool { ["heic", "heif", "hif"].contains(url.pathExtension.lowercased()) }
    static func convertIfNeeded(_ url: URL) -> URL {
        guard isHEIC(url), let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0 else { return url }
        let target = url.deletingPathExtension().appendingPathExtension("jpg")
        guard !FileManager.default.fileExists(atPath: target.path),
              let destination = CGImageDestinationCreateWithURL(target as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return url }
        CGImageDestinationAddImageFromSource(destination, source, 0, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { try? FileManager.default.removeItem(at: target); return url }
        try? FileManager.default.removeItem(at: url)
        return target
    }
}

// The containing app owns configuration; the share extension reads the same item.
// Never delete the old per-bundle entry during migration or silently fall back to
// separate storage if the installed signature lacks the shared access group.
enum ComputerVault {
    private static var legacyQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: (Bundle.main.bundleIdentifier ?? "아나") + ".computers",
         kSecAttrAccount as String: "paired-computers"]
    }
    private static var query: [String: Any] {
        get throws {
            let group: String
            do { group = try InstalledKeychainGroups.resolved.get() }
            catch { throw AhnaError.message("설치 서명에 본체·공유 메뉴의 공통 Keychain 그룹을 확인할 수 없습니다. 설치 도구의 서명 권한을 확인해 주세요. (-34018)") }
            return [kSecClass as String: kSecClassGenericPassword,
                    kSecUseDataProtectionKeychain as String: true,
                    kSecAttrService as String: "Ahna.SharedConfiguration.v1",
                    kSecAttrAccount as String: "configuration",
                    kSecAttrAccessGroup as String: group]
        }
    }
    private static func read(_ query: [String: Any]) throws -> Data? {
        var lookup = query
        lookup[kSecReturnData as String] = true
        var result: CFTypeRef?
        let code = SecItemCopyMatching(lookup as CFDictionary, &result)
        if code == errSecItemNotFound { return nil }
        guard code == errSecSuccess, let data = result as? Data else { throw AhnaError.message("공유 연결을 읽을 수 없습니다. 기기 잠금을 해제하고 본체 앱을 먼저 열어 주세요. (\(code))") }
        return data
    }
    private static func configuration() throws -> SharedConfiguration? {
        guard let data = try read(query) else { return nil }
        return try JSONDecoder().decode(SharedConfiguration.self, from: data)
    }
    static func deviceName() throws -> String? { try configuration()?.deviceName }
    static func memberToken() -> String? { ((try? configuration()) ?? nil)?.memberToken }
    static func saveMemberToken(_ token: String) throws {
        var config = try configuration() ?? SharedConfiguration(profiles: [], deviceName: nil)
        if config.memberToken == token { return }
        config.memberToken = token
        try write(config)
    }
    static func photosAsJPG() -> Bool { ((try? configuration()) ?? nil)?.photosAsJPG ?? true }
    static func savePhotosAsJPG(_ on: Bool) throws {
        var config = try configuration() ?? SharedConfiguration(profiles: [], deviceName: nil)
        config.photosAsJPG = on
        try write(config)
    }
    static func load() throws -> [ComputerProfile] {
        if let existing = try configuration() { return existing.profiles }
        // Only the containing app migrates its previous configuration. A share
        // extension opened first must not overwrite it with its old private list.
        if Bundle.main.object(forInfoDictionaryKey: "NSExtension") != nil { return [] }
        let profiles = try read(legacyQuery).map { try JSONDecoder().decode([ComputerProfile].self, from: $0) } ?? []
        try write(SharedConfiguration(profiles: profiles, deviceName: UserDefaults.standard.string(forKey: "deviceDisplayName")))
        return profiles
    }
    static func save(_ profiles: [ComputerProfile]) throws {
        var config = try configuration() ?? SharedConfiguration(profiles: [], deviceName: nil)
        if config.profiles == profiles { return }
        config.profiles = profiles
        try write(config)
    }
    static func saveDeviceName(_ name: String) throws {
        var config = try configuration() ?? SharedConfiguration(profiles: [], deviceName: nil)
        config.deviceName = name
        try write(config)
    }
    private static func write(_ configuration: SharedConfiguration) throws {
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
    @Published var address = (Brand.ahna ? Brand.server : UserDefaults.standard.string(forKey: "server") ?? "https://example.synology.me")
    @Published var pin = ""
    @Published private(set) var connections: [AhnaConnection] = []
    @Published var selectedID: UUID?
    @Published var status = "컴퓨터마다 6자리 코드를 입력해 추가하세요."
    @Published private var connecting = false
    @Published private var renaming = false
    @Published var autoSave = UserDefaults.standard.object(forKey: "autoSaveReceivedFiles") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoSave, forKey: "autoSaveReceivedFiles"); connections.forEach { $0.autoSave = autoSave } }
    }
    @Published var savePhotos = UserDefaults.standard.object(forKey: "savePhotosToLibrary") as? Bool ?? true {
        didSet { UserDefaults.standard.set(savePhotos, forKey: "savePhotosToLibrary"); connections.forEach { $0.savePhotos = savePhotos } }
    }
    /// 사진을 JPG로 보내기(HEIC → JPG, HEVC 영상 → H.264). 공유 메뉴도 같은 값을 씁니다.
    @Published var photosAsJPG = ComputerVault.photosAsJPG() {
        didSet { try? ComputerVault.savePhotosAsJPG(photosAsJPG) }
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
    /// 수신 쪽이 없거나 서버에 연결되지 않았으면 nil을 돌려주고 예전처럼 한쪽만 연결합니다.
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
    init(receive: Bool, profiles: [ComputerProfile]? = nil, saveProfiles: @escaping ([ComputerProfile]) throws -> Void = ComputerVault.save, configuration: URLSessionConfiguration = .ephemeral) {
        self.receive = receive
        usesSharedStorage = profiles == nil
        self.saveProfiles = saveProfiles; self.configuration = configuration
        do {
            let stored = try profiles ?? ComputerVault.load()
            connections = stored.map { AhnaConnection(receive: receive, profile: $0, configuration: configuration) }
            // Upgrade the old single-origin cookie without discarding its pairing.
            if receive, profiles == nil, !UserDefaults.standard.bool(forKey: "multiComputerMigrationComplete"), connections.isEmpty, let url = URL(string: address),
               let cookie = HTTPCookieStorage.shared.cookies(for: url)?.first(where: { $0.name == "ahna" && ($0.expiresDate ?? .distantFuture) > Date() }) {
                let profile = ComputerProfile(id: UUID(), address: address, hostName: "기존 Windows", token: cookie.value)
                connections = [AhnaConnection(receive: receive, profile: profile, configuration: configuration)]
                try persist()
            }
            if receive, profiles == nil { UserDefaults.standard.set(true, forKey: "multiComputerMigrationComplete") }
            selectedID = connections.first?.id
            observeConnections()
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
    @discardableResult func send(_ files: [PendingFile], completion: (() -> Void)? = nil) -> Bool { selected?.send(files, completion: completion) ?? false }
    func sendClipboard(_ text: String) async throws {
        guard !busy, let selected else { throw AhnaError.message("컴퓨터를 선택하고 연결을 확인하세요.") }
        try await selected.sendClipboard(text)
    }
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
    @Published var address: String = (Brand.ahna ? Brand.server : UserDefaults.standard.string(forKey: "server") ?? "https://example.synology.me")
    @Published var pin = ""
    @Published var state: ServerState?
    @Published var status = "상대 기기와 연결해 주세요."
    @Published var busy = false
    @Published var progress = ""
    @Published var autoSave = UserDefaults.standard.object(forKey: "autoSaveReceivedFiles") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoSave, forKey: "autoSaveReceivedFiles") }
    }
    @Published private(set) var savedRevision = 0
    @Published var savePhotos = UserDefaults.standard.object(forKey: "savePhotosToLibrary") as? Bool ?? true {
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
        // A 서버 origin can host several PCs. Never share their authentication cookies.
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        session = URLSession(configuration: config, delegate: NoAPIRedirects(), delegateQueue: nil)
        if let profile { address = profile.address }
        if receive { do { _ = try fileStore() } catch { progress = "자동 저장 준비 실패 · \(error.localizedDescription)" } }
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
            if response.statusCode == 503 || response.statusCode == 502 || response.statusCode == 504 { state = nil; throw AhnaError.message("서버가 상대 기기로 요청을 전달하지 못했습니다. (HTTP \(response.statusCode)) 앱과 서버 연결을 확인하세요.") }
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
        hostName = result.hostName ?? "Windows"
        if let identity = result.computerID, identity.count == 32, identity.allSatisfy({ $0.isASCII && $0.isHexDigit }) { computerID = identity }
        else if let http = response as? HTTPURLResponse { computerID = http.value(forHTTPHeaderField: "X-Ahna-Computer") ?? computerID }
        try credentialsChanged?()
        state = result; status = "연결됨 · \(hostName)"; revoked = false
        #if canImport(UIKit)
        if receive { logReceivedClipboard(result.clipboard ?? []) }
        #endif
    }
    #if canImport(UIKit)
    /// 컴퓨터에서 받은 글자를 전송 기록에 남깁니다(미리보기용으로 내용도 가져옴).
    private func logReceivedClipboard(_ clips: [InboxClipboard]) {
        for clip in clips where !TransferLog.shared.seenKey("clip:" + clip.id) {
            let host = hostName
            Task { @MainActor [weak self] in
                let text = try? await self?.clipboardText(clip)
                TransferLog.shared.record(sent: false, name: "글자", device: clip.sender.isEmpty ? host : clip.sender, bytes: Int64(clip.bytes), preview: text.map(TransferLog.preview), key: "clip:" + clip.id)
            }
        }
    }
    #endif
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
        TransferLog.shared.record(sent: true, name: "글자", device: hostName, bytes: Int64(text.utf8.count), preview: TransferLog.preview(text))
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
        work = Task {
            defer { busy = false; work = nil }
            do {
                let batch = UUID().uuidString
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
                    let (data, response) = try await session.upload(for: request, fromFile: file.url)
                    try verify(response, data: data)
                    TransferLog.shared.record(sent: true, name: URL(fileURLWithPath: file.path).lastPathComponent, device: hostName, bytes: file.bytes)
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
        if let receivedFiles { return receivedFiles }
        let manager = FileManager.default
        #if os(macOS)
        let documents = try MacReceiveFolder.current()
        let folderID = SHA256.hash(data: Data(documents.path.utf8)).map { String(format: "%02x", $0) }.joined()
        let metadata = try manager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("아나/received-" + folderID, isDirectory: true)
        #else
        let documents = try manager.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let metadata = try manager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("아나", isDirectory: true)
        #endif
        let store = try ReceivedFileStore(directory: documents, metadata: metadata)
        Self.sharedReceivedFiles = store
        return store
    }
    #if os(macOS)
    static func resetReceiveFolder() { sharedReceivedFiles = nil }
    #endif
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
        #if canImport(UIKit)
        ReceiveHistory.shared.record(id: key, url: destination, source: hostName)
        #endif
        savedRevision += 1
        pausedAutomaticReceives.remove(key)
        progress = "자동 저장 완료 · \(destination.lastPathComponent)\n파일 앱 → 나의 iPhone/iPad → 아나에서 확인하세요."
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
        } catch { progress = "파일 앱 저장 완료 · 사진 앱 추가 실패\n\(error.localizedDescription)" }
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
            // A Windows/서버 update is needed if the old server returns 404.
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

#if os(macOS)
@MainActor enum MacReceiveFolder {
    private static var cached: URL?
    private static var scoped = false
    private static var scopeURL: URL?
    static func current() throws -> URL {
        if let cached { return cached }
        let url: URL
        if let data = UserDefaults.standard.data(forKey: "macReceiveFolderBookmark") {
            var stale = false
            url = try URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale)
            scoped = url.startAccessingSecurityScopedResource()
            scopeURL = scoped ? url : nil
        } else {
            url = try FileManager.default.url(for: .downloadsDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("아나", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        cached = url.resolvingSymlinksInPath()
        return cached!
    }
    static func select(_ url: URL) throws {
        let access = url.startAccessingSecurityScopedResource()
        let data: Data
        do { data = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) }
        catch { if access { url.stopAccessingSecurityScopedResource() }; throw error }
        scopeURL?.stopAccessingSecurityScopedResource()
        cached = url.resolvingSymlinksInPath(); scoped = access
        scopeURL = access ? url : nil
        UserDefaults.standard.set(data, forKey: "macReceiveFolderBookmark")
        AhnaConnection.resetReceiveFolder()
    }
}
#endif

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
