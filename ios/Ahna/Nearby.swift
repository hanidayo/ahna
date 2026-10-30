import Foundation
import CoreBluetooth
import SwiftUI
import UIKit
import UniformTypeIdentifiers

// 아나 1.2 — 근처 기기(Bluetooth LE) & QR 공유
// 규약: 서비스 A4A10001-…, card(읽기) A4A10002-…, inbox(쓰기, 응답 있음, ≤512바이트) A4A10003-…
// 받는 쪽: '10분 동안 모두'일 때만 광고하고 GATT 서비스를 엽니다(앱이 화면에 있을 때만).
// 보내는 쪽: 앱이 화면에 있고 Bluetooth가 켜져 있으면 서비스 UUID로 찾고, 연결해 card를 읽어 이름을 보여 줍니다.


// MARK: - 근처 기기 · QR 상태 (화면용)

enum NearbyMode: String { case off, registered, everyone }

/// 받는 쪽 확인 창(NearbyRequest): Bluetooth 제안 또는 QR로 받기 요청
struct NearbyIncoming: Identifiable, Equatable {
    enum Source: Equatable { case offer(NearbyOffer), guest(String) }
    enum Phase: Equatable { case asking, receiving(String), done(String), failed(String) }
    let id = UUID()
    let source: Source
    let sender: String
    let detail: String
    let code: String
    let count: Int
    let bytes: Int64
    let summary: String
    let firstName: String?
    let deadline: Date
    var phase: Phase = .asking
}

/// 보내는 쪽 창(NearbySheet)
struct NearbyOutgoing: Identifiable, Equatable {
    enum Phase: Equatable { case preparing, waiting, sending(Int, Int), done, declined, failed(String) }
    let id = UUID()
    let deviceName: String
    var token: String?
    let code: String
    var phase: Phase = .preparing
    var started = Date()
}

@MainActor final class NearbyCenter: ObservableObject {
    static let everyoneDuration: TimeInterval = 600
    @Published private(set) var mode: NearbyMode
    @Published private(set) var everyoneUntil: Date? = nil
    @Published private(set) var bluetooth: NearbyBTState = .unknown
    @Published private(set) var devices: [NearbyDevice] = []
    @Published var incoming: NearbyIncoming?
    @Published var outgoing: NearbyOutgoing?
    @Published private(set) var now = Date()
    /// 앱이 띄운 시트(QR · 보내기) 수. 0일 때만 홈 화면 위에 확인 창을 띄우고, 시트가 있으면 시트 안에 띄웁니다.
    @Published var sheetDepth = 0
    private let radio = NearbyRadio()
    private weak var host: MobileHostModel?
    private var foreground = false
    private var ticker: Task<Void, Never>?
    private var sent: (() -> Void)?
    private var deviceName = "나의 iPhone"

    var platformName: String { UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone" }
    /// 근처 기기 목록을 보여 줄 수 있는지(Bluetooth 켜짐 · 권한 있음 · 앱이 화면에 있음)
    var available: Bool { bluetooth == .on && foreground }

    init() {
        let defaults = UserDefaults.standard
        var saved = NearbyMode(rawValue: defaults.string(forKey: "nearbyReceiveMode") ?? "") ?? .registered
        let until = defaults.object(forKey: "nearbyEveryoneUntil") as? Date
        if saved == .everyone, (until ?? .distantPast) <= Date() { saved = .registered; defaults.set(saved.rawValue, forKey: "nearbyReceiveMode") }
        mode = saved; everyoneUntil = saved == .everyone ? until : nil
        radio.devicesChanged = { [weak self] list in Task { @MainActor in self?.devices = list } }
        radio.stateChanged = { [weak self] state in Task { @MainActor in self?.bluetooth = state } }
        radio.offerReceived = { [weak self] offer in Task { @MainActor in self?.received(offer) } }
    }

    func attach(host: MobileHostModel) {
        self.host = host
        host.guestRequested = { [weak self] request in self?.guestRequest(request) }
    }
    func setForeground(_ value: Bool) {
        foreground = value
        if value { refreshName(); startTicker() } else { ticker?.cancel(); ticker = nil; devices = [] }
        applyRadio()
    }
    /// 이 기기 이름을 바꾼 뒤 근처에 보이는 이름도 바꿉니다.
    func refreshName() { deviceName = ReverseCredential.cleanName(DeviceIdentity.savedName, fallback: platformName); applyRadio() }
    var shownName: String { deviceName }

    func setMode(_ value: NearbyMode) {
        mode = value
        everyoneUntil = value == .everyone ? Date().addingTimeInterval(Self.everyoneDuration) : nil
        UserDefaults.standard.set(value.rawValue, forKey: "nearbyReceiveMode")
        UserDefaults.standard.set(everyoneUntil, forKey: "nearbyEveryoneUntil")
        applyRadio()
    }
    /// '10분 동안 모두'의 남은 시간 "9:32"
    var everyoneRemaining: String? {
        guard mode == .everyone, let everyoneUntil else { return nil }
        return Self.clock(everyoneUntil.timeIntervalSince(now))
    }
    static func clock(_ seconds: TimeInterval) -> String {
        let value = max(0, Int(seconds.rounded(.up)))
        return "\(value / 60):" + String(format: "%02d", value % 60)
    }
    private func applyRadio() {
        let card = (try? JSONSerialization.data(withJSONObject: ["v": 1, "name": deviceName, "platform": platformName] as [String: Any])) ?? Data()
        radio.update(foreground: foreground, advertise: foreground && mode == .everyone, card: card)
    }
    private func startTicker() {
        guard ticker == nil else { return }
        ticker = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }
    private func tick() {
        now = Date()
        if mode == .everyone, let everyoneUntil, everyoneUntil <= now { setMode(.registered) }
        if let current = incoming {
            if current.phase == .asking, now >= current.deadline { decline() }
            else if case .guest(let token) = current.source, case .receiving = current.phase { followGuest(token) }
        }
        followOutgoing()
    }

    // MARK: 받는 쪽

    private func received(_ offer: NearbyOffer) {
        guard foreground, mode == .everyone else { return }
        if let current = incoming, current.phase == .asking || isReceiving(current) { return }
        incoming = NearbyIncoming(source: .offer(offer), sender: offer.name, detail: "등록하지 않은 기기 · Bluetooth" + (offer.platform.isEmpty ? "" : " · " + offer.platform),
                                  code: offer.code, count: offer.count, bytes: offer.bytes, summary: offer.summary, firstName: nil, deadline: Date().addingTimeInterval(30))
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }
    private func guestRequest(_ request: GuestRequestInfo) {
        if let current = incoming, current.phase == .asking || isReceiving(current) { host?.answerGuest(request.token, accept: false); return }
        let total = request.files.reduce(Int64(0)) { $0 + $1.bytes }
        incoming = NearbyIncoming(source: .guest(request.token), sender: request.sender, detail: "QR로 연 웹 페이지 · 등록하지 않은 기기",
                                  code: request.code, count: request.files.count, bytes: total, summary: Self.summary(request.files.map { $0.name }),
                                  firstName: request.files.first?.name, deadline: Date().addingTimeInterval(30))
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }
    private func isReceiving(_ value: NearbyIncoming) -> Bool { if case .receiving = value.phase { return true }; return false }

    func accept() {
        guard var current = incoming, current.phase == .asking else { return }
        switch current.source {
        case .offer(let offer):
            current.phase = .receiving("받을 파일을 확인하는 중…"); incoming = current
            let id = current.id
            Task { @MainActor [weak self] in await self?.download(offer, id: id) }
        case .guest(let token):
            host?.answerGuest(token, accept: true)
            current.phase = .receiving("받는 중 · 0/\(current.count)"); incoming = current
        }
    }
    func decline() {
        guard let current = incoming else { return }
        if current.phase == .asking {
            switch current.source {
            case .offer(let offer):
                if let url = URL(string: offer.url + "/decline") {
                    var request = URLRequest(url: url); request.httpMethod = "POST"; request.httpBody = Data(); request.timeoutInterval = 20
                    let post = request
                    Task { _ = try? await URLSession.shared.data(for: post) }
                }
            case .guest(let token): host?.answerGuest(token, accept: false)
            }
        }
        incoming = nil
    }
    /// 받는 중 창을 닫기만 합니다(받기는 계속).
    func dismissIncoming() { incoming = nil }

    private func followGuest(_ token: String) {
        guard var current = incoming, let host else { return }
        guard let ticket = host.tickets[token] else { current.phase = .failed("전송이 중단되었습니다."); incoming = current; return }
        switch ticket.state {
        case "done": current.phase = .done("\(ticket.files.count)개를 받았습니다 · 파일 앱 › 아나"); finishLater(current.id)
        case "declined", "expired": current.phase = .failed("전송이 중단되었습니다. 받은 파일은 그대로 남습니다.")
        default: current.phase = .receiving("받는 중 · \(ticket.completed)/\(ticket.files.count)")
        }
        if current != incoming { incoming = current }
    }
    private func finishLater(_ id: UUID) {
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if self?.incoming?.id == id { self?.incoming = nil }
        }
    }
    private func setPhase(_ id: UUID, _ phase: NearbyIncoming.Phase) {
        guard var current = incoming, current.id == id else { return }
        current.phase = phase; incoming = current
    }

    /// [받기]: 보낸 쪽 서버의 게스트 주소에서 info → file/{i}를 차례로 받아 평소 수신처럼 저장합니다.
    private func download(_ offer: NearbyOffer, id: UUID) async {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 60; config.timeoutIntervalForResource = 4 * 3600
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        do {
            guard let infoURL = URL(string: offer.url + "/info") else { throw AhnaError.message("올바르지 않은 주소입니다.") }
            let (data, response) = try await session.data(from: infoURL)
            guard (response as? HTTPURLResponse)?.statusCode == 200, let info = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw AhnaError.message("보낸 기기에 연결하지 못했습니다. 보낸 사람의 아나가 열려 있는지 확인하세요.")
            }
            guard info["kind"] as? String == "send", !["done", "declined", "expired"].contains(info["state"] as? String ?? "") else { throw AhnaError.message("이미 끝난 전송입니다.") }
            if let code = info["code"] as? String, code != offer.code { throw AhnaError.message("확인 숫자가 맞지 않아 받지 않았습니다.") }
            let files = (info["files"] as? [[String: Any]] ?? []).compactMap { item -> (Int, String, Int64)? in
                guard let index = (item["i"] as? NSNumber)?.intValue, let raw = item["name"] as? String, let bytes = (item["bytes"] as? NSNumber)?.int64Value,
                      let name = try? MobileHTTPHost.safeName(raw) else { return nil }
                return (index, name, bytes)
            }
            guard !files.isEmpty else { throw AhnaError.message("받을 파일이 없습니다.") }
            let manager = FileManager.default
            let documents = try manager.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let metadata = try manager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("아나/nearby", isDirectory: true)
            let store = try ReceivedFileStore(directory: documents, metadata: metadata)
            let photos = UserDefaults.standard.object(forKey: "savePhotosToLibrary") as? Bool ?? true
            for (position, file) in files.enumerated() {
                setPhase(id, .receiving("받는 중 · \(file.1) (\(position + 1)/\(files.count))"))
                guard let fileURL = URL(string: offer.url + "/file/\(file.0)") else { continue }
                let (temporary, fileResponse) = try await session.download(from: fileURL)
                defer { try? manager.removeItem(at: temporary) }
                guard (fileResponse as? HTTPURLResponse)?.statusCode == 200 else { throw AhnaError.message("\(file.1)을(를) 받지 못했습니다.") }
                let key = offer.url + "|" + String(file.0)
                let destination = try store.save(temporary: temporary, name: file.1, bytes: file.2, key: key)
                ReceiveHistory.shared.record(id: key, url: destination, source: offer.name)
                if photos, PhotoLibrarySaver.isMedia(destination) { try? await PhotoLibrarySaver.save(destination) }
            }
            setPhase(id, .done("\(files.count)개를 받았습니다 · 파일 앱 › 아나"))
            finishLater(id)
        } catch {
            setPhase(id, .failed(error.localizedDescription))
        }
    }

    // MARK: 보내는 쪽

    /// 근처 기기로 보내기: 내 서버에 1회용 티켓(kind=send) → 상대 inbox에 제안 쓰기 → 수락 대기
    func send(to device: NearbyDevice, files: [PendingFile], onSent: @escaping () -> Void) {
        guard let host else { return }
        let code = String(Int.random(in: 10...99))
        let attempt = NearbyOutgoing(deviceName: device.name, code: code)
        outgoing = attempt; sent = onSent
        let total = files.reduce(Int64(0)) { $0 + $1.bytes }
        let summary = Self.summary(files.map { URL(fileURLWithPath: $0.path).lastPathComponent })
        let name = deviceName, platform = platformName, radio = self.radio
        Task { @MainActor [weak self] in
            do {
                let ticket = try await host.createTicket(kind: .send, files: files, code: code)
                guard let self, self.outgoing?.id == attempt.id else { host.cancelTicket(ticket.token); return }
                self.outgoing?.token = ticket.token
                guard let url = host.guestURL(ticket.token) else { throw AhnaError.message("서버 설정이 필요합니다.") }
                let offer = NearbyOffer(name: name, platform: platform, code: code, count: files.count, bytes: total, summary: summary, url: url)
                let data = offer.json
                let error: String? = await withCheckedContinuation { continuation in
                    radio.send(data, to: device.id) { continuation.resume(returning: $0) }
                }
                guard self.outgoing?.id == attempt.id else { return }
                if let error { host.cancelTicket(ticket.token); self.outgoing?.phase = .failed(error); return }
                self.outgoing?.phase = .waiting; self.outgoing?.started = Date()
            } catch {
                guard let self, self.outgoing?.id == attempt.id else { return }
                self.outgoing?.phase = .failed(error.localizedDescription)
            }
        }
    }
    private func followOutgoing() {
        guard var current = outgoing, let token = current.token, let host else { return }
        switch current.phase { case .waiting, .sending: break; default: return }
        let ticket = host.tickets[token]
        switch ticket?.state ?? "missing" {
        case "transferring": current.phase = .sending(ticket?.completed ?? 0, ticket?.files.count ?? 0)
        case "done":
            current.phase = .done; sent?(); sent = nil
            for file in ticket?.files ?? [] { TransferLog.shared.record(sent: true, name: file.name, device: current.deviceName, bytes: file.bytes) }
        case "declined": current.phase = .declined
        case "expired", "missing":
            if current.phase == .waiting { current.phase = .declined } else { current.phase = .failed("전송이 중단되었습니다.") }
        default:
            // 30초 안에 받지 않으면 자동으로 취소
            if current.phase == .waiting, now.timeIntervalSince(current.started) > 30 { host.cancelTicket(token); current.phase = .declined }
        }
        if current != outgoing { outgoing = current }
    }
    /// 보내기 취소 · 창 닫기. 아직 받는 중이 아니면 티켓도 지웁니다.
    func closeOutgoing() {
        guard let current = outgoing else { return }
        if let token = current.token {
            switch current.phase {
            case .preparing, .waiting: host?.cancelTicket(token)
            default: break
            }
        }
        outgoing = nil; sent = nil
    }

    /// "사진 2장" · "동영상 1개" · "파일 3개"
    static func summary(_ names: [String]) -> String {
        let types = names.map { UTType(filenameExtension: ($0 as NSString).pathExtension) }
        let images = types.filter { $0?.conforms(to: .image) == true }.count
        let movies = types.filter { $0?.conforms(to: .movie) == true || $0?.conforms(to: .audiovisualContent) == true }.count
        if images == names.count { return "사진 \(names.count)장" }
        if movies == names.count { return "동영상 \(names.count)개" }
        if images + movies == names.count { return "사진·동영상 \(names.count)개" }
        return "파일 \(names.count)개"
    }
}
