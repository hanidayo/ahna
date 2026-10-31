import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// 공유 메뉴에서 근처 기기로 보내기.
/// 공유 메뉴는 받는 쪽 서버를 열 수 없으므로 파일을 아나 서버에 잠시 맡기고(POST /_ahna/drop),
/// 그 1회용 주소를 Bluetooth로 근처 기기에 알립니다. 받는 쪽은 평소처럼 확인 숫자를 보고 [받기]를 누릅니다.
@MainActor final class ShareNearby: ObservableObject {
    enum Phase: Equatable { case idle, uploading(Double), waiting, sending(Int, Int), done, declined, failed(String) }
    @Published private(set) var devices: [NearbyDevice] = []
    @Published private(set) var bluetooth: NearbyBTState = .unknown
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var target = ""
    @Published private(set) var code = ""
    private let radio = NearbyRadio()
    private var drop: String?
    private var task: Task<Void, Never>?

    init() {
        radio.devicesChanged = { [weak self] list in Task { @MainActor in self?.devices = list } }
        radio.stateChanged = { [weak self] state in Task { @MainActor in self?.bluetooth = state } }
    }
    var active: Bool { phase != .idle }
    func start() { radio.update(foreground: true, advertise: false, card: Data()) }
    func stop() { radio.update(foreground: false, advertise: false, card: Data()) }

    func send(_ files: [PendingFile], to device: NearbyDevice, sender: String, finished: @escaping () -> Void) {
        guard !active, !files.isEmpty else { return }
        target = device.name; code = String(Int.random(in: 10...99)); phase = .uploading(0)
        let code = self.code, radio = self.radio
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                guard let token = ComputerVault.memberToken(), Brand.isMemberToken(token) else { throw AhnaError.message("아나 본체 앱을 한 번 열어 서버에 연결한 뒤 다시 시도하세요.") }
                let session = URLSession(configuration: .ephemeral)
                defer { session.finishTasksAndInvalidate() }
                func request(_ path: String, _ method: String) -> URLRequest {
                    var r = URLRequest(url: URL(string: Brand.server + path)!); r.httpMethod = method; r.timeoutInterval = 60
                    r.setValue("Bearer " + token, forHTTPHeaderField: "Authorization"); return r
                }
                // 1) 맡길 자리 만들기
                var create = request("/_ahna/drop", "POST"); create.setValue("application/json", forHTTPHeaderField: "Content-Type")
                let names = files.map { URL(fileURLWithPath: $0.path).lastPathComponent }
                create.httpBody = try JSONSerialization.data(withJSONObject: ["sender": DeviceIdentity.savedName, "code": code,
                    "files": zip(names, files).map { ["name": $0.0, "bytes": $0.1.bytes] as [String: Any] }] as [String: Any])
                let (data, response) = try await session.data(for: create)
                let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                guard (response as? HTTPURLResponse)?.statusCode == 200, let drop = body?["token"] as? String, let url = body?["url"] as? String else {
                    throw AhnaError.message(body?["error"] as? String ?? "서버에 연결하지 못했습니다. (\((response as? HTTPURLResponse)?.statusCode ?? 0))")
                }
                self.drop = drop
                // 2) 파일 올리기
                let total = max(1, files.reduce(Int64(0)) { $0 + $1.bytes }); var sent: Int64 = 0
                for (index, file) in files.enumerated() {
                    try Task.checkCancellation()
                    // 큰 파일은 50MB씩 이어 올립니다(X-Ahna-Offset). 프록시의 요청 크기 제한(100MB)을 피함.
                    let handle = try FileHandle(forReadingFrom: file.url); defer { try? handle.close() }
                    var offset: Int64 = 0
                    repeat {
                        try Task.checkCancellation()
                        let piece = try handle.read(upToCount: Int(min(AhnaConnection.chunkSize, file.bytes - offset))) ?? Data()
                        guard !piece.isEmpty || file.bytes == 0 else { throw AhnaError.message("파일을 끝까지 읽지 못했습니다.") }
                        var put = request("/_ahna/drop/\(drop)/\(index)", "PUT"); put.timeoutInterval = 3600
                        put.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
                        put.setValue(String(offset), forHTTPHeaderField: "X-Ahna-Offset")
                        let before = sent + offset
                        let watcher = UploadProgress { [weak self] done in Task { @MainActor in if case .uploading = self?.phase { self?.phase = .uploading(min(1, Double(before + done) / Double(total))) } } }
                        let (_, uploaded) = try await session.upload(for: put, from: piece, delegate: watcher)
                        guard (uploaded as? HTTPURLResponse)?.statusCode == 200 else { throw AhnaError.message("파일을 올리지 못했습니다.") }
                        offset += Int64(piece.count)
                        self.phase = .uploading(Double(sent + offset) / Double(total))
                    } while offset < file.bytes
                    sent += file.bytes
                }
                // 3) 근처 기기에 알리기
                let offer = NearbyOffer(name: DeviceIdentity.savedName, platform: "Mac", code: code,
                                        count: files.count, bytes: total, summary: ShareNearby.summary(names), url: url)
                let error: String? = await withCheckedContinuation { continuation in radio.send(offer.json, to: device.id) { continuation.resume(returning: $0) } }
                if let error { throw AhnaError.message(error) }
                self.phase = .waiting
                // 4) 수락·받기 지켜보기 (30초 안에 받지 않으면 취소)
                let started = Date()
                while !Task.isCancelled {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                    let (status, statusResponse) = try await session.data(for: request("/_ahna/drop/\(drop)", "GET"))
                    let info = (try? JSONSerialization.jsonObject(with: status)) as? [String: Any]
                    let state = (statusResponse as? HTTPURLResponse)?.statusCode == 200 ? info?["state"] as? String ?? "" : "gone"
                    switch state {
                    case "transferring": self.phase = .sending((info?["completed"] as? NSNumber)?.intValue ?? 0, files.count)
                    case "done": self.phase = .done; finished(); return
                    case "declined", "expired": self.phase = .declined; return
                    case "gone": if case .sending = self.phase { self.phase = .done; finished() } else { self.phase = .declined }; return
                    default:
                        if Date().timeIntervalSince(started) > 30 { self.cancelDrop(); self.phase = .declined; return }
                    }
                }
            } catch is CancellationError {
            } catch {
                self.cancelDrop(); self.phase = .failed(error.localizedDescription)
            }
        }
    }
    func reset() { task?.cancel(); task = nil; if case .waiting = phase { cancelDrop() }; if case .uploading = phase { cancelDrop() }; phase = .idle }
    private func cancelDrop() {
        guard let drop, let token = ComputerVault.memberToken(), let url = URL(string: Brand.server + "/_ahna/drop/\(drop)/cancel") else { return }
        var r = URLRequest(url: url); r.httpMethod = "POST"; r.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        let post = r; self.drop = nil
        Task { _ = try? await URLSession.shared.data(for: post) }
    }
    static func summary(_ names: [String]) -> String {
        let types = names.map { UTType(filenameExtension: ($0 as NSString).pathExtension) }
        let images = types.filter { $0?.conforms(to: .image) == true }.count
        let movies = types.filter { $0?.conforms(to: .movie) == true }.count
        if images == names.count { return "사진 \(names.count)장" }
        if movies == names.count { return "동영상 \(names.count)개" }
        if images + movies == names.count { return "사진·동영상 \(names.count)개" }
        return "파일 \(names.count)개"
    }
}

