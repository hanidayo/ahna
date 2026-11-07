// Ahna 1.1 — Mac 메인 창 (한 창 3열 + 오른쪽 옵션 패널)
//
// 1열: 이 Mac의 연결 코드 · 보낼 기기 · 파일 보내기(끌어 놓기/선택)
// 2열: 클립보드 (MacClipboardView)
// 3열: 받은 파일
// [옵션] 버튼은 창 안에서 오른쪽 패널(MacOptionsDrawer)을 밀어 넣습니다.

import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - 팔레트 (라이트/다크 자동)

enum MacTheme {
    static let bg = color(0xeef1f5, 0x1c1c1c)
    static let surface = color(0xffffff, 0x272727)
    static let subtle = color(0xf8f9fb, 0x2e2e2e)
    static let border = color(0xe1e4e8, 0x3a3a3a)
    static let borderStrong = color(0xc5cad1, 0x555555)
    static let text = color(0x1f2328, 0xe6e8eb)
    static let muted = color(0x5b636e, 0xa3aab4)
    static let faint = color(0x6b7280, 0x9aa1ab)
    static let accent = color(0x005fb8, 0x4cc2ff)
    static let onAccent = color(0xffffff, 0x002033)
    static let onAccentLine = color(0xffffff, 0x002033, lightAlpha: 0.45, darkAlpha: 0.35)
    static let accentSoft = color(0xe5eff9, 0x16303f)
    static let on = color(0x1e7a48, 0x4ade80)
    static let off = color(0x9aa1ab, 0x8b929c)
    static let danger = color(0xc4372f, 0xf2786f)
    static let dangerSoft = color(0xfdecea, 0x3a2321)
    /// 창 배경(제목 막대 포함) — 맨 위 막대와 같은 surface 색
    static let windowBackground = nsColor(0xffffff, 0x272727)

    static func nsColor(_ light: UInt32, _ dark: UInt32, lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) -> NSColor {
        NSColor(name: nil) { appearance in
            let match = appearance.bestMatch(from: [.aqua, .darkAqua, .vibrantLight, .vibrantDark])
            let isDark = match == .darkAqua || match == .vibrantDark
            let hex = isDark ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
                           green: CGFloat((hex >> 8) & 0xff) / 255,
                           blue: CGFloat(hex & 0xff) / 255,
                           alpha: isDark ? darkAlpha : lightAlpha)
        }
    }
    static func color(_ light: UInt32, _ dark: UInt32, lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) -> Color {
        Color(nsColor: nsColor(light, dark, lightAlpha: lightAlpha, darkAlpha: darkAlpha))
    }
}

// MARK: - 공통 모양

struct MacCardModifier: ViewModifier {
    var padding: CGFloat = 14
    var fill = false
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, maxHeight: fill ? .infinity : nil, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(MacTheme.surface))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(MacTheme.border, lineWidth: 1))
    }
}

struct MacFieldModifier: ViewModifier {
    var height: CGFloat = 34
    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .foregroundColor(MacTheme.text)
            .padding(.horizontal, 10)
            .frame(height: height)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(MacTheme.subtle))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(MacTheme.border, lineWidth: 1))
    }
}

extension View {
    func macCard(padding: CGFloat = 14, fill: Bool = false) -> some View { modifier(MacCardModifier(padding: padding, fill: fill)) }
    func macField(height: CGFloat = 34) -> some View { modifier(MacFieldModifier(height: height)) }
}

struct MacHairline: View {
    var body: some View { Rectangle().fill(MacTheme.border).frame(height: 1) }
}

enum MacButtonKind { case primary, secondary, soft, plain, onAccent, selected }

struct MacButtonStyle: ButtonStyle {
    var kind: MacButtonKind = .secondary
    var height: CGFloat = 28
    var fullWidth = false
    var fontSize: CGFloat = 12
    func makeBody(configuration: Configuration) -> some View {
        MacButtonBody(configuration: configuration, kind: kind, height: height, fullWidth: fullWidth, fontSize: fontSize)
    }
}

private struct MacButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let kind: MacButtonKind
    let height: CGFloat
    let fullWidth: Bool
    let fontSize: CGFloat
    @Environment(\.isEnabled) private var isEnabled
    private var weight: Font.Weight {
        switch kind {
        case .primary, .soft: return .bold
        case .selected: return .medium
        default: return .regular
        }
    }
    private var foreground: Color {
        switch kind {
        case .primary, .onAccent: return MacTheme.onAccent
        case .secondary: return MacTheme.text
        case .soft, .selected: return MacTheme.accent
        case .plain: return MacTheme.muted
        }
    }
    private var background: Color {
        switch kind {
        case .primary: return MacTheme.accent
        case .secondary: return MacTheme.surface
        case .soft, .selected: return MacTheme.accentSoft
        case .plain, .onAccent: return Color.clear
        }
    }
    private var stroke: Color {
        switch kind {
        case .secondary: return MacTheme.border
        case .onAccent: return MacTheme.onAccentLine
        case .selected: return MacTheme.accent
        default: return Color.clear
        }
    }
    var body: some View {
        configuration.label
            .font(.system(size: fontSize, weight: weight))
            .lineLimit(1)
            .padding(.horizontal, kind == .plain ? 8 : 10)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .frame(height: height)
            .foregroundColor(foreground)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(background))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(stroke, lineWidth: 1))
            .contentShape(Rectangle())
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.45)
    }
}

/// 온라인 = 꽉 찬 점 + "연결됨", 오프라인 = 속이 빈 테두리 점 + "오프라인"
struct MacStatusDot: View {
    let isOnline: Bool
    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(isOnline ? MacTheme.on : Color.clear)
                .overlay(Circle().strokeBorder(isOnline ? MacTheme.on : MacTheme.off, lineWidth: 1.5))
                .frame(width: 7, height: 7)
            Text(isOnline ? "연결됨" : "오프라인").font(.system(size: 12))
        }
        .foregroundColor(isOnline ? MacTheme.on : MacTheme.faint)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isOnline ? "연결됨" : "오프라인")
    }
}

struct MacNASPill: View {
    let status: String
    private var connected: Bool { status.hasPrefix("서버 연결됨") }
    private var label: String {
        if status.isEmpty { return "서버 확인 중" }
        if connected { return "서버 연결됨" }
        return status.components(separatedBy: " · ").first ?? status
    }
    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(connected ? MacTheme.on : Color.clear)
                .overlay(Circle().strokeBorder(connected ? MacTheme.on : MacTheme.off, lineWidth: 1.5))
                .frame(width: 7, height: 7)
            Text(label).font(.system(size: 12, weight: .medium)).lineLimit(1)
        }
        .padding(.horizontal, 9)
        .frame(height: 24)
        .foregroundColor(connected ? MacTheme.on : MacTheme.muted)
        .background(Capsule().fill(connected ? MacTheme.accentSoft : MacTheme.subtle))
        .overlay(Capsule().strokeBorder(connected ? Color.clear : MacTheme.border, lineWidth: 1))
        .help(status.isEmpty ? "서버 연결 상태를 확인하는 중입니다." : status)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(status.isEmpty ? label : status)
    }
}

enum MacTimeText {
    static func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.unitsStyle = .short
        formatter.dateTimeStyle = .named
        let now = Date()
        return formatter.localizedString(for: min(date, now), relativeTo: now)
    }
    /// 서버의 DateTimeOffset(예: 2026-10-27T03:04:05.1234567+00:00)을 읽습니다. 못 읽으면 nil.
    static func parse(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: text) { return date }
        let trimmed = text.replacingOccurrences(of: "\\.[0-9]+", with: "", options: .regularExpression)
        return formatter.date(from: trimmed)
    }
}

// MARK: - 보낼 기기

struct MacSendTarget: Identifiable, Equatable {
    enum Kind: Equatable { case device(String), computer(UUID) }
    let id: String
    let name: String
    let isOnline: Bool
    let detail: String
    /// 보낼 경로: 이 Mac이 추가한 연결(computer) 또는 이 Mac의 전송 대기열(device)
    let kind: Kind
    /// 이 Mac이 추가한 연결(있으면)과 그 기기가 이 Mac에 연결한 세션들. 삭제할 때 함께 지웁니다.
    var connectionID: UUID? = nil
    var peerIDs: [String] = []

    /// 기기마다 한 줄: 이 Mac에서 코드로 추가한 기기 + NAS로 이 Mac에 연결한 기기.
    /// 같은 기기는 상대가 알려 준 수신 ID로, 예전 앱이라 ID가 없으면 이름으로 합칩니다. 둘 다 있으면 추가한 연결로
    /// 보내고, 그쪽이 오프라인인데 상대가 이 Mac에서 받는 중이면 이 Mac의 전송 대기열로 보냅니다.
    /// 같은 기기인지: 상대가 알려 준 수신 ID로, 예전 앱이라 ID가 없으면 이름으로 비교합니다.
    @MainActor static func same(_ peer: MacReceiverDevice, _ connection: AhnaConnection) -> Bool {
        if !peer.computerID.isEmpty { return peer.computerID.lowercased() == (connection.computerID ?? "").lowercased() }
        return peer.name.trimmingCharacters(in: .whitespacesAndNewlines) == connection.hostName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @MainActor static func merged(receiver: MacReceiverModel, client: AhnaClient) -> [MacSendTarget] {
        func trim(_ value: String) -> String { value.trimmingCharacters(in: .whitespacesAndNewlines) }
        let peers = receiver.peers
        var claimed = Set<String>()
        var result: [MacSendTarget] = []
        for connection in client.connections {
            let matched = peers.filter { same($0, connection) }
            for peer in matched { claimed.insert(peer.id) }
            let live = matched.first { $0.online }
            let online = connection.state != nil
            let kind: Kind = !online && live != nil ? .device(live!.id) : .computer(connection.id)
            // 이름과 상태만: 오프라인이고 상대가 연결을 해제했을 때만 이유 한 줄(연결됨과 오류 문구가 함께 나오지 않게).
            result.append(MacSendTarget(id: "computer:" + connection.id.uuidString, name: connection.hostName, isOnline: online || live != nil,
                                        detail: online || live != nil || !connection.revoked ? "" : AhnaConnection.revokedMessage, kind: kind, connectionID: connection.id, peerIDs: matched.map { $0.id }))
        }
        struct PeerGroup { let key: String; let name: String; var members: [MacReceiverDevice] }
        var groups: [PeerGroup] = []
        let rest = peers.filter { !claimed.contains($0.id) }
        for peer in rest where !peer.computerID.isEmpty {
            if let index = groups.firstIndex(where: { $0.key == peer.computerID.lowercased() }) { groups[index].members.append(peer) }
            else { groups.append(PeerGroup(key: peer.computerID.lowercased(), name: peer.name, members: [peer])) }
        }
        for peer in rest where peer.computerID.isEmpty {
            if let index = groups.firstIndex(where: { trim($0.name) == trim(peer.name) }) { groups[index].members.append(peer) }
            else { groups.append(PeerGroup(key: "", name: peer.name, members: [peer])) }
        }
        for group in groups {
            let shown = group.members.first { $0.online } ?? group.members[0]
            let ids = group.members.map { $0.id }.sorted()
            result.append(MacSendTarget(id: "device:" + ids[0], name: shown.name, isOnline: shown.online, detail: "",
                                        kind: .device(shown.id), connectionID: nil, peerIDs: ids))
        }
        return result
    }

    /// 보낼 기기: 이 Mac이 추가한 기기는 늘, 이 Mac에만 연결한 기기는 지금 받을 수 있을 때만 보입니다.
    @MainActor static func all(receiver: MacReceiverModel, client: AhnaClient) -> [MacSendTarget] {
        merged(receiver: receiver, client: client).filter { $0.connectionID != nil || $0.isOnline }
    }
}

@MainActor final class MacFileSender: ObservableObject {
    @Published private(set) var sending = false
    @Published var notice = ""
    private var scoped: [URL] = []

    func send(_ urls: [URL], to target: MacSendTarget, receiver: MacReceiverModel, client: AhnaClient) {
        guard !urls.isEmpty else { return }
        guard !sending, !client.busy else { notice = "이전 전송이 끝난 뒤 다시 시도하세요."; return }
        switch target.kind {
        case .device(let id):
            sending = true
            notice = "\(target.name)(으)로 보낼 파일을 준비하는 중…"
            Task { @MainActor in
                defer { self.sending = false }
                do {
                    try await receiver.sendFiles(urls, target: id)
                    self.notice = "\(target.name)(으)로 파일 \(urls.count)개를 보냈습니다."
                } catch { self.notice = error.localizedDescription }
            }
        case .computer(let id):
            guard let connection = client.connections.first(where: { $0.id == id }) else { notice = "받을 기기를 다시 선택하세요."; return }
            release()
            for url in urls {
                if url.startAccessingSecurityScopedResource() { scoped.append(url) }
            }
            do {
                let files = try FilePreparation.collect(urls)
                client.selectedID = id
                if connection.send(files, completion: { [weak self] in self?.release() }) { notice = "" }
                else { release(); notice = "연결 상태를 확인해 주세요." }
            } catch { release(); notice = error.localizedDescription }
        }
    }
    func release() {
        for url in scoped { url.stopAccessingSecurityScopedResource() }
        scoped = []
    }
}

/// 끌어 놓은 파일 URL 모으기(콜백은 백그라운드 스레드에서 옵니다)
private final class MacDropCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [URL] = []
    func append(_ url: URL?) {
        guard let url, url.isFileURL else { return }
        lock.lock(); items.append(url); lock.unlock()
    }
    var urls: [URL] {
        lock.lock(); defer { lock.unlock() }
        return items
    }
}

@MainActor struct MacDropZone: View {
    let enabled: Bool
    let hint: String
    @Binding var targeted: Bool
    let onFiles: ([URL]) -> Void

    var body: some View {
        Button(action: choose) {
            VStack(spacing: 6) {
                ZStack {
                    Circle().fill(MacTheme.accentSoft)
                    Image(systemName: "arrow.up").font(.system(size: 18, weight: .semibold)).foregroundColor(MacTheme.accent)
                }
                .frame(width: 42, height: 42)
                Text("파일을 여기에 끌어 놓으세요").font(.system(size: 13, weight: .medium)).foregroundColor(MacTheme.text)
                Text(hint).font(.system(size: 12)).foregroundColor(MacTheme.faint)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 140, maxHeight: .infinity)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(targeted ? MacTheme.accentSoft : MacTheme.subtle))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(targeted ? MacTheme.accent : MacTheme.borderStrong, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 1 : 0.6)
        .onDrop(of: [UTType.fileURL], isTargeted: $targeted) { providers in handleDrop(providers) }
        .accessibilityLabel("파일 보내기")
        .accessibilityHint("눌러서 보낼 파일이나 폴더를 선택합니다. 파일을 끌어 놓아도 됩니다.")
    }

    private func choose() {
        guard enabled else { NSSound.beep(); return }
        let panel = NSOpenPanel()
        panel.title = "아나로 보낼 파일 선택"
        panel.prompt = "보내기"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK, !panel.urls.isEmpty { onFiles(panel.urls) }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard enabled else { return false }
        let type = UTType.fileURL.identifier
        let fileProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(type) }
        guard !fileProviders.isEmpty else { return false }
        let collector = MacDropCollector()
        let group = DispatchGroup()
        for provider in fileProviders {
            group.enter()
            provider.loadItem(forTypeIdentifier: type, options: nil) { item, _ in
                if let data = item as? Data { collector.append(URL(dataRepresentation: data, relativeTo: nil)) }
                else if let url = item as? URL { collector.append(url) }
                group.leave()
            }
        }
        let deliver = onFiles
        group.notify(queue: .main) {
            let urls = collector.urls
            guard !urls.isEmpty else { return }
            Task { @MainActor in deliver(urls) }
        }
        return true
    }
}

private struct MacPendingItem: Identifiable {
    let id: String
    let connection: AhnaConnection
    let file: InboxFile
}

// MARK: - 메인 창

@MainActor struct MacMainWindow: View {
    @ObservedObject var client: AhnaClient
    @ObservedObject private var receiver = MacReceiverModel.shared
    @ObservedObject private var history = ReceiveHistory.shared
    @ObservedObject private var updater = AppUpdater.shared
    @StateObject private var sender = MacFileSender()
    @ObservedObject private var nearby = NearbyCenter.shared
    @State private var selectedTarget = ""
    @State private var showOptions = false
    @State private var dropTargeted = false
    @State private var codeCopied = false

    private var targets: [MacSendTarget] { MacSendTarget.all(receiver: receiver, client: client) }
    private var target: MacSendTarget? { targets.first { $0.id == selectedTarget } }
    private var targetIDs: String { targets.map { $0.id }.joined(separator: "|") }
    private var selectedConnection: AhnaConnection? {
        guard let current = target, case .computer(let id) = current.kind else { return nil }
        return client.connections.first { $0.id == id }
    }
    /// 근처 기기를 골랐으면 그 기기
    private var selectedNearby: NearbyDevice? {
        guard selectedTarget.hasPrefix("nearby:") else { return nil }
        return nearby.devices.first { "nearby:" + $0.id.uuidString == selectedTarget }
    }
    private var nearbyBusy: Bool {
        guard let current = nearby.outgoing else { return false }
        switch current.phase { case .preparing, .waiting, .sending: return true; default: return false }
    }
    private var canSendFiles: Bool {
        if selectedNearby != nil { return !nearbyBusy }
        guard let current = target else { return false }
        return current.isOnline && !client.busy && !sender.sending
    }
    private var dropHint: String {
        if let device = selectedNearby { return nearbyBusy ? "보내는 중입니다 · 끝난 뒤 다시 보낼 수 있습니다" : "\(device.name)에게 보내면 상대가 받을지 확인합니다" }
        guard let current = target else { return "먼저 위에서 보낼 기기를 선택하세요" }
        if !current.isOnline { return "\(current.name)이(가) 오프라인입니다 · 연결된 기기를 선택하세요" }
        if client.busy || sender.sending { return "보내는 중입니다 · 끝난 뒤 다시 보낼 수 있습니다" }
        return "또는 눌러서 선택 · Finder 공유 메뉴에서도 보낼 수 있습니다"
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            ZStack(alignment: .trailing) {
                VStack(spacing: 0) {
                    updateStrip
                    columns.padding(16)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                // 근처 기기 · QR 창 (가운데)
                if nearby.incoming != nil || nearby.outgoing != nil || nearby.qr != nil {
                    ZStack {
                        Color.black.opacity(0.28).ignoresSafeArea()
                        if let incoming = nearby.incoming { MacIncomingCard(center: nearby, incoming: incoming) }
                        else if let outgoing = nearby.outgoing { MacOutgoingCard(center: nearby, outgoing: outgoing) }
                        else if let qr = nearby.qr { MacQRCard(center: nearby, qr: qr) }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .zIndex(3)
                }
                if showOptions {
                    Color.black.opacity(0.25)
                        .contentShape(Rectangle())
                        .onTapGesture { setOptions(false) }
                        .transition(.opacity)
                        .accessibilityHidden(true)
                        .zIndex(1)
                    MacOptionsDrawer(client: client, receiver: receiver, updater: updater, close: { setOptions(false) })
                        .frame(width: 400)
                        .frame(maxHeight: .infinity)
                        .transition(.move(edge: .trailing))
                        .zIndex(2)
                }
            }
            .clipped()
        }
        .background(MacTheme.bg)
        .foregroundColor(MacTheme.text)
        .font(.system(size: 13))
        .tint(MacTheme.accent)
        .onAppear { selectAvailableTarget(); nearby.start(host: receiver, name: client.deviceName) }
        .onChange(of: client.deviceName) { name in nearby.refreshName(name) }
        // 아나: 처음 실행하면 초대 코드로 서버에 가입합니다.
        .sheet(isPresented: Binding(get: { receiver.joined == false }, set: { _ in })) { MacJoinView(receiver: receiver) }
        .onChange(of: targetIDs) { _ in selectAvailableTarget() }
        .onChange(of: client.busy) { busy in if !busy { sender.release() } }
    }

    // MARK: 맨 위 막대

    private var topBar: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous).fill(MacTheme.accent)
                Image(systemName: "paperplane.fill").font(.system(size: 13, weight: .semibold)).foregroundColor(MacTheme.onAccent)
            }
            .frame(width: 26, height: 26)
            .accessibilityHidden(true)
            Text("아나").font(.system(size: 15, weight: .bold))
            Text("v" + AppUpdater.currentVersion)
                .font(.system(size: 12).monospacedDigit())
                .foregroundColor(MacTheme.faint)
                .accessibilityLabel("버전 " + AppUpdater.currentVersion)
            MacNASPill(status: (!receiver.remoteStatus.hasPrefix("서버 연결됨") && client.connections.contains(where: { $0.state != nil })) ? "서버 연결됨" : receiver.remoteStatus).padding(.leading, 6)
            Spacer(minLength: 12)
            if !receiver.announcements.isEmpty {
                Button(action: { receiver.showNotices = true }) {
                    HStack(spacing: 6) {
                        Image(systemName: receiver.unreadNotices > 0 ? "bell.badge.fill" : "bell")
                        Text("공지")
                        if receiver.unreadNotices > 0 {
                            Text("\(receiver.unreadNotices)").font(.system(size: 11, weight: .bold)).foregroundColor(.white)
                                .padding(.horizontal, 6).frame(minWidth: 18, minHeight: 18).background(Capsule().fill(Color.red))
                        }
                    }
                }
                .buttonStyle(MacButtonStyle(kind: .secondary, height: 30, fontSize: 13))
                .help(receiver.unreadNotices > 0 ? "읽지 않은 공지 \(receiver.unreadNotices)개" : "공지")
                .sheet(isPresented: $receiver.showNotices) { MacNoticesView(receiver: receiver) }
            }
            Button(action: { setOptions(!showOptions) }) {
                HStack(spacing: 6) {
                    Image(systemName: "sidebar.right")
                    Text("옵션")
                }
            }
            .buttonStyle(MacButtonStyle(kind: showOptions ? .selected : .secondary, height: 30, fontSize: 13))
            .help(showOptions ? "옵션 닫기" : "옵션 열기")
            .accessibilityLabel(showOptions ? "옵션 닫기" : "옵션 열기")
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
        .background(MacTheme.surface)
        .overlay(alignment: .bottom) { MacHairline() }
    }

    @ViewBuilder private var updateStrip: some View {
        switch updater.phase {
        case .available, .downloading:
            HStack(spacing: 0) {
                UpdateBanner(updater: updater)
                Spacer(minLength: 0)
            }
            .macCard(padding: 10)
            .padding([.horizontal, .top], 16)
        default:
            EmptyView()
        }
    }

    private var columns: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 14) {
                codeCard
                devicesCard
                sendCard
            }
            .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            MacClipboardView(receiver: receiver, client: client, selectedTarget: $selectedTarget)
                .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            filesCard
                .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    // MARK: 1열

    private var formattedPin: String {
        let pin = receiver.pin
        if pin.isEmpty { return "······" }
        if pin.count == 6 { return String(pin.prefix(3)) + " " + String(pin.suffix(3)) }
        return pin
    }

    private var codeCard: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 0) {
                Text("이 Mac의 연결 코드").font(.system(size: 12)).opacity(0.9)
                Text(formattedPin)
                    .font(.system(size: 26, weight: .bold).monospacedDigit())
                    .kerning(5)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .textSelection(.enabled)
                    .accessibilityLabel(receiver.pin.isEmpty ? "연결 코드 준비 중" : "연결 코드 " + receiver.pin)
            }
            Spacer(minLength: 0)
            Button(codeCopied ? "복사됨" : "복사") { copyPin() }
                .buttonStyle(MacButtonStyle(kind: .onAccent, height: 28))
                .disabled(receiver.pin.isEmpty)
                .help("다른 기기에서 이 Mac을 추가할 때 입력하는 코드입니다.")
                .accessibilityLabel("연결 코드 복사")
        }
        .foregroundColor(MacTheme.onAccent)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(MacTheme.accent))
    }

    private var devicesCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("보낼 기기").font(.system(size: 14, weight: .bold)).padding(.bottom, 4)
            if targets.isEmpty {
                Text("아직 연결된 기기가 없습니다. 오른쪽 위 옵션에서 상대 기기의 연결 코드로 추가하세요.")
                    .font(.system(size: 12)).foregroundColor(MacTheme.faint)
                    .fixedSize(horizontal: false, vertical: true)
            } else if targets.count > 5 {
                ScrollView { deviceRows }.frame(height: 5 * 50)
            } else {
                deviceRows
            }
            MacNearbyRows(center: nearby, selected: selectedTarget) { device in selectedTarget = "nearby:" + device.id.uuidString }
        }
        .macCard()
    }

    private var deviceRows: some View {
        VStack(spacing: 6) {
            ForEach(targets) { item in deviceRow(item) }
        }
    }

    private func deviceRow(_ item: MacSendTarget) -> some View {
        let selected = item.id == selectedTarget
        return Button(action: { select(item) }) {
            HStack(spacing: 10) {
                Text(item.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(item.isOnline ? MacTheme.text : MacTheme.muted)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                MacStatusDot(isOnline: item.isOnline)
            }
            .padding(.horizontal, 10)
            .frame(minHeight: 44)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(selected ? MacTheme.accentSoft : MacTheme.surface))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(selected ? MacTheme.accent : MacTheme.border, lineWidth: selected ? 2 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(item.detail)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.name + ", " + (item.isOnline ? "연결됨" : "오프라인"))
        .accessibilityAddTraits(selected ? AccessibilityTraits.isSelected : AccessibilityTraits())
        .accessibilityAddTraits(AccessibilityTraits.isButton)
    }

    private var sendCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("파일 보내기").font(.system(size: 14, weight: .bold))
            MacDropZone(enabled: canSendFiles, hint: dropHint, targeted: $dropTargeted) { urls in sendFiles(urls) }
            sendStatus
        }
        .macCard(fill: true)
    }

    @ViewBuilder private var sendStatus: some View {
        if let connection = selectedConnection, connection.busy || !connection.progress.isEmpty {
            if connection.busy, let fraction = connection.fraction {
                HStack(spacing: 8) {
                    ProgressView(value: fraction).tint(MacTheme.accent)
                    Text("\(Int(fraction * 100))%").font(.system(size: 12, weight: .semibold).monospacedDigit()).foregroundColor(MacTheme.accent)
                }
            }
            HStack(alignment: .top, spacing: 8) {
                Text(connection.progress)
                    .font(.system(size: 12)).foregroundColor(MacTheme.muted)
                    .lineLimit(3).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if connection.busy {
                    Button("전송 중단") { connection.cancel() }
                        .buttonStyle(MacButtonStyle(kind: .secondary, height: 26))
                }
            }
        }
        if !sender.notice.isEmpty {
            Text(sender.notice)
                .font(.system(size: 12)).foregroundColor(MacTheme.muted)
                .lineLimit(3).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: 3열

    private var pendingItems: [MacPendingItem] {
        client.connections.flatMap { connection in
            (connection.state?.items ?? [])
                .filter { connection.savedURL($0) == nil }
                .map { MacPendingItem(id: connection.id.uuidString + $0.id, connection: connection, file: $0) }
        }
    }

    private var filesCard: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text("받은 파일").font(.system(size: 14, weight: .bold))
                Text("\(history.entries.count)/10").font(.system(size: 12).monospacedDigit()).foregroundColor(MacTheme.faint)
                Spacer(minLength: 0)
                Button("목록 초기화") { history.clear() }
                    .buttonStyle(MacButtonStyle(kind: .plain, height: 26))
                    .disabled(history.entries.isEmpty)
            }
            .padding(.bottom, 4)
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(history.entries) { item in fileRow(item) }
                    if history.entries.isEmpty {
                        Text("받은 파일 기록이 없습니다.")
                            .font(.system(size: 12)).foregroundColor(MacTheme.faint)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 8)
                    }
                    if !client.autoSave && !pendingItems.isEmpty {
                        Text("저장 대기")
                            .font(.system(size: 12, weight: .bold)).foregroundColor(MacTheme.muted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 12)
                        ForEach(pendingItems) { item in pendingRow(item) }
                    }
                }
            }
            HStack(spacing: 6) {
                Text("최근 10개 · 목록을 지워도 파일은 유지됩니다.")
                    .font(.system(size: 11.5)).foregroundColor(MacTheme.faint)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("폴더 열기") { NSWorkspace.shared.open(ReceiveFolder.currentURL()) }
                    .buttonStyle(MacButtonStyle(kind: .plain, height: 26))
            }
            .padding(.top, 6)
        }
        .macCard(fill: true)
    }

    private func fileMeta(_ item: ReceiveHistory.Entry) -> String {
        var parts = [item.source, MacTimeText.relative(item.received)]
        if let attributes = try? FileManager.default.attributesOfItem(atPath: item.url.path),
           let size = attributes[.size] as? NSNumber {
            parts.append(ByteCountFormatter.string(fromByteCount: size.int64Value, countStyle: .file))
        }
        return parts.joined(separator: " · ")
    }

    private func fileIcon(_ systemName: String) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous).fill(MacTheme.subtle)
            Image(systemName: systemName).font(.system(size: 13)).foregroundColor(MacTheme.muted)
        }
        .frame(width: 30, height: 30)
        .accessibilityHidden(true)
    }

    private func fileRow(_ item: ReceiveHistory.Entry) -> some View {
        HStack(spacing: 10) {
            fileIcon("doc")
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.middle)
                Text(fileMeta(item)).font(.system(size: 11.5)).foregroundColor(MacTheme.faint).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("열기") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
                .buttonStyle(MacButtonStyle(kind: .secondary, height: 26))
                .accessibilityLabel(item.name + " Finder에서 보기")
        }
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) { MacHairline() }
        .help(item.url.path)
    }

    private func pendingRow(_ item: MacPendingItem) -> some View {
        HStack(spacing: 10) {
            fileIcon("arrow.down.doc")
            VStack(alignment: .leading, spacing: 1) {
                Text(item.file.name).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.middle)
                Text(item.connection.hostName + " · " + ByteCountFormatter.string(fromByteCount: item.file.bytes, countStyle: .file))
                    .font(.system(size: 11.5)).foregroundColor(MacTheme.faint).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("지금 저장") {
                let connection = item.connection
                let file = item.file
                Task { @MainActor in
                    do { _ = try await connection.saveToFiles(file) } catch { connection.progress = error.localizedDescription }
                }
            }
            .buttonStyle(MacButtonStyle(kind: .soft, height: 26))
            .disabled(item.connection.busy)
        }
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) { MacHairline() }
    }

    // MARK: 동작

    private func setOptions(_ open: Bool) {
        withAnimation(.easeOut(duration: 0.2)) { showOptions = open }
    }

    private func select(_ item: MacSendTarget) {
        selectedTarget = item.id
        if case .computer(let id) = item.kind { client.selectedID = id }
    }

    private func selectAvailableTarget() {
        if selectedNearby != nil { return }
        let list = targets
        guard !list.contains(where: { $0.id == selectedTarget }) else { return }
        if let first = list.first(where: { $0.isOnline }) ?? list.first { select(first) }
        else { selectedTarget = "" }
    }

    private func sendFiles(_ urls: [URL]) {
        if let device = selectedNearby { nearby.send(to: device, urls: urls); return }
        guard let current = target else { sender.notice = "보낼 기기를 먼저 선택하세요."; return }
        guard current.isOnline else { sender.notice = "\(current.name)이(가) 오프라인입니다. 연결된 기기를 선택하세요."; return }
        sender.send(urls, to: current, receiver: receiver, client: client)
    }

    private func copyPin() {
        let pin = receiver.pin
        guard !pin.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(pin, forType: .string)
        codeCopied = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            codeCopied = false
        }
    }
}

// MARK: - 옵션 패널

@MainActor struct MacOptionsDrawer: View {
    @ObservedObject var client: AhnaClient
    @ObservedObject var receiver: MacReceiverModel
    @ObservedObject var updater: AppUpdater
    let close: () -> Void
    @AppStorage(ReceiveFolder.preferenceKey) private var folderPath = ""
    private enum Editor { case name, nas }
    @State private var editing: Editor?
    @State private var nameDraft = ""
    @State private var pendingDelete: MacSendTarget?
    @State private var folderError = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text("옵션").font(.system(size: 15, weight: .bold))
                Spacer(minLength: 0)
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 34, height: 34)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundColor(MacTheme.muted)
                .keyboardShortcut(.cancelAction)
                .help("옵션 닫기")
                .accessibilityLabel("옵션 닫기")
            }
            .padding(.leading, 18)
            .padding(.trailing, 8)
            .frame(height: 48)
            .overlay(alignment: .bottom) { MacHairline() }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    MacMeaningBanner()
                    devicesSection
                    MacNearbyOptions(center: NearbyCenter.shared, guestReady: receiver.guestReady)
                    rowsSection
                    appInfoSection
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)
            }
        }
        .background(MacTheme.surface)
        .overlay(alignment: .leading) { Rectangle().fill(MacTheme.border).frame(width: 1) }
        .shadow(color: Color.black.opacity(0.16), radius: 18, x: -14, y: 0)
        .confirmationDialog(
            "연결을 삭제할까요?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { device in
            Button("삭제", role: .destructive) { forget(device) }
            Button("취소", role: .cancel) {}
        } message: { device in
            Text("\(device.name) 연결을 삭제합니다. 다시 추가하려면 상대 기기의 연결 코드가 필요합니다.")
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text).font(.system(size: 12, weight: .bold)).foregroundColor(MacTheme.muted)
    }

    // MARK: 연결된 기기

    private var devicesSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionTitle("연결된 기기").padding(.bottom, 4)
            ForEach(linked) { device in
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(device.name)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(device.isOnline ? MacTheme.text : MacTheme.muted)
                            .lineLimit(1)
                        // 오프라인일 때만 이유 한 줄 (예: 상대 기기에서 연결을 해제했습니다 · 다시 추가하세요)
                        if !device.isOnline && !device.detail.isEmpty {
                            Text(device.detail)
                                .font(.system(size: 11))
                                .foregroundColor(MacTheme.faint)
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(device.detail)
                    MacStatusDot(isOnline: device.isOnline)
                    Button(action: { pendingDelete = device }) {
                        ZStack {
                            Circle().fill(MacTheme.dangerSoft)
                            Image(systemName: "xmark").font(.system(size: 8, weight: .heavy)).foregroundColor(MacTheme.danger)
                        }
                        .frame(width: 20, height: 20)
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(client.busy)
                    .help(device.name + " 연결 삭제")
                    .accessibilityLabel(device.name + " 연결 삭제")
                }
                .frame(minHeight: 42)
                .overlay(alignment: .bottom) { MacHairline() }
            }
            if linked.isEmpty {
                Text("아직 추가한 기기가 없습니다.")
                    .font(.system(size: 12)).foregroundColor(MacTheme.faint)
                    .padding(.vertical, 8)
            }
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    TextField("상대 기기의 6자리 코드", text: $client.pin)
                        .macField()
                        .onSubmit { addDevice() }
                        .accessibilityLabel("상대 기기의 6자리 코드")
                    Button("기기 추가") { addDevice() }
                        .buttonStyle(MacButtonStyle(kind: .primary, height: 34, fontSize: 13))
                        .disabled(client.busy)
                }
            }
            .padding(.top, 10)
            if !client.status.isEmpty {
                Text(client.status)
                    .font(.system(size: 12)).foregroundColor(MacTheme.faint)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
            }
        }
    }

    // MARK: 설정 행

    private var nasSummary: String {
        if receiver.joined == false { return "초대 코드 필요" }
        let status = receiver.remoteStatus.components(separatedBy: " · ").first ?? ""
        return status.isEmpty ? "연결됨" : "연결됨 · " + status
    }

    private var folderDisplay: String {
        _ = folderPath
        return (ReceiveFolder.currentURL().path as NSString).abbreviatingWithTildeInPath
    }

    private var rowsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            optionRow("이 Mac의 이름", value: client.deviceName.isEmpty ? "이름 없음" : client.deviceName,
                      action: editing == .name ? "닫기" : "변경") { toggle(.name) }
            if editing == .name { nameEditor }
            if !client.deviceNameStatus.isEmpty {
                Text(client.deviceNameStatus)
                    .font(.system(size: 12)).foregroundColor(MacTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(alignment: .bottom) { MacHairline() }
            }
            optionRow("서버", value: nasSummary, action: editing == .nas ? "닫기" : "변경") { toggle(.nas) }
            if editing == .nas { nasEditor }
            optionRow("받은 파일 저장 위치", value: folderDisplay, action: "폴더 선택", disabled: client.busy) { chooseFolder() }
            folderExtras
        }
        .overlay(alignment: .top) { MacHairline() }
    }

    private func optionRow(_ label: String, value: String, action: String, disabled: Bool = false, perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(label).font(.system(size: 13)).foregroundColor(MacTheme.text)
                    Text(value).font(.system(size: 12)).foregroundColor(MacTheme.faint).lineLimit(1).truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(action).font(.system(size: 12, weight: .medium)).foregroundColor(MacTheme.accent)
            }
            .frame(minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.5 : 1)
        .overlay(alignment: .bottom) { MacHairline() }
        .accessibilityLabel(label + ", " + value)
        .accessibilityHint(action)
    }

    private var nameEditor: some View {
        HStack(spacing: 8) {
            TextField("예: 내 MacBook", text: $nameDraft)
                .macField()
                .onSubmit { saveName() }
                .accessibilityLabel("이 Mac의 이름")
            Button("저장") { saveName() }
                .buttonStyle(MacButtonStyle(kind: .primary, height: 34, fontSize: 13))
                .disabled(client.busy || nameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) { MacHairline() }
    }

    private var nasEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("새 초대 코드 · 다시 연결할 때만", text: $receiver.remoteKey)
                .macField()
                .onSubmit { receiver.saveOptions() }
                .accessibilityLabel("초대 코드")
            HStack(spacing: 8) {
                Text("설정 후 자동으로 서버에 연결됩니다.")
                    .font(.system(size: 12)).foregroundColor(MacTheme.faint)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("저장") { receiver.saveOptions() }
                    .buttonStyle(MacButtonStyle(kind: .primary, height: 30, fontSize: 13))
            }
            if !receiver.remoteStatus.isEmpty {
                Text(receiver.remoteStatus).font(.system(size: 12)).foregroundColor(MacTheme.muted)
            }
            if !receiver.message.isEmpty {
                Text(receiver.message)
                    .font(.system(size: 12)).foregroundColor(MacTheme.muted)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) { MacHairline() }
    }

    private var folderExtras: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("받은 파일 자동 저장").font(.system(size: 13))
                Spacer(minLength: 0)
                Toggle("받은 파일 자동 저장", isOn: $client.autoSave)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            HStack(spacing: 8) {
                Button("Finder에서 열기") { NSWorkspace.shared.open(ReceiveFolder.currentURL()) }
                    .buttonStyle(MacButtonStyle(kind: .secondary, height: 28))
                Spacer(minLength: 0)
            }
            Text("변경 후 수신하는 파일부터 선택한 폴더에 저장합니다. 기존 파일은 이동하지 않습니다. 외장 드라이브나 공유 폴더를 선택하면 연결된 동안 사용할 수 있습니다.")
                .font(.system(size: 12)).foregroundColor(MacTheme.faint)
                .fixedSize(horizontal: false, vertical: true)
            if client.busy {
                Text("전송이 끝난 뒤 저장 폴더를 변경할 수 있습니다.").font(.system(size: 12)).foregroundColor(MacTheme.muted)
            }
            if !folderError.isEmpty {
                Text(folderError).font(.system(size: 12)).foregroundColor(MacTheme.danger).textSelection(.enabled)
            }
        }
        .padding(.vertical, 10)
    }

    // MARK: 앱 정보

    private var updateText: String {
        switch updater.phase {
        case .idle: return "업데이트를 확인하려면 버튼을 누르세요"
        case .checking: return "확인 중…"
        case .upToDate: return "최신 버전입니다"
        case .available(let version): return "새 버전 있음 · v" + version
        case .downloading: return "새 버전을 내려받는 중…"
        case .failed: return "업데이트를 확인하지 못했습니다"
        }
    }

    private var appInfoSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("아나 v" + AppUpdater.currentVersion).font(.system(size: 13, weight: .bold))
                    Text(updateText).font(.system(size: 12)).foregroundColor(MacTheme.faint)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button("업데이트 확인") { Task { await updater.check(force: true) } }
                    .buttonStyle(MacButtonStyle(kind: .secondary, height: 30))
                    .disabled(updater.phase == .checking || updater.phase == .downloading)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(MacTheme.subtle))
            UpdateBanner(updater: updater)
        }
    }

    // MARK: 동작

    private func toggle(_ editor: Editor) {
        if editor == .name && editing != .name { nameDraft = client.deviceName }
        withAnimation(.easeOut(duration: 0.15)) { editing = editing == editor ? nil : editor }
    }

    private func saveName() {
        guard !client.busy else { return }
        client.deviceName = nameDraft
        Task { await client.saveDeviceName() }
    }

    private func addDevice() {
        guard !client.busy else { return }
        client.hostIdentity = receiver.computerID
        Task { await client.connect() }
    }

    /// 연결된 기기: 이 Mac이 추가한 기기 + 이 Mac에 연결한 기기 (기기마다 한 줄)
    private var linked: [MacSendTarget] { MacSendTarget.merged(receiver: receiver, client: client) }

    /// 이 Mac이 추가한 연결과, 그 기기가 이 Mac에 연결한 세션을 함께 지웁니다.
    private func forget(_ device: MacSendTarget) {
        let connection = client.connections.first { $0.id == device.connectionID }
        let peers = device.peerIDs
        Task { @MainActor in
            if let connection { await client.forget(connection) }
            do { try await receiver.forget(peers) } catch { client.status = error.localizedDescription }
        }
    }

    private func chooseFolder() {
        folderError = ReceiveOptions.pickFolder(client: client) ?? ""
    }
}


// MARK: - 아나: 이름 풀이 · 첫 실행 가입

struct MacMeaningBanner: View {
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "paperplane")
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(MacTheme.onAccent)
                .frame(width: 36, height: 36)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(MacTheme.accent))
            VStack(alignment: .leading, spacing: 2) {
                Text("아나").font(.system(size: 15, weight: .heavy))
                Text("경상도 말로 “옛다, 받아라”").font(.system(size: 12)).foregroundColor(MacTheme.muted)
                Text("— 툭 건네듯 주고받으세요").font(.system(size: 12)).foregroundColor(MacTheme.muted)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(MacTheme.subtle))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(MacTheme.border, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}

@MainActor struct MacJoinView: View {
    @ObservedObject var receiver: MacReceiverModel
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "paperplane")
                .font(.system(size: 34, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: 76, height: 76)
                .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color(red: 0.0, green: 0.373, blue: 0.722)))
            Text("아나").font(.system(size: 28, weight: .heavy))
            Text("받은 초대 코드를 입력하면 바로 시작합니다").font(.system(size: 13)).foregroundColor(MacTheme.muted)
            TextField("초대 코드", text: $receiver.remoteKey)
                .macField()
                .multilineTextAlignment(.center)
                .frame(width: 260)
                .onSubmit { receiver.saveOptions() }
            Button(receiver.joining ? "연결 중…" : "시작하기") { receiver.saveOptions() }
                .buttonStyle(MacButtonStyle(kind: .primary, height: 36, fontSize: 14))
                .disabled(receiver.joining || receiver.remoteKey.trimmingCharacters(in: .whitespaces).isEmpty)
                .keyboardShortcut(.defaultAction)
            if !receiver.message.isEmpty {
                Text(receiver.message).font(.system(size: 12)).foregroundColor(MacTheme.danger)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(32)
        .frame(width: 400)
        .background(MacTheme.bg)
    }
}

// MARK: - 서버 관리자 공지

@MainActor struct MacNoticesView: View {
    @ObservedObject var receiver: MacReceiverModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("공지").font(.system(size: 17, weight: .bold))
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(receiver.announcements) { note in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(note.text).font(.system(size: 14)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            HStack {
                                Text(note.created.formatted(date: .abbreviated, time: .shortened) + (note.read ? " · 읽음 · 3일 뒤 사라짐" : " · 읽지 않음"))
                                    .font(.system(size: 12)).foregroundColor(MacTheme.faint)
                                Spacer()
                                if note.read {
                                    Button("삭제") { receiver.deleteAnnouncement(note.id) }.buttonStyle(MacButtonStyle(kind: .secondary, height: 26, fontSize: 12))
                                } else {
                                    Button("읽음") { receiver.readAnnouncement(note.id) }.buttonStyle(MacButtonStyle(kind: .primary, height: 26, fontSize: 12))
                                }
                            }
                        }
                        .padding(14)
                        .background(RoundedRectangle(cornerRadius: 10).fill(MacTheme.surface))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(note.read ? MacTheme.border : MacTheme.accent, lineWidth: 1))
                    }
                }
            }
            .frame(maxHeight: 420)
            HStack { Spacer(); Button("닫기") { dismiss() }.buttonStyle(MacButtonStyle(kind: .secondary, height: 30, fontSize: 13)).keyboardShortcut(.cancelAction) }
        }
        .padding(22).frame(width: 460)
    }
}
