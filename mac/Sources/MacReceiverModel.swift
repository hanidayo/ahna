import AppKit
import Combine
import Foundation
import Security

struct MacReceiverDevice: Identifiable, Equatable {
    let id: String
    let name: String
    /// 상대 기기가 알려 준 자기 수신 ID(예전 앱은 빈 값). 같은 기기를 한 줄로 합칠 때 씁니다.
    var computerID = ""
    var online = true
}

@MainActor final class MacReceiverModel: ObservableObject {
    static let shared = MacReceiverModel()
    @Published var pin = ""
    @Published var hostName = Host.current().localizedName ?? "Mac"
    @Published var addresses: [String] = []
    @Published var savePath = ""
    @Published var remoteStatus = ""
    @Published var remoteEnabled = false
    @Published var remoteURL = Brand.server
    /// 아나 서버에 가입했는지 (nil: 아직 모름). false면 첫 화면에서 초대 코드를 묻습니다.
    @Published var joined: Bool?
    /// 서버 관리자 공지(읽은 공지는 3일 뒤 빠짐). 새 공지가 오면 showNotices로 팝업을 띄웁니다.
    @Published private(set) var announcements: [MacAnnouncement] = []
    @Published var showNotices = false
    var unreadNotices: Int { announcements.filter { !$0.read }.count }
    func readAnnouncement(_ id: String) { try? write(["command": "announcementRead", "id": id]) }
    func deleteAnnouncement(_ id: String) { try? write(["command": "announcementDelete", "id": id]) }
    @Published var joining = false
    private var savedMemberToken: String?
    @Published var remoteKey = ""
    @Published var message = ""
    @Published private(set) var devices: [MacReceiverDevice] = []
    /// 이 Mac에 연결한 모든 기기(지금 받는 중이 아닌 기기 포함). 예전 수신 구성요소면 devices와 같습니다.
    @Published private(set) var peers: [MacReceiverDevice] = []
    /// 이 Mac 수신 쪽의 ID. 이 Mac이 다른 기기를 추가할 때 함께 보냅니다.
    @Published private(set) var computerID: String?
    @Published private(set) var clipboard: [InboxClipboard] = []
    @Published private(set) var clipboardSupported = false
    @Published private(set) var clipboardBusy = false
    private var clipboardRequests: [String: CheckedContinuation<String, Error>] = [:]
    /// 다른 기기가 이 Mac과 연결하면서 넘겨준 그 기기 쪽 연결(한 번의 코드 입력으로 양쪽 연결). 추가한 기기로 저장합니다.
    var reverseReceived: (@MainActor (ReverseCredential) -> Void)?
    private var process: Process?
    private var input: FileHandle?
    private var reader: Task<Void, Never>?
    private var loadedOptions = false
    private var cachedReceiverKey: Result<Data, Error>?
    func start() {
        guard process == nil else { return }
        do {
            let folder = try receiverFolder()
            savePath = folder.path
            let data = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("아나/Receiver", isDirectory: true).resolvingSymlinksInPath()
            try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
            guard let resources = Bundle.main.resourceURL else { throw CocoaError(.fileNoSuchFile) }
            let executable = resources.appendingPathComponent("Backend/" + Self.runtimeID + "/Ahna.MacReceiver")
            guard FileManager.default.isExecutableFile(atPath: executable.path) else {
                message = "수신 구성요소가 없습니다. Mac에서 Mac앱만들기.command로 다시 빌드해 주세요."; return
            }
            let child = Process(); let incoming = Pipe(); let outgoing = Pipe()
            child.executableURL = executable; child.currentDirectoryURL = data
            child.standardInput = incoming; child.standardOutput = outgoing; child.standardError = FileHandle.nullDevice
            try child.run()
            process = child; input = incoming.fileHandleForWriting
            try write(["dataPath": data.path, "savePath": folder.path, "encryptionKey": try receiverKey().base64EncodedString()])
            reader = Task {
                do {
                    for try await line in outgoing.fileHandleForReading.bytes.lines { consume(line) }
                    if !Task.isCancelled, self.process === child {
                        pin = ""; addresses = []; message = "수신 서비스가 종료되었습니다. 앱을 다시 열어 주세요."
                        failClipboardRequests(); devices = []; peers = []; clipboard = []; clipboardSupported = false
                        self.process = nil; try? input?.close(); input = nil
                    }
                }
                catch { if !Task.isCancelled { failClipboardRequests(); devices = []; peers = []; clipboard = []; clipboardSupported = false; message = "수신 서비스 연결이 끊겼습니다. 앱을 다시 열어 주세요." } }
            }
        } catch { stop(); message = "Mac 수신 서비스를 시작하지 못했습니다. 저장 폴더와 키체인 접근 권한을 확인하세요." }
    }
    func stop() {
        failClipboardRequests(); devices = []; peers = []; clipboard = []; clipboardSupported = false
        reader?.cancel(); reader = nil
        try? write(["command": "stop"]); try? input?.close(); input = nil
        if let process {
            // Give the service time to persist native sessions on a normal stop.
            for _ in 0..<40 { if !process.isRunning { break }; Thread.sleep(forTimeInterval: 0.025) }
            if process.isRunning { process.terminate(); process.waitUntilExit() }
        }
        process = nil; pin = ""; addresses = []
    }
    func chooseFolder() {
        let picker = NSOpenPanel(); picker.canChooseDirectories = true; picker.canChooseFiles = false; picker.allowsMultipleSelection = false; picker.canCreateDirectories = true
        picker.directoryURL = try? receiverFolder()
        picker.prompt = "이 폴더에 저장"
        if picker.runModal() == .OK, let url = picker.url {
            stop()
            do { try ReceiveFolder.choose(url) } catch { message = "선택한 폴더에 접근할 수 없습니다." }
            start()
        }
    }
    func saveOptions() {
        do { joining = !remoteKey.trimmingCharacters(in: .whitespaces).isEmpty; message = ""; try write(["command": "configure", "savePath": savePath, "remoteEnabled": true, "remoteUrl": Brand.server, "remoteKey": remoteKey.trimmingCharacters(in: .whitespaces)]); remoteKey = "" }
        catch { message = "수신 서비스가 실행 중인지 확인하세요." }
    }
    func sendClipboard(_ text: String, target: String) async throws {
        guard !text.isEmpty, !text.contains("\0"), text.utf8.count <= 65536 else { throw AhnaError.message("보낼 글자를 붙여넣어 주세요. 최대 64 KB까지 보낼 수 있습니다.") }
        _ = try await clipboardCommand(["command": "clipboardSend", "target": target, "text": text])
    }
    func sendFiles(_ urls: [URL], target: String) async throws {
        guard !urls.isEmpty, urls.count <= 256 else { throw AhnaError.message("파일은 한 번에 1~256개 선택하세요.") }
        let staging = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("Ahna-Send-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        // The already-running sandboxed service cannot assume it received the
        // NSOpenPanel extension granted to the parent. Stage into our container.
        let paths: [String] = try await Task.detached(priority: .userInitiated) {
            _ = try FilePreparation.collect(urls)
            var paths: [String] = []
            for (index, url) in urls.enumerated() {
                let parent = staging.appendingPathComponent(String(index), isDirectory: true)
                try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
                let destination = parent.appendingPathComponent(url.lastPathComponent)
                try FileManager.default.copyItem(at: url, to: destination); paths.append(destination.path)
            }
            return paths
        }.value
        _ = try await clipboardCommand(["command": "filesSend", "target": target, "paths": paths], timeout: 2700)
    }
    // MARK: 근처 기기 · QR (1회용 게스트 티켓)

    /// 수신 구성요소가 만든 티켓들(토큰별). 근처 기기 보내기·QR 화면이 상태를 봅니다.
    @Published private(set) var tickets: [String: GuestTicketSnapshot] = [:]
    /// QR로 받기에서 상대가 [보내기]를 눌렀을 때(확인 창)
    var guestRequested: ((GuestTicketSnapshot) -> Void)?
    /// 근처 기기·QR은 상대가 이 Mac의 서버 주소로 받아 가므로 서버에 연결돼 있어야 합니다.
    var guestReady: Bool { joined == true && remoteStatus.contains("연결됨") }

    /// kind=send: 고른 파일을 내려받을 수 있는 1회용 링크 · kind=receive: 웹 페이지에서 올릴 수 있는 링크
    func createTicket(kind: GuestKind, urls: [URL] = [], peer: String, code: String? = nil) async throws -> (GuestTicketSnapshot, String) {
        guard guestReady else { throw AhnaError.message("서버에 연결된 뒤 다시 시도하세요. (옵션 › 서버)") }
        var command: [String: Any] = ["command": "ticketCreate", "kind": kind.rawValue, "peer": peer]
        if kind == .send {
            // 상대가 받아 갈 때까지 파일이 남아 있어야 하므로 지우지 않고 둡니다(다음 실행 때 하루 지난 것만 정리).
            command["paths"] = try await stage(urls, prefix: "Ahna-Share-")
            if let code { command["code"] = code }
        }
        let text = try await clipboardCommand(command, timeout: 600)
        guard let data = text.data(using: .utf8), let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let raw = object["ticket"] as? [String: Any], let ticket = GuestTicketSnapshot(raw), let url = object["url"] as? String else {
            throw AhnaError.message("공유를 준비하지 못했습니다.")
        }
        tickets[ticket.token] = ticket
        return (ticket, url)
    }
    func cancelTicket(_ token: String) { try? write(["command": "ticketCancel", "token": token]) }
    func answerGuest(_ token: String, accept: Bool) { try? write(["command": "ticketAnswer", "token": token, "accept": accept]) }

    /// 보낼 파일을 앱 캐시로 복사합니다(수신 구성요소가 원래 위치에 접근하지 못할 수 있음).
    private func stage(_ urls: [URL], prefix: String) async throws -> [String] {
        guard !urls.isEmpty, urls.count <= 256 else { throw AhnaError.message("파일은 한 번에 1~256개 선택하세요.") }
        let caches = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        if prefix == "Ahna-Share-", let old = try? FileManager.default.contentsOfDirectory(at: caches, includingPropertiesForKeys: [.creationDateKey]) {
            for item in old where item.lastPathComponent.hasPrefix(prefix) {
                if let created = try? item.resourceValues(forKeys: [.creationDateKey]).creationDate, Date().timeIntervalSince(created) > 86400 { try? FileManager.default.removeItem(at: item) }
            }
        }
        let staging = caches.appendingPathComponent(prefix + UUID().uuidString, isDirectory: true)
        return try await Task.detached(priority: .userInitiated) {
            _ = try FilePreparation.collect(urls)
            var paths: [String] = []
            for (index, url) in urls.enumerated() {
                let parent = staging.appendingPathComponent(String(index), isDirectory: true)
                try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
                let destination = parent.appendingPathComponent(url.lastPathComponent)
                try FileManager.default.copyItem(at: url, to: destination); paths.append(destination.path)
            }
            return paths
        }.value
    }

    /// 이 Mac에 연결한 기기의 세션을 지웁니다(같은 기기의 다른 세션 포함).
    func forget(_ ids: [String]) async throws {
        guard !ids.isEmpty else { return }
        _ = try await clipboardCommand(["command": "forgetSessions", "ids": ids])
    }
    /// 이 Mac이 다른 기기를 추가할 때 함께 보낼 이 Mac 쪽 연결을 수신 구성요소에 만들게 합니다.
    /// NAS 연결이 꺼져 있거나 수신 구성요소가 예전 버전이면 nil(예전처럼 한쪽만 연결).
    func reverseOffer() async -> ReverseCredential? {
        guard let text = try? await clipboardCommand(["command": "reverseOffer"]), let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return ReverseCredential.validated(object)
    }
    /// 만든 연결을 상대가 저장했으면 유지하고 아니면 지웁니다.
    func reverseComplete(token: String, accepted: Bool, name: String, computerID: String?) {
        var command: [String: Any] = ["command": "reverseComplete", "token": token, "accepted": accepted, "name": name]
        if let computerID { command["computerID"] = computerID }
        try? write(command)
    }
    func clipboardText(_ item: InboxClipboard) async throws -> String {
        let text = try await clipboardCommand(["command": "clipboardRead", "id": item.id])
        guard text.utf8.count == item.bytes, !text.isEmpty, !text.contains("\0"), text.utf8.count <= 65536 else { throw AhnaError.message("받은 글자를 읽을 수 없습니다. 목록을 다시 확인하세요.") }
        return text
    }
    private func clipboardCommand(_ object: [String: Any], timeout: UInt64 = 20) async throws -> String {
        guard clipboardSupported, process?.isRunning == true else { throw AhnaError.message("Mac 수신 구성요소를 함께 업데이트하고 앱을 다시 실행하세요.") }
        guard clipboardRequests.count < 4 else { throw AhnaError.message("이전 글자 요청이 끝난 뒤 다시 시도하세요.") }
        let requestID = UUID().uuidString
        return try await withCheckedThrowingContinuation { continuation in
            clipboardRequests[requestID] = continuation; clipboardBusy = true
            var command = object; command["requestID"] = requestID
            do { try write(command) }
            catch { finishClipboard(requestID, result: .failure(error)); return }
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: timeout * 1_000_000_000)
                self?.finishClipboard(requestID, result: .failure(AhnaError.message("글자 요청 시간이 초과되었습니다. 다시 시도하세요.")))
            }
        }
    }
    private func finishClipboard(_ requestID: String, result: Result<String, Error>) {
        guard let continuation = clipboardRequests.removeValue(forKey: requestID) else { return }
        clipboardBusy = !clipboardRequests.isEmpty; continuation.resume(with: result)
    }
    private func failClipboardRequests() {
        let requests = clipboardRequests; clipboardRequests.removeAll(); clipboardBusy = false
        for continuation in requests.values { continuation.resume(throwing: AhnaError.message("수신 서비스 연결이 종료되었습니다. 다시 실행해 주세요.")) }
    }
    private func write(_ object: [String: Any]) throws {
        guard let input else { throw CocoaError(.fileWriteUnknown) }
        var data = try JSONSerialization.data(withJSONObject: object); data.append(10)
        try input.write(contentsOf: data)
    }
    private func consume(_ line: String) {
        guard let data = line.data(using: .utf8), let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        switch object["type"] as? String {
        case "status":
            pin = object["pin"] as? String ?? ""; addresses = object["addresses"] as? [String] ?? []
            savePath = object["savePath"] as? String ?? savePath; remoteStatus = object["remoteStatus"] as? String ?? ""
            clipboardSupported = object["clipboardSupported"] as? Bool ?? false
            if let value = object["joined"] as? Bool { joined = value }
            let notes = ((object["announcements"] as? [[String: Any]]) ?? []).compactMap { item -> MacAnnouncement? in
                guard let id = item["id"] as? String, let text = item["text"] as? String else { return nil }
                return MacAnnouncement(id: id, text: text, created: Date(timeIntervalSince1970: (item["created"] as? NSNumber)?.doubleValue ?? 0), read: item["read"] as? Bool ?? false)
            }
            if notes != announcements { announcements = notes; if notes.isEmpty { showNotices = false } }
            if let token = object["memberToken"] as? String, token != savedMemberToken, Brand.isMemberToken(token) {
                savedMemberToken = token; try? ComputerVault.saveMemberToken(token)
            }
            devices = ((object["devices"] as? [[String: Any]]) ?? []).compactMap { item in
                guard let id = item["id"] as? String, let name = item["name"] as? String else { return nil }; return MacReceiverDevice(id: id, name: name)
            }
            if let list = object["peers"] as? [[String: Any]] {
                let next: [MacReceiverDevice] = list.compactMap { item in
                    guard let id = item["id"] as? String, let name = item["name"] as? String else { return nil }
                    return MacReceiverDevice(id: id, name: name, computerID: item["computerID"] as? String ?? "", online: item["online"] as? Bool ?? false)
                }
                if next != peers { peers = next }
            } else if peers != devices { peers = devices }
            if let identity = object["computerID"] as? String, identity.count == 32, identity != computerID { computerID = identity }
            if let value = object["clipboard"], let encoded = try? JSONSerialization.data(withJSONObject: value) {
                clipboard = (try? JSONDecoder().decode([InboxClipboard].self, from: encoded)) ?? []
            } else { clipboard = [] }
            if let history = object["history"] as? [[String: Any]] {
                for item in history.reversed() where (item["direction"] as? String) == "receive" {
                    if let id = item["id"] as? String, let name = item["name"] as? String {
                        ReceiveHistory.shared.record(id: id, url: URL(fileURLWithPath: savePath).appendingPathComponent(name), source: item["device"] as? String ?? "기기")
                    }
                }
            }
            if !loadedOptions {
                remoteEnabled = true
                if let url = object["remoteUrl"] as? String, !url.isEmpty { remoteURL = url }
                loadedOptions = true
            }
        case "saved": message = joining ? "서버에 연결했습니다." : "옵션을 저장했습니다."; joining = false
        case "received": message = (object["message"] as? String ?? "파일") + " · 저장 완료"
        case "announcements":
            // 읽지 않은 새 공지: 창을 열고 공지 팝업을 띄웁니다(목록은 이어서 오는 status에 있음).
            BackgroundSession.shared.showMain(); showNotices = true
        case "notice":
            // 서버 관리자 알림(사용량 한도·메시지·초기화·차단)
            let text = object["text"] as? String ?? "서버 알림", informational = (object["action"] as? String) == "message"
            message = text
            Task { @MainActor in
                let alert = NSAlert(); alert.messageText = "아나 · 서버 알림"; alert.informativeText = text
                alert.alertStyle = informational ? .informational : .warning
                NSApp.activate(ignoringOtherApps: true); alert.runModal()
            }
        case "clipboardReceived": message = (object["sender"] as? String ?? "기기") + "에서 글자가 도착했습니다. 클립보드의 받은 글자에서 복사하세요."
        case "reverseOffer":
            guard let requestID = object["requestID"] as? String else { break }
            if let offer = object["offer"] as? [String: Any], let data = try? JSONSerialization.data(withJSONObject: offer), let text = String(data: data, encoding: .utf8) {
                finishClipboard(requestID, result: .success(text))
            } else { finishClipboard(requestID, result: .success("")) }
        case "reverseReceived":
            if let credential = ReverseCredential.validated(object) { reverseReceived?(credential) }
        case "ticket":
            if let requestID = object["requestID"] as? String, let data = try? JSONSerialization.data(withJSONObject: object), let text = String(data: data, encoding: .utf8) {
                finishClipboard(requestID, result: .success(text))
            }
        case "guest":
            if let raw = object["ticket"] as? [String: Any], let ticket = GuestTicketSnapshot(raw) {
                tickets[ticket.token] = ticket
                if ticket.finished { let token = ticket.token; Task { @MainActor [weak self] in try? await Task.sleep(nanoseconds: 120_000_000_000); self?.tickets.removeValue(forKey: token) } }
            }
        case "guestRequest":
            if let raw = object["ticket"] as? [String: Any], let ticket = GuestTicketSnapshot(raw) {
                tickets[ticket.token] = ticket
                if let ask = guestRequested { ask(ticket) } else { answerGuest(ticket.token, accept: false) }
            }
        case "clipboardSent", "filesPrepared", "sessionsForgotten":
            if let requestID = object["requestID"] as? String { finishClipboard(requestID, result: .success("")) }
        case "clipboardText":
            if let requestID = object["requestID"] as? String {
                if let text = object["text"] as? String { finishClipboard(requestID, result: .success(text)) }
                else { finishClipboard(requestID, result: .failure(AhnaError.message("받은 글자를 읽을 수 없습니다."))) }
            }
        case "error":
            let error = object["message"] as? String ?? "수신 서비스 오류"
            joining = false
            if let requestID = object["requestID"] as? String { finishClipboard(requestID, result: .failure(AhnaError.message(error))) }
            else { message = error }
        default: break
        }
    }
    #if arch(arm64)
    private static let runtimeID = "osx-arm64"
    #else
    private static let runtimeID = "osx-x64"
    #endif
    private func receiverFolder() throws -> URL {
        let url = ReceiveFolder.currentURL()
        try ReceiveFolder.prepare(url, isDefault: UserDefaults.standard.string(forKey: ReceiveFolder.preferenceKey) == nil)
        return url
    }
    func refreshFolder() {
        guard savePath != ReceiveFolder.currentURL().path else { return }
        stop(); start()
    }
    private func receiverKey() throws -> Data {
        if cachedReceiverKey == nil { cachedReceiverKey = Result { try readReceiverKey() } }
        return try cachedReceiverKey!.get()
    }
    private func readReceiverKey() throws -> Data {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "Ahna.MacReceiver", kSecAttrAccount as String: "configuration-encryption-key"]
        var lookup = query; lookup[kSecReturnData as String] = true
        var result: CFTypeRef?; let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data, data.count == 32 { return data }
        guard status == errSecItemNotFound else { throw CocoaError(.fileReadNoPermission) }
        var data = Data(count: 32)
        let generated = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        guard generated == errSecSuccess else { throw CocoaError(.fileWriteUnknown) }
        var add = query; add[kSecValueData as String] = data; add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        guard SecItemAdd(add as CFDictionary, nil) == errSecSuccess else { throw CocoaError(.fileWriteNoPermission) }
        return data
    }
}

/// 서버 관리자 공지
struct MacAnnouncement: Identifiable, Equatable {
    let id: String
    let text: String
    let created: Date
    let read: Bool
}
