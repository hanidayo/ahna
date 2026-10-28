import UIKit
import SwiftUI
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {
    private var staging: URL?
    override func viewDidLoad() {
        super.viewDidLoad()
        let host = UIHostingController(rootView: ShareScreen(context: extensionContext, prepare: { [weak self] in try await self?.prepareFiles() ?? [] }))
        addChild(host); host.view.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(host.view)
        NSLayoutConstraint.activate([host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor), host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor), host.view.topAnchor.constraint(equalTo: view.topAnchor), host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)])
        host.didMove(toParent: self)
    }
    private func prepareFiles() async throws -> [PendingFile] {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ahna-share-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); staging = root
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        guard !providers.isEmpty, providers.count <= 256 else { throw AhnaError.message("1~256개 파일을 선택하세요.") }
        var urls: [URL] = []
        let jpg = ComputerVault.photosAsJPG()
        for (index, provider) in providers.enumerated() {
            let hasURL = provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
            guard let type = provider.registeredTypeIdentifiers.first(where: { id in
                guard let type = UTType(id) else { return false }
                return type.conforms(to: .data) || type.conforms(to: .image) || type.conforms(to: .movie) || type.conforms(to: .folder) || type == .fileURL
            }) else { throw AhnaError.message("이 항목을 파일로 가져올 수 없습니다. 파일 앱에서 공유해 주세요.") }
            let directory = root.appendingPathComponent(String(index), isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let suggestedName=provider.suggestedName ?? "파일"
            let copied: URL = try await withCheckedThrowingContinuation { continuation in
                let copy: @Sendable (URL?, Error?) -> Void = { url, error in
                    do {
                        guard let url else { throw error ?? AhnaError.message("공유 파일을 읽을 수 없습니다.") }
                        let access = url.startAccessingSecurityScopedResource()
                        defer { if access { url.stopAccessingSecurityScopedResource() } }
                        _ = try FilePreparation.collect([url])
                        let safe = url.lastPathComponent.isEmpty ? suggestedName : url.lastPathComponent
                        let destination = directory.appendingPathComponent(safe)
                        // Provider URLs expire as soon as this callback returns.
                        try FileManager.default.copyItem(at: url, to: destination)
                        continuation.resume(returning: destination)
                    } catch { continuation.resume(throwing: error) }
                }
                if hasURL {
                    provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { object, error in copy(object as? URL, error) }
                } else {
                    provider.loadFileRepresentation(forTypeIdentifier: type, completionHandler: copy)
                }
            }
            // 사진 앱에서 공유한 HEIC 사진도 설정에 따라 JPG로 바꿔 보냅니다.
            urls.append(jpg ? PhotoJPEG.convertIfNeeded(copied) : copied)
        }
        return try FilePreparation.collect(urls)
    }
    deinit { if let staging { try? FileManager.default.removeItem(at: staging) } }
}

// 아나 1.1 공유 창 — 좁은 창(700pt 미만): 아래에서 올라온 시트 모양, 기기 목록 /
// 넓은 창(700pt 이상): 가운데 대화상자, 기기 카드 3열. 크기 등급이 아니라 실제 너비로 고릅니다.
// 단계: 기기 고르기 → 보내는 중 → 완료(잠시 후 자동으로 닫힘)
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
                    var put = request("/_ahna/drop/\(drop)/\(index)", "PUT"); put.timeoutInterval = 3600
                    put.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
                    let (_, uploaded) = try await session.upload(for: put, fromFile: file.url)
                    guard (uploaded as? HTTPURLResponse)?.statusCode == 200 else { throw AhnaError.message("파일을 올리지 못했습니다.") }
                    sent += file.bytes; self.phase = .uploading(Double(sent) / Double(total))
                }
                // 3) 근처 기기에 알리기
                let offer = NearbyOffer(name: DeviceIdentity.savedName, platform: UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone", code: code,
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

struct ShareScreen: View {
    let context: NSExtensionContext?
    let prepare: () async throws -> [PendingFile]
    @StateObject private var client = AhnaClient(receive: false)
    @StateObject private var nearby = ShareNearby()
    @State private var files: [PendingFile] = []
    @State private var prepared = false
    @State private var completed = false
    @State private var sendingID: UUID?

    private var sendingConnection: AhnaConnection? { client.connections.first { $0.id == sendingID } }
    private var isSending: Bool { sendingConnection?.busy == true }

    var body: some View {
        GeometryReader { proxy in
            screen(regular: AhnaLayout.isWide(proxy.size.width))
        }
        .task { do { files = try await prepare(); prepared = true } catch { client.progress = error.localizedDescription } }
        .task(id: client.pollID) { await client.poll() }
        .onAppear { nearby.start() }
        .onDisappear { client.cancel(); nearby.reset(); nearby.stop() }
    }

    /// regular: 창 너비 700pt 이상(가운데 대화상자 · 기기 카드 격자)
    private func screen(regular: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if !regular {
                Capsule().fill(AhnaPalette.border).frame(width: 36, height: 4)
                    .frame(maxWidth: .infinity).padding(.bottom, 14)
                    .accessibilityHidden(true)
            }
            header(regular: regular).padding(.bottom, regular ? 16 : 14)
            ScrollView {
                Group {
                    if completed { doneStage(regular: regular) }
                    else if nearby.active { nearbyStage(regular: regular) }
                    else if isSending { sendingStage(regular: regular) }
                    else { pickStage(regular: regular) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, regular ? 22 : 16)
        .padding(.top, regular ? 22 : 10)
        .padding(.bottom, 20)
        .frame(maxWidth: regular ? CGFloat(560) : CGFloat.infinity, maxHeight: .infinity, alignment: .top)
        .frame(maxWidth: .infinity)
        .foregroundStyle(AhnaPalette.text)
        .background(AhnaPalette.surface.ignoresSafeArea())
        .tint(AhnaPalette.accent)
    }

    // MARK: 머리글

    private func header(regular: Bool) -> some View {
        HStack(spacing: 12) {
            AhnaLogoTile(size: regular ? 44 : 40)
            VStack(alignment: .leading, spacing: 1) {
                Text("아나로 보내기").font(.system(size: regular ? 18 : 17, weight: .bold)).accessibilityAddTraits(.isHeader)
                Text(summary).font(.system(size: 12)).foregroundStyle(AhnaPalette.faint)
            }
            Spacer(minLength: 0)
        }
    }

    private var summary: String {
        guard prepared else { return "공유 파일 준비 중…" }
        let total = files.reduce(Int64(0)) { $0 + $1.bytes }
        let types: [UTType?] = files.map { UTType(filenameExtension: ($0.path as NSString).pathExtension) }
        let noun: String
        if !files.isEmpty && types.allSatisfy({ $0?.conforms(to: .image) == true }) { noun = "사진 \(files.count)장" }
        else if !files.isEmpty && types.allSatisfy({ $0?.conforms(to: .movie) == true }) { noun = "동영상 \(files.count)개" }
        else { noun = "파일 \(files.count)개" }
        return noun + " · " + AhnaText.bytes(total)
    }

    // MARK: 기기 고르기

    private func pickStage(regular: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("보낼 기기").font(.system(size: 13, weight: .medium)).foregroundStyle(AhnaPalette.muted)
                .padding(.bottom, regular ? 8 : 6)
            if client.connections.isEmpty {
                Text("아나 본체 앱에서 기기를 추가한 뒤 공유 메뉴를 다시 열어 주세요. 기기 목록과 기기 이름을 함께 사용합니다.")
                    .font(.system(size: 13)).foregroundStyle(AhnaPalette.faint)
                    .padding(.vertical, 8)
            } else if regular {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                    ForEach(client.connections) { c in deviceCard(c) }
                }
            } else {
                VStack(spacing: 8) {
                    ForEach(client.connections) { c in deviceRow(c) }
                }
            }
            if !nearby.devices.isEmpty {
                HStack(spacing: 5) {
                    Image(systemName: "dot.radiowaves.left.and.right").font(.system(size: 11, weight: .semibold))
                    Text("근처 기기").font(.system(size: 13, weight: .semibold))
                }
                .foregroundStyle(Self.nearText)
                .padding(.top, 16).padding(.bottom, 6)
                VStack(spacing: 8) {
                    ForEach(nearby.devices) { device in nearbyRow(device) }
                }
            }
            if !prepared {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("공유 파일 준비 중…").font(.system(size: 12)).foregroundStyle(AhnaPalette.faint)
                }
                .padding(.top, 10)
            }
            if !client.connections.isEmpty && !client.progress.isEmpty {
                Text(client.progress).font(.system(size: 12)).foregroundStyle(AhnaPalette.muted).padding(.top, 10)
            }
            HStack {
                if regular { Spacer() }
                Button("취소") { cancelShare() }
                    .buttonStyle(AhnaButtonStyle(kind: .subtle, height: regular ? 44 : 48, fullWidth: !regular))
                    .frame(width: regular ? 96 : nil)
            }
            .padding(.top, regular ? 16 : 14)
            Text("\(client.deviceName) · 기기 추가와 이름 변경은 아나 본체 앱에서 한 번만 설정하세요. 설정을 바꾼 뒤 이 공유 메뉴를 다시 열면 반영됩니다. 전송이 끝나면 공유창이 자동으로 닫힙니다.")
                .font(.system(size: 11)).foregroundStyle(AhnaPalette.faint)
                .padding(.top, 12)
        }
    }

    private func canSend(_ c: AhnaConnection) -> Bool { prepared && c.state != nil && !client.busy }

    private func deviceRow(_ c: AhnaConnection) -> some View {
        let online = c.state != nil
        return Button { send(to: c) } label: {
            HStack(spacing: 12) {
                DeviceIconTile(symbol: AhnaText.deviceSymbol(c.hostName), isOnline: online, size: 40, offlineFill: AhnaPalette.surface)
                Text(c.hostName).font(.system(size: 15, weight: .medium)).lineLimit(1)
                    .foregroundStyle(online ? AhnaPalette.text : AhnaPalette.muted)
                Spacer(minLength: 4)
                DeviceStatePill(isOnline: online)
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 64)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(online ? AhnaPalette.surface : AhnaPalette.subtle))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(AhnaPalette.border, style: StrokeStyle(lineWidth: 1, dash: online ? [] : [4, 3])))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!canSend(c))
        .accessibilityLabel("\(c.hostName), \(online ? "연결됨" : "오프라인")")
        .accessibilityHint(online ? "눌러서 보내기" : c.status)
    }

    private func deviceCard(_ c: AhnaConnection) -> some View {
        let online = c.state != nil
        return Button { send(to: c) } label: {
            VStack(spacing: 8) {
                DeviceIconTile(symbol: AhnaText.deviceSymbol(c.hostName), isOnline: online, size: 52, offlineFill: AhnaPalette.surface)
                Text(c.hostName).font(.system(size: 14, weight: .medium)).lineLimit(1)
                    .foregroundStyle(online ? AhnaPalette.text : AhnaPalette.muted)
                DeviceStateLabel(isOnline: online)
            }
            .padding(.vertical, 16).padding(.horizontal, 8)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(online ? AhnaPalette.surface : AhnaPalette.subtle))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(AhnaPalette.border, style: StrokeStyle(lineWidth: 1, dash: online ? [] : [4, 3])))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!canSend(c))
        .accessibilityLabel("\(c.hostName), \(online ? "연결됨" : "오프라인")")
        .accessibilityHint(online ? "눌러서 보내기" : c.status)
    }

    // 기존 전송 흐름 그대로: 기기를 고르면 바로 보내고, 끝나면 공유창을 닫습니다.
    private func send(to connection: AhnaConnection) {
        client.selectedID = connection.id
        let started = client.send(files) {
            completed = true
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                context?.completeRequest(returningItems: nil)
            }
        }
        if started { sendingID = connection.id }
    }

    private func cancelShare() {
        client.cancel()
        context?.cancelRequest(withError: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
    }

    // MARK: 근처 기기

    static let near = AhnaPalette.rgb(0x7C3AED, 0xA78BFA)
    static let nearSoft = AhnaPalette.rgb(0xF1EBFE, 0x2B2140)
    static let nearText = AhnaPalette.rgb(0x6D28D9, 0xC4B5FD)

    private func nearbyRow(_ device: NearbyDevice) -> some View {
        Button {
            nearby.send(files, to: device, sender: client.deviceName) {
                completed = true
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 1_200_000_000)
                    context?.completeRequest(returningItems: nil)
                }
            }
        } label: {
            HStack(spacing: 12) {
                Text(String(device.name.prefix(1)).uppercased())
                    .font(.system(size: 16, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 40, height: 40).background(Circle().fill(Self.near))
                Text(device.name).font(.system(size: 15, weight: .medium)).lineLimit(1)
                Spacer(minLength: 4)
                Text(device.proximity).font(.system(size: 12, weight: device.veryClose ? .bold : .regular))
                    .foregroundStyle(device.veryClose ? Self.nearText : AhnaPalette.muted)
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(Capsule().fill(device.veryClose ? Self.nearSoft : AhnaPalette.subtle))
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 64)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(AhnaPalette.surface))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Self.near.opacity(0.5), lineWidth: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!prepared || client.busy)
        .accessibilityLabel("\(device.name), 근처 기기, \(device.proximity)")
    }

    private func nearbyStage(regular: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(AhnaText.toward(nearby.target) + " 보내기").font(.system(size: 16, weight: .bold))
            switch nearby.phase {
            case .uploading(let fraction):
                // 파일을 서버에 맡기는 동안에도 확인 숫자를 먼저 보여 줍니다(다 올라가면 상대 화면에 같은 숫자가 뜹니다).
                HStack(spacing: 12) {
                    Text("파일을 준비하는 중 · \(Int(fraction * 100))%\n끝나면 상대 화면에 이 숫자가 뜹니다").font(.system(size: 13)).foregroundStyle(AhnaPalette.muted)
                    Spacer()
                    ForEach(Array(nearby.code), id: \.self) { digit in
                        Text(String(digit)).font(.system(size: 26, weight: .bold).monospacedDigit()).foregroundStyle(Self.nearText)
                            .frame(width: 42, height: 52).background(RoundedRectangle(cornerRadius: 10).fill(Self.nearSoft))
                    }
                }
                ProgressView(value: fraction).tint(Self.near)
            case .waiting, .sending:
                HStack(spacing: 12) {
                    Text("상대 화면에 이 숫자가 보이면\n[받기]를 누르라고 알려 주세요").font(.system(size: 13)).foregroundStyle(AhnaPalette.muted)
                    Spacer()
                    ForEach(Array(nearby.code), id: \.self) { digit in
                        Text(String(digit)).font(.system(size: 26, weight: .bold).monospacedDigit()).foregroundStyle(Self.nearText)
                            .frame(width: 42, height: 52).background(RoundedRectangle(cornerRadius: 10).fill(Self.nearSoft))
                    }
                }
                if case .sending(let done, let total) = nearby.phase {
                    Text("상대가 받는 중 · \(done)/\(total)").font(.system(size: 12)).foregroundStyle(AhnaPalette.faint)
                } else {
                    Text("수락을 기다리는 중 · 30초 안에 받지 않으면 취소됩니다").font(.system(size: 12)).foregroundStyle(AhnaPalette.faint)
                }
            case .declined:
                Text("상대가 받지 않았습니다.").font(.system(size: 14))
            case .failed(let message):
                Text(message).font(.system(size: 13)).foregroundStyle(AhnaPalette.danger)
            case .done, .idle:
                EmptyView()
            }
            HStack {
                if regular { Spacer() }
                Button(nearbyEnded ? "다른 기기 고르기" : "취소") { nearby.reset() }
                    .buttonStyle(AhnaButtonStyle(kind: .subtle, height: regular ? 44 : 48, fullWidth: !regular))
                    .frame(width: regular ? 160 : nil)
            }
            .padding(.top, 4)
        }
        .padding(.top, 8)
    }
    private var nearbyEnded: Bool { switch nearby.phase { case .declined, .failed: return true; default: return false } }

    // MARK: 보내는 중

    private var sendFraction: Double {
        guard let c = sendingConnection, let head = c.progress.split(separator: " ").first else { return 0 }
        let parts = head.split(separator: "/")
        guard parts.count == 2, let index = Int(parts[0]), let count = Int(parts[1]), count == files.count, count > 0 else { return 0 }
        let total = files.reduce(Int64(0)) { $0 + max($1.bytes, 1) }
        let done = files.prefix(max(index - 1, 0)).reduce(Int64(0)) { $0 + max($1.bytes, 1) }
        return total > 0 ? min(1, Double(done) / Double(total)) : 0
    }

    private func sendingStage(regular: Bool) -> some View {
        let name = sendingConnection?.hostName ?? "기기"
        let fraction = sendFraction
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                DeviceIconTile(symbol: AhnaText.deviceSymbol(name), isOnline: true, size: 40)
                VStack(alignment: .leading, spacing: 1) {
                    Text(AhnaText.toward(name) + " 보내는 중").font(.system(size: 15, weight: .medium)).lineLimit(1)
                    Text(sendingConnection?.progress ?? "").font(.system(size: 12)).foregroundStyle(AhnaPalette.faint)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 4)
                Text(String(Int(fraction * 100)) + "%").font(.system(size: 15, weight: .bold).monospacedDigit()).foregroundStyle(AhnaPalette.accent)
            }
            .padding(14)
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(AhnaPalette.border, lineWidth: 1))
            Capsule().fill(AhnaPalette.subtle).frame(height: 6)
                .overlay(alignment: .leading) {
                    GeometryReader { proxy in
                        Capsule().fill(AhnaPalette.accent).frame(width: proxy.size.width * CGFloat(fraction), height: 6)
                    }
                }
                .accessibilityElement()
                .accessibilityLabel("전송 진행률")
                .accessibilityValue(String(Int(fraction * 100)) + "%")
            Text("이 창을 닫지 마세요. 다 보내면 자동으로 닫힙니다.").font(.system(size: 12)).foregroundStyle(AhnaPalette.faint)
            HStack {
                if regular { Spacer() }
                Button("전송 취소") { cancelShare() }
                    .buttonStyle(AhnaButtonStyle(kind: .subtle, height: regular ? 44 : 48, fullWidth: !regular))
                    .frame(width: regular ? 120 : nil)
            }
            .padding(.top, 4)
        }
        .padding(.top, 8)
    }

    // MARK: 완료

    private func doneStage(regular: Bool) -> some View {
        let name = nearby.phase == .done ? nearby.target : (sendingConnection?.hostName ?? "기기")
        return VStack(spacing: 8) {
            Image(systemName: "checkmark")
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(AhnaPalette.accent)
                .frame(width: 56, height: 56)
                .background(Circle().fill(AhnaPalette.accentSoft))
            Text(AhnaText.toward(name) + " 보냈습니다").font(.system(size: 17, weight: .bold))
            Text(summary + " · 잠시 후 자동으로 닫힙니다").font(.system(size: 12)).foregroundStyle(AhnaPalette.faint)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.top, regular ? 14 : 18).padding(.bottom, 8)
        .accessibilityElement(children: .combine)
    }
}
