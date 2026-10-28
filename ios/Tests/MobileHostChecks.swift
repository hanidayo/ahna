import Foundation
import CryptoKit

// Compile on the Mac. All keys, sessions and files are confined to a temporary directory.
enum AhnaError: LocalizedError { case message(String); var errorDescription: String? { if case .message(let value) = self { return value }; return nil } }
struct PendingFile { let url: URL; let path: String; let bytes: Int64 }
// 앱에서는 Shared/AhnaClient.swift에 있습니다(이 검사는 그 파일 없이 빌드).
struct ReverseCredential: Sendable {
    let address: String; let computerID: String; let token: String; let name: String
    static func validated(_ object: Any?) -> ReverseCredential? {
        guard let input = object as? [String: Any], let address = input["address"] as? String, let id = input["computerID"] as? String, let token = input["token"] as? String else { return nil }
        return ReverseCredential(address: address, computerID: id.lowercased(), token: token, name: cleanName(input["name"] as? String, fallback: "기기"))
    }
    static func cleanName(_ value: String?, fallback: String) -> String { let name = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines); return name.isEmpty ? fallback : String(name.prefix(40)) }
}
final class NoAPIRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
@main struct MobileHostChecks {
    static func main() async throws {
        let folder = URL(fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"] ?? "/tmp").appendingPathComponent("Ahna-MobileHost-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let key = Data(SymmetricKey(size: .bits256).withUnsafeBytes { Array($0) })
        let port = UInt16.random(in: 48000...59000)
        let host = try MobileHTTPHost(directory: folder.appendingPathComponent("state"), receivingDirectory: folder.appendingPathComponent("received"), encryptionKey: key, stableIdentity: "00112233445566778899aabbccddeeff", port: port)
        host.start(); defer { host.stop() }
        let config = URLSessionConfiguration.ephemeral
        let session = URLSession(configuration: config, delegate: NoAPIRedirects(), delegateQueue: nil)
        let stranger = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel(); stranger.invalidateAndCancel() }
        let base = "http://127.0.0.1:\(port)"
        var count = 0
        func check(_ success: Bool, _ title: String) throws { guard success else { throw AhnaError.message("FAIL: " + title) }; count += 1; print("PASS: " + title) }
        func request(_ path: String, body: Data? = nil, client: URLSession? = nil) async throws -> (Int, Data) {
            var request = URLRequest(url: URL(string: base + path)!)
            if let body { request.httpMethod = "POST"; request.httpBody = body; request.setValue(String(body.count), forHTTPHeaderField: "Content-Length") }
            let (data, response) = try await (client ?? session).data(for: request)
            return ((response as! HTTPURLResponse).statusCode, data)
        }
        for _ in 0..<50 { do { _ = try await request("/api/state"); break } catch { try await Task.sleep(nanoseconds: 100_000_000) } }
        try check(try await request("/api/state").0 == 401, "Unpaired state rejected")
        let pairBody = try JSONSerialization.data(withJSONObject: ["pin": host.pin, "name": "테스트 Android", "native": true, "canReceive": true])
        let pair = try await request("/api/pair", body: pairBody)
        try check(pair.0 == 200, "Android-style native pairing")
        let device = (try JSONSerialization.jsonObject(with: pair.1) as! [String: Any])["id"] as! String
        let state = try await request("/api/state?receiving=true")
        let stateJSON = try JSONSerialization.jsonObject(with: state.1) as! [String: Any]
        try check(state.0 == 200 && stateJSON["owner"] as? Bool == false, "Existing mobile state contract")
        let content = Data((0..<(2 * 1024 * 1024 + 13)).map { UInt8(truncatingIfNeeded: $0) })
        let fileName = "한글 사진 🐱.bin".decomposedStringWithCanonicalMapping
        let path = fileName.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+=?#")))!
        let uploadPath = "/api/upload?batch=87dd1c2c-071b-4d1e-9bc3-76c589056bff&path=" + path
        let upload = try await request(uploadPath, body: content); try check(upload.0 == 200, "Streamed Android-to-iPhone upload")
        let received = folder.appendingPathComponent("received/한글 사진 🐱.bin")
        try check(try Data(contentsOf: received) == content, "NFC Korean filename and byte integrity")
        try check(try await request(uploadPath, body: content).0 == 200, "Duplicate filename safely accepted")
        try check((try FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent("received").path)).count == 2, "Existing file is never overwritten")
        try check(try await request("/api/upload?batch=87dd1c2c-071b-4d1e-9bc3-76c589056bff&path=../escape", body: Data([1])).0 == 400, "Path traversal denied")
        let source = folder.appendingPathComponent("source.bin"); try content.write(to: source)
        let result: String = await withCheckedContinuation { continuation in host.prepare([PendingFile(url: source, path: "아이폰에서.bin", bytes: Int64(content.count))], target: device) { continuation.resume(returning: $0) } }
        try check(result.contains("전송 준비 완료"), "iPhone prepares file for Android")
        let inboxState = try await request("/api/state")
        let items = (try JSONSerialization.jsonObject(with: inboxState.1) as! [String: Any])["items"] as! [[String: Any]]
        let id = items[0]["id"] as! String
        try check(try await request("/api/download/" + id).1 == content, "iPhone-to-Android streamed download")
        try check(try await request("/api/download/" + id, client: stranger).0 == 401, "Unpaired download denied")
        let receipt = try JSONSerialization.data(withJSONObject: ["destination": "files"])
        try check(try await request("/api/received/" + id, body: receipt).0 == 200, "Recipient saved acknowledgement")
        let text = "한글 🐱\r\n둘째 줄  "
        try check(try await request("/api/upload?kind=clipboard&batch=87dd1c2c-071b-4d1e-9bc3-76c589056bff", body: Data(text.utf8)).0 == 200, "Incoming UTF-8 clipboard")
        host.sendText(text, target: device)
        let clipState = try await request("/api/state")
        let clips = (try JSONSerialization.jsonObject(with: clipState.1) as! [String: Any])["clipboard"] as! [[String: Any]]
        let clipID = clips[0]["id"] as! String
        try check(try await request("/api/download/" + clipID + "?kind=clipboard").1 == Data(text.utf8), "Outgoing UTF-8 clipboard")
        try check(try await request("/api/admin/settings", body: Data()).0 == 404, "No desktop administrative API exposed")
        // 아나 1.2 게스트 티켓(근처 기기 · QR): 쿠키 없이 토큰으로만
        let cid = "00112233445566778899aabbccddeeff"
        let sendTicket: GuestTicketSnapshot? = await withCheckedContinuation { continuation in
            host.createTicket(kind: .send, files: [PendingFile(url: source, path: "사진.bin", bytes: Int64(content.count))], code: "47") { ticket, _ in continuation.resume(returning: ticket) }
        }
        let sendToken = sendTicket?.token ?? ""
        try check(sendToken.count == 43 && MobileHTTPHost.validTicketToken(sendToken), "Guest token is 43-char base64url")
        let guest = "/s/\(cid)/\(sendToken)"
        try check(try await request(guest + "/info", client: stranger).0 == 200, "Guest info without cookie")
        try check(try await request("/s/\(cid)/" + String(repeating: "A", count: 43) + "/info", client: stranger).0 == 404, "Wrong guest token is 404")
        try check(try await request("/s/ffffffffffffffffffffffffffffffff/\(sendToken)/info", client: stranger).0 == 404, "Other computer ID is 404")
        try check(MobileHTTPHost.guestAllowed("GET", guest + "/file/0") && !MobileHTTPHost.guestAllowed("GET", guest + "/file/1000") && MobileHTTPHost.guestAllowed("POST", guest + "/upload"), "Guest relay allow-list")
        try check(try await request(guest + "/file/0", client: stranger).1 == content, "Guest file download")
        try await Task.sleep(nanoseconds: 300_000_000)
        let afterSend = try JSONSerialization.jsonObject(with: try await request(guest + "/status", client: stranger).1) as! [String: Any]
        try check(afterSend["state"] as? String == "done", "Send ticket done after every file")
        try check(try await request(guest + "/file/0", client: stranger).0 == 404, "Finished ticket file is gone")
        let receiveTicket: GuestTicketSnapshot? = await withCheckedContinuation { continuation in
            host.createTicket(kind: .receive, files: [], code: nil) { ticket, _ in continuation.resume(returning: ticket) }
        }
        let upload2 = "/s/\(cid)/\(receiveTicket?.token ?? "")"
        try check(try await request(upload2 + "/upload?i=0&name=a.bin", body: Data([1]), client: stranger).0 == 409, "Upload before approval refused")
        let ask = try JSONSerialization.data(withJSONObject: ["name": "민수", "files": [["name": "웹에서.bin", "bytes": 3]]])
        try check(try await request(upload2 + "/request", body: ask, client: stranger).0 == 200, "Guest upload request")
        host.answerGuest(receiveTicket?.token ?? "", accept: true)
        try await Task.sleep(nanoseconds: 200_000_000)
        let encoded = "웹에서.bin".addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
        try check(try await request(upload2 + "/upload?i=0&name=" + encoded, body: Data([1, 2, 3]), client: stranger).0 == 200, "Approved guest upload saved")
        try check(FileManager.default.fileExists(atPath: folder.appendingPathComponent("received/웹에서.bin").path), "Guest upload in receive folder")
        print("Mobile receiver checks passed: \(count). 서버 and iOS UI still require device validation.")
    }
}
