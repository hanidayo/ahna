import Foundation
import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - 근처 기기 · QR 상태 (화면용)

enum NearbyMode: String { case off, registered, everyone }

/// 받는 쪽 확인 창: Bluetooth 제안 또는 QR로 받기 요청
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
    let deadline: Date
    var phase: Phase = .asking
}

/// 보내는 쪽 창
struct NearbyOutgoing: Identifiable, Equatable {
    enum Phase: Equatable { case preparing, waiting, sending(Int, Int), done, declined, failed(String) }
    let id = UUID()
    let deviceName: String
    var token: String?
    let code: String
    var phase: Phase = .preparing
    var started = Date()
}

/// QR 창: 보내기(파일 링크) 또는 받기(올리기 링크)
struct NearbyQR: Identifiable, Equatable {
    let id = UUID()
    let kind: GuestKind
    var token: String?
    var url: String?
    var error: String?
}

@MainActor final class NearbyCenter: ObservableObject {
    static let shared = NearbyCenter()
    static let everyoneDuration: TimeInterval = 600
    @Published private(set) var mode: NearbyMode
    @Published private(set) var everyoneUntil: Date? = nil
    @Published private(set) var bluetooth: NearbyBTState = .unknown
    @Published private(set) var devices: [NearbyDevice] = []
    @Published var incoming: NearbyIncoming?
    @Published var outgoing: NearbyOutgoing?
    @Published var qr: NearbyQR?
    @Published private(set) var now = Date()
    private let radio = NearbyRadio()
    private weak var host: MacReceiverModel?
    private var ticker: Task<Void, Never>?
    private var deviceName = "Mac"
    let platformName = "Mac"
    var available: Bool { bluetooth == .on }

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

    /// Mac 앱은 메뉴 막대에 늘 떠 있으므로 실행 중에는 계속 찾고, '10분 동안 모두'일 때만 광고합니다.
    func start(host: MacReceiverModel, name: String) {
        self.host = host
        host.guestRequested = { [weak self] ticket in self?.guestRequest(ticket) }
        refreshName(name)
        if ticker == nil {
            ticker = Task { @MainActor [weak self] in
                while !Task.isCancelled { self?.tick(); try? await Task.sleep(nanoseconds: 500_000_000) }
            }
        }
    }
    func refreshName(_ name: String) {
        deviceName = ReverseCredential.cleanName(name, fallback: "Mac"); applyRadio()
    }
    func setMode(_ value: NearbyMode) {
        mode = value
        everyoneUntil = value == .everyone ? Date().addingTimeInterval(Self.everyoneDuration) : nil
        UserDefaults.standard.set(value.rawValue, forKey: "nearbyReceiveMode")
        UserDefaults.standard.set(everyoneUntil, forKey: "nearbyEveryoneUntil")
        applyRadio()
    }
    var everyoneRemaining: String? {
        guard mode == .everyone, let everyoneUntil else { return nil }
        let value = max(0, Int(everyoneUntil.timeIntervalSince(now).rounded(.up)))
        return "\(value / 60):" + String(format: "%02d", value % 60)
    }
    private func applyRadio() {
        let card = (try? JSONSerialization.data(withJSONObject: ["v": 1, "name": deviceName, "platform": platformName] as [String: Any])) ?? Data()
        radio.update(foreground: true, advertise: mode == .everyone, card: card)
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
        guard mode == .everyone else { return }
        if let current = incoming, current.phase == .asking || isReceiving(current) { return }
        incoming = NearbyIncoming(source: .offer(offer), sender: offer.name, detail: "등록하지 않은 기기 · Bluetooth" + (offer.platform.isEmpty ? "" : " · " + offer.platform),
                                  code: offer.code, count: offer.count, bytes: offer.bytes, summary: offer.summary, deadline: Date().addingTimeInterval(30))
        NSApp.requestUserAttention(.criticalRequest)
        NSApp.activate(ignoringOtherApps: true)
    }
    private func guestRequest(_ ticket: GuestTicketSnapshot) {
        if let current = incoming, current.phase == .asking || isReceiving(current) { host?.answerGuest(ticket.token, accept: false); return }
        let total = ticket.files.reduce(Int64(0)) { $0 + $1.bytes }
        incoming = NearbyIncoming(source: .guest(ticket.token), sender: ticket.peer.isEmpty ? "이름 없는 기기" : ticket.peer, detail: "QR로 연 웹 페이지 · 등록하지 않은 기기",
                                  code: ticket.code ?? "", count: ticket.files.count, bytes: total, summary: Self.summary(ticket.files.map { $0.name }),
                                  deadline: Date().addingTimeInterval(30))
        NSApp.requestUserAttention(.criticalRequest)
        NSApp.activate(ignoringOtherApps: true)
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
    func dismissIncoming() { incoming = nil }

    private func followGuest(_ token: String) {
        guard var current = incoming, let host else { return }
        guard let ticket = host.tickets[token] else { return }
        switch ticket.state {
        case "done": current.phase = .done("\(ticket.files.count)개를 받았습니다 · 받은 파일 폴더"); finishLater(current.id)
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

    /// [받기]: 보낸 쪽 서버의 게스트 주소에서 info → file/{i}를 차례로 받아 받은 파일 폴더에 저장합니다.
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
                      let name = MacGuest.safeName(raw) else { return nil }
                return (index, name, bytes)
            }
            guard !files.isEmpty else { throw AhnaError.message("받을 파일이 없습니다.") }
            let manager = FileManager.default
            let folder = ReceiveFolder.currentURL()
            try manager.createDirectory(at: folder, withIntermediateDirectories: true)
            for (position, file) in files.enumerated() {
                setPhase(id, .receiving("받는 중 · \(file.1) (\(position + 1)/\(files.count))"))
                guard let fileURL = URL(string: offer.url + "/file/\(file.0)") else { continue }
                let (temporary, fileResponse) = try await session.download(from: fileURL)
                defer { try? manager.removeItem(at: temporary) }
                guard (fileResponse as? HTTPURLResponse)?.statusCode == 200 else { throw AhnaError.message("\(file.1)을(를) 받지 못했습니다.") }
                let destination = Self.freeName(file.1, in: folder)
                try manager.moveItem(at: temporary, to: destination)
                ReceiveHistory.shared.record(id: offer.url + "|" + String(file.0), url: destination, source: offer.name)
            }
            setPhase(id, .done("\(files.count)개를 받았습니다 · 받은 파일 폴더"))
            finishLater(id)
        } catch {
            setPhase(id, .failed(error.localizedDescription))
        }
    }
    /// 같은 이름이 있으면 "이름 (2).확장자"
    static func freeName(_ name: String, in folder: URL) -> URL {
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        var candidate = folder.appendingPathComponent(name); var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent(ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)"); n += 1
        }
        return candidate
    }

    // MARK: 보내는 쪽

    /// 근처 기기로 보내기: 1회용 티켓(kind=send) → 상대 inbox에 제안 쓰기 → 수락 대기
    func send(to device: NearbyDevice, urls: [URL]) {
        guard let host, !urls.isEmpty else { return }
        let code = String(Int.random(in: 10...99))
        let attempt = NearbyOutgoing(deviceName: device.name, code: code)
        outgoing = attempt
        let total = urls.reduce(Int64(0)) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) }
        let summary = Self.summary(urls.map { $0.lastPathComponent })
        let name = deviceName, platform = platformName, radio = self.radio
        Task { @MainActor [weak self] in
            do {
                let (ticket, url) = try await host.createTicket(kind: .send, urls: urls, peer: device.name, code: code)
                guard let self, self.outgoing?.id == attempt.id else { host.cancelTicket(ticket.token); return }
                self.outgoing?.token = ticket.token
                let offer = NearbyOffer(name: name, platform: platform, code: ticket.code ?? code, count: urls.count, bytes: total, summary: summary, url: url)
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
        case "transferring", "accepted": current.phase = .sending(ticket?.completed ?? 0, ticket?.files.count ?? 0)
        case "done": current.phase = .done
        case "declined": current.phase = .declined
        case "expired", "missing":
            if current.phase == .waiting { current.phase = .declined } else { current.phase = .failed("전송이 중단되었습니다.") }
        default:
            if current.phase == .waiting, now.timeIntervalSince(current.started) > 30 { host.cancelTicket(token); current.phase = .declined }
        }
        if current != outgoing { outgoing = current }
    }
    func closeOutgoing() {
        guard let current = outgoing else { return }
        if let token = current.token {
            switch current.phase { case .preparing, .waiting: host?.cancelTicket(token); default: break }
        }
        outgoing = nil
    }

    // MARK: QR

    /// QR로 보내기(urls 있음) · QR로 받기(urls 없음): 1회용 링크를 만들어 QR로 보여 줍니다.
    func openQR(urls: [URL]) {
        guard let host else { return }
        let kind: GuestKind = urls.isEmpty ? .receive : .send
        let attempt = NearbyQR(kind: kind)
        qr = attempt
        Task { @MainActor [weak self] in
            do {
                let (ticket, url) = try await host.createTicket(kind: kind, urls: urls, peer: "QR")
                guard let self, self.qr?.id == attempt.id else { host.cancelTicket(ticket.token); return }
                self.qr?.token = ticket.token; self.qr?.url = url
            } catch {
                guard let self, self.qr?.id == attempt.id else { return }
                self.qr?.error = error.localizedDescription
            }
        }
    }
    func closeQR() {
        if let token = qr?.token, let ticket = host?.tickets[token], !ticket.finished, ticket.state != "transferring" { host?.cancelTicket(token) }
        qr = nil
    }
    func ticket(_ token: String?) -> GuestTicketSnapshot? { token.flatMap { host?.tickets[$0] } }

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
