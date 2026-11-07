import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers

@MainActor final class BackgroundSession: ObservableObject {
    static let shared = BackgroundSession()
    let client = AhnaClient(receive: true, deferStorage: true)
    private var receiver: BackgroundPolling?
    private var mainWindow: NSWindow?
    private var optionsWindow: NSWindow?
    private var identity: AnyCancellable?
    func start() {
        guard receiver == nil else { return }
        // 이 Mac 수신 쪽의 ID를 연결·상태 확인 때 함께 보내, 상대 기기가 이 Mac을 한 번만 보여 주게 합니다.
        identity = MacReceiverModel.shared.$computerID.sink { [weak self] value in self?.client.hostIdentity = value }
        // 한 번의 코드 입력으로 양쪽 연결: 이 Mac이 추가할 때 이 Mac 쪽 연결을 함께 보내고, 다른 기기가 이 Mac과 연결하며
        // 넘겨준 그 기기 쪽 연결은 추가한 기기로 저장합니다(공유 메뉴도 같은 저장소를 읽습니다).
        let receiverModel = MacReceiverModel.shared, client = self.client
        client.reverseOffer = { await receiverModel.reverseOffer() }
        client.reverseComplete = { token, accepted, name, computerID in receiverModel.reverseComplete(token: token, accepted: accepted, name: name, computerID: computerID) }
        // 상대가 이 Mac의 연결을 해제했을 때 그 기기가 이 Mac에 연결한 쪽이 남아 있으면 죽은 연결만 지웁니다.
        client.inboundExists = { connection in receiverModel.peers.contains { MacSendTarget.same($0, connection) } }
        receiverModel.reverseReceived = { credential in client.addReverse(credential) }
        receiver = BackgroundPolling(client: client); receiver?.start()
        Task { await client.restoreConfiguration(); MacReceiverModel.shared.start() }
    }
    func showMain() {
        if mainWindow == nil {
            let host = NSHostingController(rootView: MacMainWindow(client: client).frame(minWidth: 1000, minHeight: 680))
            let window = NSWindow(contentViewController: host)
            window.title = "아나"; window.setContentSize(NSSize(width: 1100, height: 720))
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            // 제목 막대를 맨 위 막대(surface 색)와 이어 보이게 합니다. 창 제목은 Mission Control·윈도우 메뉴용으로 유지.
            window.titlebarAppearsTransparent = true; window.titleVisibility = .hidden
            window.backgroundColor = MacTheme.windowBackground
            window.isReleasedWhenClosed = false; window.center(); mainWindow = window
        }
        mainWindow?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func showOptions() {
        if optionsWindow == nil {
            let host = NSHostingController(rootView: ReceiveOptions(client: client).padding(24).frame(width: 570))
            let window = NSWindow(contentViewController: host)
            window.title = "아나 수신 옵션"; window.isReleasedWhenClosed = false
            window.styleMask = [.titled, .closable]; window.center(); optionsWindow = window
        }
        optionsWindow?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func stop() { MacReceiverModel.shared.stop(); receiver?.stop(); receiver = nil; client.cancel() }
}

final class MacDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        BackgroundSession.shared.start()
        // 시작 시, 그리고 6시간마다 GitHub 릴리스 확인. 새 버전이 있으면 메인 창 위쪽 배너와 옵션 패널에 설치 버튼이 나타납니다.
        Task { @MainActor in
            while true {
                await AppUpdater.shared.check(force: true)
                if case .available = AppUpdater.shared.phase { BackgroundSession.shared.showMain() }
                try? await Task.sleep(nanoseconds: 6 * 3600 * 1_000_000_000)
            }
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) { BackgroundSession.shared.stop() }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        BackgroundSession.shared.showMain(); return false
    }
}
@main struct AhnaMacApp: App {
    @NSApplicationDelegateAdaptor(MacDelegate.self) private var delegate
    var body: some Scene {
        MenuBarExtra("아나", systemImage: "paperplane.fill") {
            AhnaStatusMenu(client: BackgroundSession.shared.client)
        }.menuBarExtraStyle(.menu)
    }
}
struct AhnaStatusMenu: View {
    @ObservedObject var client: AhnaClient
    var body: some View {
        Text("아나 · 백그라운드 수신 중")
        Text("연결된 기기: \(client.connections.filter { $0.state != nil }.count) / \(client.connections.count)")
        if !client.progress.isEmpty { Text(client.progress).lineLimit(3) }
        Divider()
        Button("컴퓨터 추가 / 아나 열기…") { BackgroundSession.shared.showMain() }
        Button("옵션 / 수신 저장 폴더…") { BackgroundSession.shared.showOptions() }
        Button("수신 폴더 열기") { NSWorkspace.shared.open(ReceiveFolder.currentURL()) }
        Button("업데이트 확인…") { Task { await AppUpdater.shared.check(force: true); BackgroundSession.shared.showMain() } }
        Toggle("받은 파일 자동 저장", isOn: $client.autoSave)
        Divider()
        Text("창을 닫아도 수신이 계속됩니다.")
        Button("아나 종료") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}
struct ReceiveOptions: View {
    @ObservedObject var client: AhnaClient
    @AppStorage(ReceiveFolder.preferenceKey) private var folderPath = ""
    @State private var error = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("수신 파일 저장 옵션").font(.title2.bold())
            Toggle("받은 파일 자동 저장", isOn: $client.autoSave)
            Text("저장 폴더").font(.headline)
            Text(ReceiveFolder.currentURL().path).textSelection(.enabled).foregroundStyle(.secondary).lineLimit(3)
            HStack {
                Button("폴더 선택…") { choose() }.disabled(client.busy)
                Button("Finder에서 열기") { NSWorkspace.shared.open(ReceiveFolder.currentURL()) }
            }
            Text("변경 후 수신하는 파일부터 선택한 폴더에 저장합니다. 기존 파일은 이동하지 않습니다. 외장 드라이브나 공유 폴더를 선택하면 연결된 동안 사용할 수 있습니다.").font(.callout).foregroundStyle(.secondary)
            if client.busy { Text("전송이 끝난 뒤 저장 폴더를 변경할 수 있습니다.").foregroundStyle(.secondary) }
            if !error.isEmpty { Text(error).foregroundStyle(.red).textSelection(.enabled) }
        }.id(folderPath)
    }
    private func choose() {
        if let message = Self.pickFolder(client: client) { error = message }
        else { error = ""; folderPath = UserDefaults.standard.string(forKey: ReceiveFolder.preferenceKey) ?? folderPath }
    }
    /// 저장 폴더 선택 창을 띄웁니다. 성공·취소는 nil, 실패하면 안내 문구를 돌려줍니다. (메인 창 옵션 패널도 사용)
    @MainActor static func pickFolder(client: AhnaClient) -> String? {
        let panel = NSOpenPanel()
        panel.title = "아나 수신 파일 저장 폴더"
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = false; panel.canCreateDirectories = true
        panel.directoryURL = ReceiveFolder.currentURL()
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        guard !client.busy else { return "전송이 끝난 뒤 다시 선택해 주세요." }
        do { try ReceiveFolder.choose(url); MacReceiverModel.shared.refreshFolder(); return nil }
        catch { return error.localizedDescription }
    }
}
