import SwiftUI
import UIKit
import PhotosUI
import UniformTypeIdentifiers

@main struct AhnaApp: App { var body: some Scene { WindowGroup { HomeView() } } }

// 머리글의 서버 표시: 이 기기가 받는 통로(브리지)나 보내는 연결 중 하나라도 서버로 통하면 '연결됨'.
// 예전에는 받는 통로만 보고 판단해서, 실제로는 서버로 주고받는 중인데 '연결 안 됨'으로 보였습니다.
@MainActor func nasHeaderStatus(host: MobileHostModel, client: AhnaClient) -> String {
    if host.remoteStatus.contains("연결됨") { return host.remoteStatus }
    if client.connections.contains(where: { $0.state != nil }) { return "서버 연결됨" }
    return host.remoteStatus
}

// 숫자 키패드에는 '완료' 키가 없어서, 입력하지 않고 닫을 방법이 없었습니다.
// 키보드 위 '완료' 버튼, 화면 빈 곳 누르기, 스크롤로 언제든 키보드를 내립니다.
func hideKeyboard() {
    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
}

extension View {
    func keyboardDoneButton() -> some View {
        toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("완료") { hideKeyboard() }.fontWeight(.semibold)
            }
        }
    }
}

// 아나 1.1 — 지금 창의 너비로 배치를 고릅니다(AhnaLayout): 700pt 미만 휴대폰 배치(1열) ·
// 700~999pt 2열(iPad 세로) · 1000pt 이상 3열(iPad 가로). 회전·Split View·Slide Over로 너비가 바뀌면 바로 다시 배치합니다.
// 탭 막대는 시스템 TabView가 그립니다(iOS 26에서는 떠 있는 캡슐 모양).
struct HomeView: View {
    @StateObject private var client = AhnaClient(receive: true)
    @StateObject private var host = MobileHostModel()
    @StateObject private var updater = AppUpdater()
    @StateObject private var nearby = NearbyCenter()
    @Environment(\.scenePhase) private var phase
    @State private var tab = 0
    var body: some View {
        TabView(selection: $tab) {
            SendReceiveScreen(client: client, host: host, nearby: nearby)
                .tabItem { Label("주고받기", systemImage: "arrow.left.arrow.right") }.tag(0)
            OptionsScreen(client: client, host: host, updater: updater, nearby: nearby)
                .tabItem { Label("옵션", systemImage: "gearshape.fill") }.tag(1)
        }
        .tint(AhnaPalette.accent)
        // 근처 기기 · QR로 받기 확인 창. QR · 보내기 창이 떠 있으면 그 창 안에 띄웁니다.
        .overlay { if nearby.incoming != nil && nearby.sheetDepth == 0 { NearbyRequestOverlay(center: nearby) } }
        // 아나: 처음 실행하면 초대 코드로 서버에 가입합니다(가입 전에는 닫을 수 없음).
        .fullScreenCover(isPresented: $host.needsJoin) { JoinScreen(host: host) }
        .task(id: "\(phase)-\(client.pollID)") {
            // 이 기기 수신 쪽의 ID를 연결·상태 확인 때 함께 보내, 상대 기기가 이 기기를 한 번만 보여 주게 합니다.
            client.hostIdentity = host.engine?.identity
            if phase == .active { await client.poll() }
        }
        .onAppear { client.hostIdentity = host.engine?.identity; connectBothWays(); host.start(); nearby.attach(host: host); nearby.setForeground(true) }
        .task { await updater.check() }
        // 수신(MobileHTTPHost)과 Bluetooth는 앱이 화면에 있을 때만 동작합니다.
        .onChange(of: phase) { _, value in
            if value == .active { host.start(); nearby.setForeground(true) }
            else if value == .background { host.stop(); nearby.setForeground(false) }
        }
        .onChange(of: client.deviceNameStatus) { _, _ in nearby.refreshName() }
    }
}

extension HomeView {
    /// 한 번의 코드 입력으로 양쪽 연결: 이 기기가 추가할 때 이 기기 쪽 연결을 함께 보내고, 상대가 이 기기와 연결하며
    /// 넘겨준 그 기기 쪽 연결은 추가한 기기로 저장합니다(공유 메뉴도 같은 저장소를 읽습니다).
    /// 상대가 이 기기의 연결을 해제했을 때 그 기기가 이 기기에 연결한 쪽이 남아 있으면 죽은 연결만 지웁니다.
    @MainActor private func connectBothWays() {
        let client = self.client, host = self.host
        client.reverseOffer = { await host.reverseOffer() }
        client.reverseComplete = { token, accepted, name, computerID in host.reverseComplete(token: token, accepted: accepted, name: name, computerID: computerID) }
        client.inboundExists = { connection in host.peers.contains { sameDevice($0, connection) } }
        host.reverseReceived = { credential in client.addReverse(credential) }
    }
}

// MARK: - 공통 머리글 · 페이지

struct ScreenHeader: View {
    let title: String
    var showsLogo = true
    var showsVersion = false
    let nasStatus: String
    let regular: Bool
    var detail: String? = nil
    var body: some View {
        HStack(spacing: regular ? 12 : 10) {
            if showsLogo { AhnaLogoTile(size: regular ? 36 : 32) }
            Text(title)
                .font(.system(size: regular ? 22 : 19, weight: .bold))
                .kerning(-0.3)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            if showsVersion {
                Text("v" + AppUpdater.currentVersion)
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(AhnaPalette.faint)
                    .accessibilityLabel("버전 " + AppUpdater.currentVersion)
            }
            if regular {
                NASStatusPill(status: nasStatus)
                Spacer(minLength: 8)
                if let detail {
                    Text(detail).font(.system(size: 13)).foregroundStyle(AhnaPalette.faint).lineLimit(1)
                }
            } else {
                Spacer(minLength: 8)
                NASStatusPill(status: nasStatus)
            }
        }
        .foregroundStyle(AhnaPalette.text)
        .padding(.horizontal, regular ? 24 : 16)
        .frame(height: regular ? 68 : 60)
        .background {
            if !regular { AhnaPalette.surface.ignoresSafeArea(edges: .top) }
        }
        .overlay(alignment: .bottom) {
            if !regular { AhnaDivider() }
        }
    }
}

struct AhnaPage<Content: View>: View {
    let header: ScreenHeader
    let content: Content
    init(header: ScreenHeader, @ViewBuilder content: () -> Content) {
        self.header = header
        self.content = content()
    }
    var body: some View {
        VStack(spacing: 0) {
            header
            NavigationStack {
                ScrollView {
                    content
                        .contentShape(Rectangle())
                        .onTapGesture { hideKeyboard() }
                }
                .scrollDismissesKeyboard(.immediately)
                .background(AhnaPalette.bg.ignoresSafeArea())
                .toolbar(.hidden, for: .navigationBar)
                .keyboardDoneButton()
            }
        }
        .foregroundStyle(AhnaPalette.text)
        .background(AhnaPalette.bg.ignoresSafeArea())
    }
}

struct CardTitle: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.system(size: 16, weight: .bold)).foregroundStyle(AhnaPalette.text).accessibilityAddTraits(.isHeader)
    }
}

/// 사진 보관함에서 고른 사진·동영상을 임시 파일로 받습니다.
struct PickedMediaFile: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in try PickedMediaFile.copy(received.file) }
        FileRepresentation(importedContentType: .image) { received in try PickedMediaFile.copy(received.file) }
        FileRepresentation(importedContentType: .data) { received in try PickedMediaFile.copy(received.file) }
    }
    private static func copy(_ source: URL) throws -> PickedMediaFile {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ahna-pick-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent(source.lastPathComponent.isEmpty ? "사진" : source.lastPathComponent)
        try FileManager.default.copyItem(at: source, to: destination)
        return PickedMediaFile(url: destination)
    }
}

// MARK: - 기기 목록 (보낼 기기 · 연결된 기기)

/// 한 기기 = 한 줄. 이 기기가 코드로 추가한 연결(connection)과, 그 기기가 이 기기에 연결한 세션(peerIDs)을 합칩니다.
struct DeviceEntry: Identifiable {
    let id: String
    let name: String
    let isOnline: Bool
    let connection: AhnaConnection?
    let peerIDs: [String]
    /// 지금 이 기기에서 받는 중인 세션(있으면)
    let livePeer: String?
    /// 추가한 연결이 기본. 그쪽이 오프라인이고 상대가 이 기기에서 받는 중이면 이 기기의 전송 대기열로 보냅니다.
    @MainActor var sendsThroughHost: Bool { (connection == nil || connection?.state == nil) && livePeer != nil }
}

/// 같은 기기인지: 상대가 알려 준 수신 ID로, 예전 앱이라 ID가 없으면 이름으로 비교합니다.
@MainActor func sameDevice(_ peer: HostPeer, _ connection: AhnaConnection) -> Bool {
    if !peer.computerID.isEmpty { return peer.computerID.lowercased() == (connection.computerID ?? "").lowercased() }
    return peer.name.trimmingCharacters(in: .whitespacesAndNewlines) == connection.hostName.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// 같은 기기는 상대가 알려 준 수신 ID로, 예전 앱이라 ID가 없으면 이름으로 합칩니다.
@MainActor func mergedDevices(_ connections: [AhnaConnection], _ peers: [HostPeer]) -> [DeviceEntry] {
    func trim(_ value: String) -> String { value.trimmingCharacters(in: .whitespacesAndNewlines) }
    func same(_ peer: HostPeer, _ connection: AhnaConnection) -> Bool { sameDevice(peer, connection) }
    var claimed = Set<String>()
    var result: [DeviceEntry] = []
    for connection in connections {
        let matched = peers.filter { same($0, connection) }
        for peer in matched { claimed.insert(peer.id) }
        let live = matched.first { $0.online }?.id
        result.append(DeviceEntry(id: "client:" + connection.id.uuidString, name: connection.hostName, isOnline: connection.state != nil || live != nil,
                                  connection: connection, peerIDs: matched.map { $0.id }, livePeer: live))
    }
    struct PeerGroup { let key: String; let name: String; var members: [HostPeer] }
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
        let live = group.members.first { $0.online }
        let ids = group.members.map { $0.id }.sorted()
        result.append(DeviceEntry(id: "host:" + ids[0], name: (live ?? group.members[0]).name, isOnline: live != nil,
                                  connection: nil, peerIDs: ids, livePeer: live?.id))
    }
    return result
}

// MARK: - 주고받기

struct SendReceiveScreen: View {
    @ObservedObject var client: AhnaClient
    @ObservedObject var host: MobileHostModel
    @ObservedObject var nearby: NearbyCenter
    @ObservedObject private var history = ReceiveHistory.shared
    @State private var showingQR = false
    @State private var nearbySummary = ""

    @State private var target = ""
    @State private var draft = ""
    @State private var notice = ""
    @State private var clipNotice = ""
    @State private var fileNotice = ""
    @State private var clipPreview: [String: String] = [:]
    // 보낼 파일 목록
    @State private var pending: [PendingFile] = []
    @State private var scoped: [URL] = []
    @State private var tempFolders: [URL] = []
    @State private var importing = false
    @State private var choosingPhotos = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var loadingPhotos = false
    @State private var sendingToClient = false
    @State private var sendingToHost = false

    /// 보낼 기기: 추가한 기기는 늘, 이 기기에만 연결한 기기는 지금 받을 수 있을 때만 보입니다(기기마다 한 줄).
    private var targets: [DeviceEntry] {
        mergedDevices(client.connections, host.peers).filter { $0.connection != nil || $0.isOnline }
    }
    /// 근처 기기(Bluetooth). 등록한 기기와 이름이 같으면 숨깁니다.
    private var nearbyDevices: [NearbyDevice] {
        guard nearby.available else { return [] }
        let names = Set(targets.map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines) })
        return nearby.devices.filter { !names.contains($0.name.trimmingCharacters(in: .whitespacesAndNewlines)) }
    }
    /// 근처 기기를 골랐으면 그 기기(목록에서 사라지면 nil → 등록한 기기로 돌아감)
    private var nearbyTarget: NearbyDevice? {
        guard target.hasPrefix("near:") else { return nil }
        return nearbyDevices.first { "near:" + $0.id.uuidString == target }
    }
    private var pendingSummary: String {
        pending.isEmpty ? "" : NearbyCenter.summary(pending.map { URL(fileURLWithPath: $0.path).lastPathComponent }) + " · " + AhnaText.bytes(pendingTotal)
    }
    /// 고른 기기가 없거나 사라졌으면 첫 온라인 기기를 씁니다. 근처 기기를 골랐으면 nil.
    private var currentTarget: DeviceEntry? {
        if nearbyTarget != nil { return nil }
        let all = targets
        return all.first { $0.id == target } ?? all.first { $0.isOnline } ?? all.first
    }
    private var transferring: Bool { sendingToClient || sendingToHost }

    var body: some View {
        // 크기 등급(size class)이 아니라 실제 너비로 고릅니다. iPad 세로도 regular라 3열이 되어 칸이 좁았습니다.
        GeometryReader { proxy in
            page(columns: AhnaLayout.columns(forWidth: proxy.size.width))
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            importFiles(result)
        }
        .photosPicker(isPresented: $choosingPhotos, selection: $photoItems, maxSelectionCount: 100, matching: .any(of: [.images, .videos]), preferredItemEncoding: client.photosAsJPG ? .compatible : .current)
        .onChange(of: photoItems) { _, items in if !items.isEmpty { loadPhotos(items) } }
        .sheet(isPresented: Binding(get: { nearby.outgoing != nil }, set: { if !$0 { nearby.closeOutgoing() } })) {
            NearbySendSheet(center: nearby, summary: nearbySummary)
        }
        .sheet(isPresented: $showingQR) {
            QrShareSheet(host: host, center: nearby, files: pending, summary: pendingSummary, onSent: { clearPending() }, mode: pending.isEmpty ? .receive : .send)
        }
        .onChange(of: client.busy) { _, busy in
            // 전송이 끝나면(성공·실패 모두) 상태 문구를 보여 줍니다. 성공 시 목록은 완료 콜백에서 비웁니다.
            if !busy && sendingToClient {
                sendingToClient = false
                fileNotice = client.selected?.progress ?? ""
            }
        }
    }

    /// columns: 1 = 휴대폰 배치, 2 = 2열(iPad 세로), 3 = 3열(iPad 가로). 2열·3열은 태블릿 머리글과 크기를 씁니다.
    @MainActor private func page(columns: Int) -> some View {
        let regular = columns >= 2
        return AhnaPage(header: ScreenHeader(title: "아나", showsLogo: true, showsVersion: true, nasStatus: nasHeaderStatus(host: host, client: client), regular: regular,
                                                 detail: "이 기기 · \(client.deviceName) · 코드 \(AhnaText.spacedCode(host.pin))")) {
            if columns >= 3 {
                HStack(alignment: .top, spacing: 16) {
                    VStack(spacing: 16) { targetCard; fileCard(regular: true) }.frame(maxWidth: .infinity, alignment: .top)
                    VStack(spacing: 16) { textCard(regular: true); clipsCard }.frame(maxWidth: .infinity, alignment: .top)
                    VStack(spacing: 16) { filesCard(regular: true) }.frame(maxWidth: .infinity, alignment: .top)
                }
                .padding(.horizontal, 24).padding(.top, 4).padding(.bottom, 24)
            } else if columns == 2 {
                // 왼쪽: 보낼 기기 · 파일 보내기 · 글자 보내기 / 오른쪽: 받은 글자 · 받은 파일
                HStack(alignment: .top, spacing: 16) {
                    VStack(spacing: 16) { targetCard; fileCard(regular: true); textCard(regular: true) }.frame(maxWidth: .infinity, alignment: .top)
                    VStack(spacing: 16) { clipsCard; filesCard(regular: true) }.frame(maxWidth: .infinity, alignment: .top)
                }
                .padding(.horizontal, 24).padding(.top, 4).padding(.bottom, 24)
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    targetChips
                    fileCard(regular: false)
                    textCard(regular: false)
                    clipsCard
                    filesCard(regular: false)
                }
                .padding(16).padding(.bottom, 16)
            }
        }
    }

    // MARK: 보낼 기기

    /// 휴대폰 배치: Bluetooth를 쓸 수 있으면 '내 기기' + '근처 기기' 카드(NearbyPhone), 아니면 예전 칩 줄
    @ViewBuilder private var targetChips: some View {
        if nearby.available {
            VStack(alignment: .leading, spacing: 10) {
                Text("내 기기").font(.system(size: 13, weight: .medium)).foregroundStyle(AhnaPalette.muted).accessibilityAddTraits(.isHeader)
                chipRow
                AhnaDivider().padding(.top, 4)
                NearbyTargetSection(devices: nearbyDevices, selectedID: target) { target = "near:" + $0.id.uuidString }
            }
            .ahnaCard(horizontal: 16, vertical: 14)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("보낼 기기").font(.system(size: 13, weight: .medium)).foregroundStyle(AhnaPalette.muted).accessibilityAddTraits(.isHeader)
                chipRow
            }
        }
    }

    @ViewBuilder private var chipRow: some View {
        if targets.isEmpty {
            noTargetText
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(targets) { t in chip(t, selected: t.id == currentTarget?.id) }
                }
                .padding(.vertical, 1)
            }
        }
    }

    private var noTargetText: some View {
        Text("아직 추가한 기기가 없습니다. 옵션 탭의 ‘기기 추가’에서 상대 기기의 코드를 입력하세요.")
            .font(.system(size: 13)).foregroundStyle(AhnaPalette.faint)
    }

    private func chip(_ t: DeviceEntry, selected: Bool) -> some View {
        Button { target = t.id } label: {
            HStack(spacing: 8) {
                Image(systemName: AhnaText.deviceSymbol(t.name)).font(.system(size: 16))
                Text(t.name).font(.system(size: 14, weight: selected ? .medium : .regular)).lineLimit(1)
                StatusDot(isOnline: t.isOnline)
            }
            .foregroundStyle(t.isOnline ? AhnaPalette.text : AhnaPalette.muted)
            .padding(.horizontal, 14)
            .frame(height: 48)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(selected ? AhnaPalette.accentSoft : AhnaPalette.surface))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(selected ? AhnaPalette.accent : AhnaPalette.border, lineWidth: selected ? 2 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(t.name), \(t.isOnline ? "연결됨" : "오프라인")")
        .accessibilityAddTraits(selected ? AccessibilityTraits.isSelected : AccessibilityTraits())
    }

    /// 2열·3열: 세로 목록 카드
    private var targetCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            CardTitle("보낼 기기").padding(.bottom, 4)
            if targets.isEmpty { noTargetText }
            ForEach(targets) { t in
                let selected = t.id == currentTarget?.id
                Button { target = t.id } label: {
                    HStack(spacing: 12) {
                        Image(systemName: AhnaText.deviceSymbol(t.name)).font(.system(size: 17))
                            .foregroundStyle(t.isOnline ? AhnaPalette.text : AhnaPalette.muted)
                        Text(t.name).font(.system(size: 14, weight: .medium)).lineLimit(1)
                            .foregroundStyle(t.isOnline ? AhnaPalette.text : AhnaPalette.muted)
                        Spacer(minLength: 4)
                        DeviceStateLabel(isOnline: t.isOnline)
                    }
                    .padding(.horizontal, 12)
                    .frame(minHeight: 56)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(selected ? AhnaPalette.accentSoft : AhnaPalette.surface))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(selected ? AhnaPalette.accent : AhnaPalette.border, lineWidth: selected ? 2 : 1))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(t.name), \(t.isOnline ? "연결됨" : "오프라인")")
                .accessibilityAddTraits(selected ? AccessibilityTraits.isSelected : AccessibilityTraits())
            }
            if nearby.available {
                AhnaDivider().padding(.vertical, 6)
                NearbyTargetSection(devices: nearbyDevices, selectedID: target) { target = "near:" + $0.id.uuidString }
            }
        }
        .ahnaCard()
    }

    // MARK: 파일 보내기

    private func fileCard(regular: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                CardTitle("파일 보내기")
                Spacer()
                // QR로 보내기 / 받기 (앱이 없는 상대와 서버를 거쳐 주고받기)
                Button { showingQR = true } label: {
                    Label("QR", systemImage: "qrcode").font(.system(size: 13, weight: .bold))
                }
                .buttonStyle(AhnaButtonStyle(kind: .soft, height: 34, fullWidth: false))
                .disabled(loadingPhotos)
                .accessibilityLabel("QR로 보내기 또는 받기")
            }
            Menu {
                Button { choosingPhotos = true } label: { Label("사진 보관함", systemImage: "photo.on.rectangle") }
                Button { importing = true } label: { Label("파일 앱", systemImage: "folder") }
            } label: {
                VStack(spacing: 6) {
                    ZStack {
                        Circle().fill(AhnaPalette.accentSoft)
                        if loadingPhotos {
                            ProgressView().tint(AhnaPalette.accent)
                        } else {
                            Image(systemName: "arrow.up").font(.system(size: 20, weight: .semibold)).foregroundStyle(AhnaPalette.accent)
                        }
                    }
                    .frame(width: regular ? 48 : 44, height: regular ? 48 : 44)
                    Text(loadingPhotos ? "사진 가져오는 중…" : "파일 선택").font(.system(size: 14, weight: .medium)).foregroundStyle(AhnaPalette.text)
                    Text("사진 · 문서 · 동영상 / 파일당 최대 4 GiB").font(.system(size: 12)).foregroundStyle(AhnaPalette.faint)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, regular ? 28 : 22)
                .padding(.horizontal, 12)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(AhnaPalette.subtle))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(AhnaPalette.borderStrong, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
                .contentShape(Rectangle())
            }
            .disabled(loadingPhotos || transferring)
            .accessibilityLabel("파일 선택")

            if !pending.isEmpty {
                VStack(spacing: 0) {
                    let shown = Array(pending.prefix(20))
                    ForEach(Array(shown.enumerated()), id: \.element.id) { index, file in
                        HStack(spacing: 10) {
                            Image(systemName: AhnaText.fileSymbol(file.path)).font(.system(size: 15))
                                .foregroundStyle(AhnaPalette.accent)
                                .frame(width: 34, height: 34)
                                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(AhnaPalette.accentSoft))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(file.path).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.middle)
                                Text(AhnaText.bytes(file.bytes)).font(.system(size: 12)).foregroundStyle(AhnaPalette.faint)
                            }
                            Spacer(minLength: 4)
                            Button { removePending(file) } label: {
                                Image(systemName: "xmark").font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(AhnaPalette.muted)
                                    .frame(width: 44, height: 44).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain).disabled(transferring)
                            .accessibilityLabel("\(file.path) 목록에서 빼기")
                        }
                        .padding(.vertical, 4)
                        if index < shown.count - 1 || pending.count > shown.count { AhnaDivider() }
                    }
                    if pending.count > shown.count {
                        Text("외 \(pending.count - shown.count)개 · 모두 \(AhnaText.bytes(pendingTotal))")
                            .font(.system(size: 12)).foregroundStyle(AhnaPalette.faint)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                    }
                }
            }

            if transferring {
                HStack(spacing: 10) {
                    ProgressView().tint(AhnaPalette.accent)
                    Text(sendingToClient ? (client.selected?.progress ?? "") : "전송 준비 중…")
                        .font(.system(size: 12)).foregroundStyle(AhnaPalette.muted).lineLimit(2)
                    Spacer(minLength: 4)
                    if sendingToClient {
                        Button("전송 중단") { client.cancel() }
                            .buttonStyle(AhnaButtonStyle(kind: .secondary, height: 36, fullWidth: false))
                    }
                }
            }

            if let near = nearbyTarget {
                Button(near.name + "에 보내기" + (pending.isEmpty ? "" : " · \(pending.count)개")) { sendNearby(near) }
                    .buttonStyle(NearbyButtonStyle(height: 50))
                    .disabled(pending.isEmpty || transferring || loadingPhotos || nearby.outgoing != nil || !host.guestReady)
                Text(host.guestReady ? "등록하지 않은 기기라 상대가 [받기]를 눌러야 전송됩니다"
                                     : "서버 설정이 필요합니다 · 옵션 › 서버에서 ‘이 기기가 서버로 받기’를 연결하면 근처 기기로 보낼 수 있습니다")
                    .font(.system(size: 12)).foregroundStyle(AhnaPalette.faint)
                    .frame(maxWidth: .infinity).multilineTextAlignment(.center)
            } else {
                Button(sendFilesLabel) { sendFiles() }
                    .buttonStyle(AhnaButtonStyle(kind: .primary, height: 50))
                    .disabled(pending.isEmpty || currentTarget == nil || transferring || loadingPhotos || client.busy)
            }

            if !fileNotice.isEmpty {
                Text(fileNotice).font(.system(size: 12)).foregroundStyle(AhnaPalette.faint)
            }
        }
        .ahnaCard()
    }

    private var pendingTotal: Int64 { pending.reduce(Int64(0)) { $0 + $1.bytes } }

    private var sendFilesLabel: String {
        guard let t = currentTarget else { return "보낼 기기를 먼저 추가하세요" }
        return AhnaText.toward(t.name) + (pending.isEmpty ? " 보내기" : " \(pending.count)개 보내기")
    }

    private func importFiles(_ result: Result<[URL], Error>) {
        do {
            let urls = try result.get()
            var accessed: [URL] = []
            for url in urls { if url.startAccessingSecurityScopedResource() { accessed.append(url) } }
            do {
                let files = try FilePreparation.collect(urls)
                scoped += accessed
                pending += files
                fileNotice = ""
            } catch {
                for url in accessed { url.stopAccessingSecurityScopedResource() }
                throw error
            }
        } catch { fileNotice = error.localizedDescription }
    }

    private func loadPhotos(_ items: [PhotosPickerItem]) {
        photoItems = []
        loadingPhotos = true
        Task { @MainActor in
            defer { loadingPhotos = false }
            do {
                var urls: [URL] = []
                for item in items {
                    guard let picked = try await item.loadTransferable(type: PickedMediaFile.self) else { continue }
                    tempFolders.append(picked.url.deletingLastPathComponent())
                    urls.append(client.photosAsJPG ? PhotoJPEG.convertIfNeeded(picked.url) : picked.url)
                }
                guard !urls.isEmpty else { throw AhnaError.message("고른 사진을 가져올 수 없습니다.") }
                pending += try FilePreparation.collect(urls)
                fileNotice = ""
            } catch { fileNotice = error.localizedDescription }
        }
    }

    private func removePending(_ file: PendingFile) {
        pending.removeAll { $0.id == file.id }
        if pending.isEmpty { clearPending() }
    }

    private func clearPending() {
        pending = []
        for url in scoped { url.stopAccessingSecurityScopedResource() }
        scoped = []
        for folder in tempFolders { try? FileManager.default.removeItem(at: folder) }
        tempFolders = []
    }

    /// 근처 기기로 보내기: 내 서버에 1회용 링크를 만들고 Bluetooth로 상대에게 알립니다. 상대가 다 받으면 목록을 비웁니다.
    private func sendNearby(_ device: NearbyDevice) {
        guard !pending.isEmpty else { return }
        guard host.guestReady else { fileNotice = "서버 설정이 필요합니다."; return }
        nearbySummary = pendingSummary
        fileNotice = ""
        nearby.send(to: device, files: pending) { clearPending() }
    }

    private func sendFiles() {
        guard let t = currentTarget, !pending.isEmpty else { return }
        let files = pending
        if !t.sendsThroughHost, let connection = t.connection {
            client.selectedID = connection.id
            let started = client.send(files) { clearPending() }
            if started { sendingToClient = true; fileNotice = "" }
            else { fileNotice = "\(t.name)의 연결 상태를 확인한 뒤 다시 보내 주세요." }
        } else if let peer = t.livePeer ?? t.peerIDs.first {
            sendingToHost = true
            fileNotice = ""
            host.send(files, target: peer) {
                sendingToHost = false
                fileNotice = host.status
                // 전송 대기열에 복사됐으면 원본 목록을 비웁니다.
                if host.status.contains("전송 준비 완료") { clearPending() }
            }
        } else {
            fileNotice = "받을 기기를 선택하세요."
        }
    }

    // MARK: 글자 보내기

    private func textCard(regular: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                CardTitle("글자 보내기")
                Spacer()
                PasteButton(payloadType: String.self) { draft = $0.joined(separator: "\n") }
                    .labelStyle(.titleAndIcon)
                    .buttonBorderShape(.roundedRectangle(radius: 10))
                    .controlSize(.small)
                    .tint(AhnaPalette.accent)
            }
            ZStack(alignment: .topLeading) {
                TextEditor(text: $draft)
                    .font(.system(size: 14))
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 8).padding(.vertical, 6)
                    .frame(height: regular ? 120 : 96)
                    .accessibilityLabel("보낼 글자")
                if draft.isEmpty {
                    Text("보낼 글자를 입력하거나 붙여넣으세요")
                        .font(.system(size: 14)).foregroundStyle(AhnaPalette.faint)
                        .padding(.horizontal, 13).padding(.vertical, 14)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .ahnaField()
            Button("글자 보내기") { sendText() }
                .buttonStyle(AhnaButtonStyle(kind: .outline, height: 46))
                .disabled(draft.isEmpty || currentTarget == nil || client.busy)
            if !notice.isEmpty { Text(notice).font(.system(size: 12)).foregroundStyle(AhnaPalette.faint) }
        }
        .ahnaCard()
    }

    private func sendText() {
        guard let t = currentTarget else { notice = "받을 기기를 선택하세요."; return }
        let text = draft
        Task { @MainActor in
            do {
                if !t.sendsThroughHost, let c = t.connection { try await c.sendClipboard(text) }
                else if let peer = t.livePeer ?? t.peerIDs.first { host.engine?.sendText(text, target: peer) }
                else { throw AhnaError.message("받을 기기를 선택하세요.") }
                notice = "글자를 보냈습니다. 받은 기기에서 복사하세요."
            } catch { notice = error.localizedDescription }
        }
    }

    // MARK: 받은 글자

    private struct ClipItem: Identifiable {
        let id: String
        let meta: String
        let preview: String?
        let connection: AhnaConnection?
        let clip: InboxClipboard?
        let text: String?
    }

    private var clipItems: [ClipItem] {
        var items: [ClipItem] = []
        for c in client.connections {
            for clip in c.state?.clipboard ?? [] {
                items.append(ClipItem(id: c.id.uuidString + "/" + clip.id, meta: clip.sender == c.hostName ? clip.sender : "\(clip.sender) · \(c.hostName)",
                                      preview: clipPreview[clip.id], connection: c, clip: clip, text: nil))
            }
        }
        for (index, clip) in host.clips.enumerated() {
            items.append(ClipItem(id: "host/\(index)", meta: clip.0, preview: clip.1, connection: nil, clip: nil, text: clip.1))
        }
        return items
    }

    private var clipsCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            CardTitle("받은 글자").padding(.bottom, 6)
            let items = clipItems
            if items.isEmpty {
                Text("아직 받은 글자가 없습니다.").font(.system(size: 13)).foregroundStyle(AhnaPalette.faint).padding(.vertical, 6)
            }
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.meta).font(.system(size: 12)).foregroundStyle(AhnaPalette.faint).lineLimit(1)
                        Text(item.preview ?? "복사를 누르면 내용을 가져옵니다")
                            .font(.system(size: 14))
                            .foregroundStyle(item.preview == nil ? AhnaPalette.muted : AhnaPalette.text)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Button("복사") { copy(item) }
                        .buttonStyle(AhnaButtonStyle(kind: .soft, height: 36, fullWidth: false))
                        .accessibilityLabel("\(item.meta)에서 받은 글자 복사")
                }
                .padding(.vertical, 10)
                if index < items.count - 1 { AhnaDivider() }
            }
            if !clipNotice.isEmpty { Text(clipNotice).font(.system(size: 12)).foregroundStyle(AhnaPalette.faint).padding(.top, 4) }
        }
        .ahnaCard()
    }

    private func copy(_ item: ClipItem) {
        if let text = item.text { UIPasteboard.general.string = text; clipNotice = "복사했습니다."; return }
        guard let connection = item.connection, let clip = item.clip else { return }
        Task { @MainActor in
            do {
                let text = try await connection.clipboardText(clip)
                UIPasteboard.general.string = text
                clipPreview[clip.id] = text
                clipNotice = "복사했습니다."
            } catch { clipNotice = error.localizedDescription }
        }
    }

    // MARK: 받은 파일

    private func filesCard(regular: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                CardTitle("받은 파일")
                Spacer()
                Text("\(history.entries.count)/10 · 파일 앱 › 아나").font(.system(size: 12)).foregroundStyle(AhnaPalette.faint)
            }
            .padding(.bottom, 6)
            if history.entries.isEmpty {
                Text("아직 받은 파일이 없습니다.").font(.system(size: 13)).foregroundStyle(AhnaPalette.faint).padding(.vertical, 6)
            }
            ForEach(Array(history.entries.enumerated()), id: \.element.id) { index, item in
                HStack(spacing: 10) {
                    Image(systemName: AhnaText.fileSymbol(item.name)).font(.system(size: 15))
                        .foregroundStyle(AhnaPalette.muted)
                        .frame(width: regular ? 36 : 34, height: regular ? 36 : 34)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(AhnaPalette.subtle))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.name).font(.system(size: 13, weight: .medium)).lineLimit(1).truncationMode(.middle)
                        Text(fileMeta(item)).font(.system(size: 12)).foregroundStyle(AhnaPalette.faint).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    ShareLink(item: item.url) {
                        Text("열기").font(.system(size: 13)).foregroundStyle(AhnaPalette.text)
                            .padding(.horizontal, 12).frame(height: 36)
                            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(AhnaPalette.surface))
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(AhnaPalette.border, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(item.name) 열기")
                }
                .padding(.vertical, 8)
                if index < history.entries.count - 1 { AhnaDivider() }
            }
            HStack {
                Button("목록 초기화") { history.clear() }
                    .font(.system(size: 13)).foregroundStyle(AhnaPalette.muted)
                    .frame(height: 36)
                    .buttonStyle(.plain)
                    .disabled(history.entries.isEmpty)
                Spacer()
            }
            .padding(.top, 4)
            Text("최근 10개 · 오래된 기록부터 교체합니다. 목록 초기화는 저장된 파일을 지우지 않습니다.")
                .font(.system(size: 12)).foregroundStyle(AhnaPalette.faint)
        }
        .ahnaCard()
    }

    private func fileMeta(_ item: ReceiveHistory.Entry) -> String {
        var parts = [item.source, item.received.formatted(.relative(presentation: .named))]
        if let size = (try? item.url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize { parts.append(AhnaText.bytes(Int64(size))) }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

// MARK: - 옵션

struct OptionsScreen: View {
    @ObservedObject var client: AhnaClient
    @ObservedObject var host: MobileHostModel
    @ObservedObject var updater: AppUpdater
    @ObservedObject var nearby: NearbyCenter
    @State private var pairingResult = false
    @State private var editor: OptionsEditor?
    @State private var forgetting: DeviceEntry?
    @State private var confirmRevoke = false
    @State private var copiedCode = false

    enum OptionsEditor: String, Identifiable { case name, nas; var id: String { rawValue } }
    private var updateAvailable: Bool { if case .available = updater.phase { return true }; return false }

    var body: some View {
        // 주고받기 화면과 같은 기준: 실제 너비로 1열 · 2열 · 3열을 고릅니다.
        GeometryReader { proxy in
            page(columns: AhnaLayout.columns(forWidth: proxy.size.width))
        }
        .sheet(item: $editor) { which in
            switch which {
            case .name: NameEditorSheet(client: client, host: host)
            case .nas: NASEditorSheet(client: client, host: host)
            }
        }
    }

    /// columns: 1 = 휴대폰 배치, 2 = 2열(iPad 세로), 3 = 3열(iPad 가로)
    @MainActor private func page(columns: Int) -> some View {
        let regular = columns >= 2
        return AhnaPage(header: ScreenHeader(title: "옵션", showsLogo: regular, nasStatus: nasHeaderStatus(host: host, client: client), regular: regular)) {
            AhnaMeaningBanner().padding(.horizontal, regular ? 24 : 16).padding(.top, regular ? 4 : 16).padding(.bottom, regular ? 12 : 0)
            if columns >= 3 {
                HStack(alignment: .top, spacing: 16) {
                    VStack(spacing: 16) { codeCard(regular: true); addCard }.frame(maxWidth: .infinity, alignment: .top)
                    VStack(spacing: 16) { devicesCard(regular: true); NearbyOptionsCard(center: nearby) }.frame(maxWidth: .infinity, alignment: .top)
                    VStack(spacing: 16) {
                        if updateAvailable { updateCard }
                        settingsCard
                        NearbySendInfoCard()
                    }.frame(maxWidth: .infinity, alignment: .top)
                }
                .padding(.horizontal, 24).padding(.top, 4).padding(.bottom, 24)
            } else if columns == 2 {
                // 왼쪽: 연결 코드 · 기기 추가 · 연결된 기기 / 오른쪽: (새 버전 안내) · 근처 기기에서 받기 · 보낼 때 · 설정
                HStack(alignment: .top, spacing: 16) {
                    VStack(spacing: 16) { codeCard(regular: true); addCard; devicesCard(regular: true) }.frame(maxWidth: .infinity, alignment: .top)
                    VStack(spacing: 16) {
                        if updateAvailable { updateCard }
                        NearbyOptionsCard(center: nearby)
                        NearbySendInfoCard()
                        settingsCard
                    }.frame(maxWidth: .infinity, alignment: .top)
                }
                .padding(.horizontal, 24).padding(.top, 4).padding(.bottom, 24)
            } else {
                VStack(spacing: 14) {
                    if updateAvailable { updateCard }
                    codeCard(regular: false)
                    devicesCard(regular: false)
                    addCard
                    NearbyOptionsCard(center: nearby)
                    NearbySendInfoCard()
                    settingsCard
                }
                .padding(16).padding(.bottom, 16)
            }
        }
    }

    private var updateCard: some View {
        UpdateBanner(updater: updater).ahnaCard()
    }

    // MARK: 연결 코드

    private func codeCard(regular: Bool) -> some View {
        VStack(alignment: .leading, spacing: regular ? 8 : 6) {
            Text("이 기기의 연결 코드").font(.system(size: 13, weight: .medium)).opacity(0.9)
            HStack(spacing: 10) {
                Text(AhnaText.spacedCode(host.pin))
                    .font(.system(size: regular ? 40 : 36, weight: .bold).monospacedDigit())
                    .kerning(6)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .textSelection(.enabled)
                    .accessibilityLabel("연결 코드 " + host.pin.map { String($0) }.joined(separator: " "))
                Spacer(minLength: 4)
                Button {
                    UIPasteboard.general.string = host.pin
                    copiedCode = true
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        copiedCode = false
                    }
                } label: {
                    Image(systemName: copiedCode ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 17, weight: .medium))
                        .frame(width: 44, height: 44)
                        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(AhnaPalette.onAccentLine, lineWidth: 1))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(host.pin.isEmpty)
                .accessibilityLabel(copiedCode ? "코드를 복사했습니다" : "코드 복사")
            }
            Text("다른 기기의 아나에서 **기기 추가**를 누르고 이 코드를 입력하세요. 받는 동안 앱을 열어 두세요.")
                .font(.system(size: 12)).opacity(0.9)
        }
        .foregroundStyle(AhnaPalette.onAccent)
        .padding(regular ? 20 : 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(AhnaPalette.accent))
    }

    // MARK: 연결된 기기

    private func devicesCard(regular: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            CardTitle("연결된 기기").padding(.top, 10).padding(.bottom, 4)
            let devices = mergedDevices(client.connections, host.peers)
            if devices.isEmpty {
                Text("아직 추가한 기기가 없습니다.").font(.system(size: 13)).foregroundStyle(AhnaPalette.faint).padding(.vertical, 12)
            }
            ForEach(Array(devices.enumerated()), id: \.element.id) { index, c in
                let online = c.isOnline
                if regular || index > 0 { AhnaDivider() }
                HStack(spacing: 12) {
                    DeviceIconTile(symbol: AhnaText.deviceSymbol(c.name), isOnline: online)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(c.name).font(.system(size: 15, weight: .medium))
                            .foregroundStyle(online ? AhnaPalette.text : AhnaPalette.muted)
                            .lineLimit(1)
                        // 이름과 상태만: 오프라인이고 상대가 연결을 해제했을 때만 그 이유 한 줄.
                        DeviceStateLabel(isOnline: online, onlineText: "연결됨", offlineText: c.connection?.revoked == true ? AhnaConnection.revokedMessage : "오프라인")
                    }
                    .accessibilityElement(children: .combine)
                    Spacer(minLength: 4)
                    Button { forgetting = c } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .heavy))
                            .foregroundStyle(AhnaPalette.danger)
                            .frame(width: 26, height: 26)
                            .background(Circle().fill(AhnaPalette.dangerSoft))
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(client.busy)
                    .accessibilityLabel("\(c.name) 연결 삭제")
                }
                .padding(.vertical, 12)
            }
            if !devices.isEmpty {
                Text("꺼진 기기는 켜지고 아나가 실행되면 자동으로 다시 연결됩니다.")
                    .font(.system(size: 12)).foregroundStyle(AhnaPalette.faint).padding(.bottom, 10)
            }
        }
        .ahnaCard(horizontal: 16, vertical: 6)
        .alert("\(forgetting?.name ?? "기기") 연결을 삭제할까요?",
               isPresented: Binding(get: { forgetting != nil }, set: { if !$0 { forgetting = nil } }),
               presenting: forgetting) { c in
            // 이 기기가 추가한 연결과, 그 기기가 이 기기에 연결한 세션을 함께 지웁니다.
            Button("삭제", role: .destructive) { Task { @MainActor in if let connection = c.connection { await client.forget(connection) }; host.forget(c.peerIDs) } }
            Button("취소", role: .cancel) {}
        } message: { _ in
            Text("다시 추가할 때는 상대 기기의 연결 코드가 필요합니다.")
        }
    }

    // MARK: 기기 추가

    private var addCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            CardTitle("기기 추가")
            Text("상대 기기에 ‘서버 연결됨’이 보이는지 확인하고, 그 기기의 연결 코드를 입력하세요.")
                .font(.system(size: 12)).foregroundStyle(AhnaPalette.faint)
            Text("상대 기기의 6자리 코드").font(.system(size: 12)).foregroundStyle(AhnaPalette.muted)
            HStack(spacing: 8) {
                TextField("000000", text: $client.pin)
                    .keyboardType(.numberPad)
                    .font(.system(size: 22, weight: .medium).monospacedDigit())
                    .kerning(8)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 14)
                    .ahnaField(height: 50)
                    .disabled(client.busy)
                    .accessibilityLabel("상대 기기의 6자리 코드")
                Button("추가") { Task { await client.connect(); pairingResult = true } }
                    .buttonStyle(AhnaButtonStyle(kind: .primary, height: 50))
                    .frame(width: 88)
                    .disabled(client.busy)
            }
            Button { editor = .nas } label: {
                HStack(spacing: 4) {
                    Text("연결할 서버: " + (client.address.isEmpty ? "주소 없음" : client.address))
                        .foregroundStyle(AhnaPalette.faint).lineLimit(1).truncationMode(.middle)
                    Text("변경").foregroundStyle(AhnaPalette.accent).fontWeight(.medium)
                }
                .font(.system(size: 12))
                .frame(minHeight: 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("연결할 서버 주소 변경, 현재 \(client.address)")
            if !client.status.isEmpty {
                Text(client.status).font(.system(size: 12)).foregroundStyle(AhnaPalette.faint)
            }
        }
        .ahnaCard()
        .alert("기기 등록", isPresented: $pairingResult) { Button("확인", role: .cancel) {} } message: { Text(client.status) }
    }

    // MARK: 설정

    private var updateValue: String {
        let current = "v" + AppUpdater.currentVersion
        switch updater.phase {
        case .checking: return current + " · 확인 중…"
        case .upToDate: return current + " · 최신 버전입니다"
        case .available(let v): return current + " · 새 버전 v\(v) 있음"
        case .downloading: return current + " · 내려받는 중…"
        case .failed: return current + " · 확인하지 못했습니다"
        case .idle: return current
        }
    }

    private var nasValue: String {
        let address = host.nasAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        return address.isEmpty ? host.remoteStatus : address + " · " + host.remoteStatus
    }

    private var settingsCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            CardTitle("설정").padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 6)
            AhnaDivider()
            SettingsRow("이 기기의 이름", value: client.deviceName, action: { editor = .name }) { SettingsChevron() }
            AhnaDivider()
            SettingsRow("서버", value: nasValue, action: { editor = .nas }) { SettingsChevron() }
            AhnaDivider()
            SettingsToggleRow(title: "받은 파일 자동 저장", value: "파일 앱 → 나의 iPhone/iPad → 아나", isOn: $client.autoSave)
            AhnaDivider()
            SettingsToggleRow(title: "사진·동영상은 사진 앱에도 저장", value: "", isOn: $client.savePhotos)
            AhnaDivider()
            SettingsToggleRow(title: "사진을 JPG로 보내기", value: "HEIC 사진은 JPG, HEVC 영상은 H.264로 · 끄면 원본 그대로", isOn: $client.photosAsJPG)
            AhnaDivider()
            SettingsRow("앱 업데이트", value: updateValue, action: { Task { await updater.check(force: true) } }) {
                Text("업데이트 확인").font(.system(size: 13, weight: .medium)).foregroundStyle(AhnaPalette.accent)
            }
            .disabled(updater.phase == .checking || updater.phase == .downloading)
            if case .failed(let message) = updater.phase {
                Text(message).font(.system(size: 12)).foregroundStyle(AhnaPalette.danger)
                    .padding(.horizontal, 16).padding(.bottom, 10)
            }
            AhnaDivider()
            SettingsRow("모든 기기 해제 · 코드 새로 만들기", value: "이 기기에 연결한 모든 기기가 다시 코드를 입력해야 합니다",
                        titleColor: AhnaPalette.danger, action: { confirmRevoke = true }) { EmptyView() }
        }
        .ahnaCard(padding: 0)
        .alert("모든 기기를 해제할까요?", isPresented: $confirmRevoke) {
            Button("해제하고 새 코드 만들기", role: .destructive) { host.revoke() }
            Button("취소", role: .cancel) {}
        } message: {
            Text("이 기기에 연결한 모든 기기의 연결이 끊어지고 연결 코드가 바뀝니다. 다시 연결하려면 새 코드를 입력해야 합니다.")
        }
    }
}

struct SettingsChevron: View {
    var body: some View {
        Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(AhnaPalette.faint).accessibilityHidden(true)
    }
}

struct SettingsRow<Trailing: View>: View {
    let title: String
    let value: String
    let titleColor: Color
    let action: () -> Void
    let trailing: Trailing
    init(_ title: String, value: String, titleColor: Color = AhnaPalette.text, action: @escaping () -> Void, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.value = value
        self.titleColor = titleColor
        self.action = action
        self.trailing = trailing()
    }
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 15)).foregroundStyle(titleColor)
                    if !value.isEmpty {
                        Text(value).font(.system(size: 12)).foregroundStyle(AhnaPalette.faint).multilineTextAlignment(.leading).lineLimit(3)
                    }
                }
                Spacer(minLength: 8)
                trailing
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct SettingsToggleRow: View {
    let title: String
    let value: String
    @Binding var isOn: Bool
    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 15)).foregroundStyle(AhnaPalette.text)
                if !value.isEmpty { Text(value).font(.system(size: 12)).foregroundStyle(AhnaPalette.faint) }
            }
        }
        .tint(AhnaPalette.accent)
        .padding(.horizontal, 16).padding(.vertical, 8)
        .frame(minHeight: 60)
    }
}

// MARK: - 설정 편집 시트

struct NameEditorSheet: View {
    @ObservedObject var client: AhnaClient
    @ObservedObject var host: MobileHostModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("예: 내 아이폰, 거실 아이패드", text: $client.deviceName)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .disabled(client.busy)
                } footer: {
                    Text(client.deviceNameStatus.isEmpty ? "다른 기기에서 받을 기기를 고를 때 표시되는 이름입니다." : client.deviceNameStatus)
                }
            }
            .scrollContentBackground(.hidden)
            .background(AhnaPalette.bg.ignoresSafeArea())
            .navigationTitle("이 기기의 이름")
            .keyboardDoneButton()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("닫기") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("저장") { Task { await client.saveDeviceName(); host.engine?.setDisplayName(client.deviceName) } }
                        .disabled(client.busy)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .tint(AhnaPalette.accent)
    }
}

/// 옵션 맨 위: 이름 풀이
struct AhnaMeaningBanner: View {
    var body: some View {
        HStack(spacing: 12) {
            AhnaLogoTile(size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text("아나").font(.system(size: 17, weight: .heavy))
                Text("경상도 말로 \"옛다, 받아라\"").font(.system(size: 13)).foregroundStyle(AhnaPalette.muted)
                Text("— 툭 건네듯 주고받으세요").font(.system(size: 13)).foregroundStyle(AhnaPalette.muted)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(AhnaPalette.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(AhnaPalette.border, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}

/// 아나 첫 실행: 초대 코드 입력 → 서버 가입.
struct JoinScreen: View {
    @ObservedObject var host: MobileHostModel
    @State private var code = ""
    @FocusState private var focused: Bool
    var body: some View {
        VStack(spacing: 22) {
            Spacer()
            AhnaLogoTile(size: 84)
            VStack(spacing: 8) {
                Text(Brand.name).font(.system(size: 34, weight: .heavy)).kerning(-0.8)
                Text("받은 초대 코드를 입력하면 바로 시작합니다").font(.system(size: 15)).foregroundStyle(AhnaPalette.muted)
            }
            TextField("초대 코드", text: $code)
                .font(.system(size: 20, weight: .semibold)).multilineTextAlignment(.center)
                .textInputAutocapitalization(.characters).autocorrectionDisabled().focused($focused)
                .padding(.vertical, 14).background(AhnaPalette.surface, in: RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(AhnaPalette.border))
                .submitLabel(.join).onSubmit { Task { await host.join(invite: code) } }
            Button { hideKeyboard(); Task { await host.join(invite: code) } } label: {
                HStack { if host.joining { ProgressView().tint(AhnaPalette.onAccent) }; Text(host.joining ? "연결 중…" : "시작하기").fontWeight(.bold) }
                    .frame(maxWidth: .infinity).padding(.vertical, 15)
            }
            .foregroundStyle(AhnaPalette.onAccent).background(AhnaPalette.accent, in: RoundedRectangle(cornerRadius: 14))
            .disabled(host.joining || code.trimmingCharacters(in: .whitespaces).isEmpty)
            if !host.remoteStatus.isEmpty && host.remoteStatus != "서버 설정이 필요합니다." {
                Text(host.remoteStatus).font(.footnote).foregroundStyle(AhnaPalette.danger).multilineTextAlignment(.center)
            }
            Spacer(); Spacer()
        }
        .padding(.horizontal, 28).frame(maxWidth: 440)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AhnaPalette.bg.ignoresSafeArea())
        .contentShape(Rectangle()).onTapGesture { hideKeyboard() }
        .onAppear { focused = true }
        .interactiveDismissDisabled()
    }
}

struct NASEditorSheet: View {
    @ObservedObject var client: AhnaClient
    @ObservedObject var host: MobileHostModel
    @State private var invite = ""
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 8) {
                        StatusDot(isOnline: host.remoteStatus.contains("연결됨"))
                        Text(host.remoteStatus).font(.footnote)
                    }
                    if Brand.ahna {
                        TextField("새 초대 코드 · 다시 연결할 때만", text: $invite)
                            .textInputAutocapitalization(.characters).autocorrectionDisabled()
                        Button(host.joining ? "연결 중…" : "다시 연결") { Task { await host.join(invite: invite); invite = "" } }
                            .disabled(host.joining || invite.trimmingCharacters(in: .whitespaces).isEmpty)
                    } else {
                    TextField("서버 HTTPS 주소", text: $host.nasAddress)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("연결 키 · 처음 한 번 또는 변경할 때", text: $host.nasKey)
                    Button("저장") { host.configureNAS() }
                    }
                } header: {
                    Text(Brand.ahna ? "서버" : "이 기기가 서버로 받기")
                } footer: {
                    Text(Brand.ahna ? "앱이 열려 있는 동안 자동으로 서버에 연결됩니다." : "저장하면 앱이 열려 있는 동안 자동으로 서버에 연결됩니다.")
                }
                if !Brand.ahna {
                Section {
                    TextField("서버 HTTPS 주소", text: $client.address)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                        .disabled(client.busy)
                } header: {
                    Text("기기 추가에 쓰는 서버 주소")
                } footer: {
                    Text("다른 기기의 연결 코드로 기기를 추가할 때 이 주소로 연결합니다.")
                }
                }
            }
            .scrollContentBackground(.hidden)
            .background(AhnaPalette.bg.ignoresSafeArea())
            .navigationTitle("서버")
            .keyboardDoneButton()
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("닫기") { dismiss() } }
            }
        }
        .presentationDetents([.large])
        .tint(AhnaPalette.accent)
    }
}
