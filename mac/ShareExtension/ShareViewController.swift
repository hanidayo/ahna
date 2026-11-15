import AppKit
import SwiftUI
import UniformTypeIdentifiers

@objc(AhnaMacShareViewController)
final class ShareViewController: NSViewController {
    private var hosting: NSHostingController<DirectShareScreen>?
    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 560))
        preferredContentSize = NSSize(width: 480, height: 560)
    }
    override func viewDidAppear() {
        super.viewDidAppear()
        guard hosting == nil else { return }
        ComputerVault.beginShareOperation()
        let host = NSHostingController(rootView: DirectShareScreen(context: extensionContext))
        addChild(host); host.view.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(host.view)
        NSLayoutConstraint.activate([host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),host.view.topAnchor.constraint(equalTo: view.topAnchor),host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)])
        hosting = host
    }
}

/// 공유한 항목이 웹 주소·글자뿐이면 그 글자를 꺼냅니다(여러 개면 줄을 바꿔 이어 붙임). 파일이 하나라도 섞이면 nil.
/// 사파리 등에서 공유한 주소를 파일(txt)이 아니라 상대 기기의 클립보드 글자로 보내기 위해 씁니다.
enum SharedText {
    static func extract(_ providers: [NSItemProvider]) async -> String? {
        guard !providers.isEmpty, providers.count <= 16 else { return nil }
        var parts: [String] = []
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) { return nil }
            let types = provider.registeredTypeIdentifiers.compactMap { UTType($0) }
            if types.contains(where: { $0.conforms(to: .image) || $0.conforms(to: .audiovisualContent) || $0.conforms(to: .pdf) }) { return nil }
            let isURL = provider.hasItemConformingToTypeIdentifier(UTType.url.identifier)
            guard isURL || provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) else { return nil }
            guard let value = await load(provider, type: isURL ? UTType.url.identifier : UTType.plainText.identifier) else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty && !parts.contains(trimmed) { parts.append(trimmed) }
        }
        let text = parts.joined(separator: "\n")
        return text.isEmpty || text.contains("\0") || text.utf8.count > 65536 ? nil : text
    }
    private static func load(_ provider: NSItemProvider, type: String) async -> String? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: type, options: nil) { item, _ in
                var text: String?
                if let url = item as? URL { text = url.isFileURL ? nil : url.absoluteString }
                else if let string = item as? String { text = string }
                else if let data = item as? Data { text = String(data: data, encoding: .utf8) }
                else if let attributed = item as? NSAttributedString { text = attributed.string }
                continuation.resume(returning: text)
            }
        }
    }
    /// 근처 기기(Bluetooth)로 보낼 때는 글자를 '아나-글자.txt' 한 파일로 만들어 보냅니다.
    static func file(_ text: String) throws -> PendingFile {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ahna-share-text-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("아나-글자.txt")
        let data = Data(text.utf8)
        try data.write(to: url)
        return PendingFile(url: url, path: url.path, bytes: Int64(data.count))
    }
}

struct DirectShareScreen: View {
    let context: NSExtensionContext?
    @StateObject private var client = AhnaClient(receive: false)
    @StateObject private var nearby = ShareNearby()
    @State private var files: [PendingFile] = []
    /// 웹 주소·글자만 공유했을 때 그 글자(파일 대신 상대 클립보드로 보냄)
    @State private var text: String?
    @State private var staging: URL?
    @State private var preparing = true
    @State private var preparationError = ""
    @State private var completed = false
    @Environment(\.colorScheme) private var colorScheme
    private var accent: Color {
        colorScheme == .dark ? Color(red: 0.298, green: 0.761, blue: 1.0) : Color(red: 0.0, green: 0.373, blue: 0.722)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("아나").font(.largeTitle.bold())
                Spacer()
                Button("취소") { client.cancel(); context?.cancelRequest(withError: CocoaError(.userCancelled)) }
            }
            HStack(spacing: 16) {
                Image(systemName: "paperplane.fill").font(.title).foregroundStyle(accent)
                VStack(alignment: .leading, spacing: 6) {
                    Text(nearby.active ? AhnaText.toward(nearby.target) + " 보내기" : "아나로 보내기").font(.headline)
                    Text(preparing ? "공유 파일 준비 중…" : text.map { ($0.hasPrefix("http://") || $0.hasPrefix("https://") ? "링크" : "글자") + " · 상대 기기 클립보드로 보냅니다" } ?? "선택한 파일 \(files.count)개").foregroundStyle(.secondary)
                }
                Spacer()
            }.padding(18).background(.background, in: RoundedRectangle(cornerRadius: 16))
            if nearby.active { nearbyStatus } else {
            Text("보낼 기기").font(.headline).foregroundStyle(.secondary)
            ScrollView {
                VStack(spacing: 1) {
                    ForEach(client.connections) { connection in
                        Button {
                            client.selectedID = connection.id
                            if let text {
                                // 주소·글자는 파일이 아니라 상대 기기의 받은 글자(클립보드)로 보냅니다.
                                Task { @MainActor in
                                    do { try await connection.sendClipboard(text); completed = true; context?.completeRequest(returningItems: nil) }
                                    catch { preparationError = error.localizedDescription }
                                }
                            } else {
                                _ = client.send(files) {
                                    completed = true
                                    context?.completeRequest(returningItems: nil)
                                }
                            }
                        } label: {
                            HStack(spacing: 14) {
                                DeviceStatusIcon(systemName: "desktopcomputer", isOnline: connection.state != nil).font(.title)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(connection.hostName).font(.headline)
                                    ConnectionStatusBadge(isOnline: connection.state != nil, onlineText: "온라인 · 눌러서 보내기", offlineText: "오프라인 · 재연결 대기")
                                }
                                Spacer()
                                Image(systemName: "paperplane.fill")
                            }.padding(18).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        .foregroundStyle(connection.state == nil ? AhnaPalette.offline : accent)
                        .ahnaRow(isOnline: connection.state != nil)
                        .disabled(preparing || completed || !preparationError.isEmpty || client.busy || connection.state == nil)
                        if connection.id != client.connections.last?.id { Divider().padding(.leading, 55) }
                    }
                    if client.connections.isEmpty {
                        Text(client.status.hasPrefix("컴퓨터마다") ? "먼저 아나 본체에서 기기를 추가해 주세요." : client.status)
                            .foregroundStyle(.secondary).padding(18).textSelection(.enabled)
                    }
                }.background(.background, in: RoundedRectangle(cornerRadius: 16))
                if !nearby.devices.isEmpty {
                    HStack(spacing: 5) {
                        Image(systemName: "dot.radiowaves.left.and.right")
                        Text("근처 기기")
                    }
                    .font(.headline).foregroundStyle(Self.nearText).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 14)
                    VStack(spacing: 1) {
                        ForEach(nearby.devices) { device in
                            Button {
                                let outgoing: [PendingFile]
                                if let text { guard let file = try? SharedText.file(text) else { return }; outgoing = [file] } else { outgoing = files }
                                nearby.send(outgoing, to: device, sender: client.deviceName) {
                                    completed = true
                                    Task { @MainActor in try? await Task.sleep(nanoseconds: 1_200_000_000); context?.completeRequest(returningItems: nil) }
                                }
                            } label: {
                                HStack(spacing: 14) {
                                    Text(String(device.name.prefix(1)).uppercased()).font(.headline).foregroundStyle(.white)
                                        .frame(width: 32, height: 32).background(Circle().fill(Self.near))
                                    Text(device.name).font(.headline)
                                    Spacer()
                                    Text(device.proximity).font(.callout).foregroundStyle(device.veryClose ? Self.nearText : .secondary)
                                }.padding(14).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                            .disabled(preparing || completed || !preparationError.isEmpty || client.busy)
                        }
                    }.background(.background, in: RoundedRectangle(cornerRadius: 16))
                }
            }
            }
            if !preparationError.isEmpty { Text(preparationError).foregroundStyle(.red).textSelection(.enabled) }
            if !client.progress.isEmpty {
                HStack { if client.busy { ProgressView().controlSize(.small) }; Text(client.progress).font(.callout).textSelection(.enabled) }
            }
            Text("\(client.deviceName) · 기기 추가와 이름 변경은 아나 본체에서 설정하세요. 모든 파일의 저장 응답을 확인하면 이 공유창이 자동으로 닫힙니다.")
                .font(.footnote).foregroundStyle(.secondary)
        }.padding(24).frame(minWidth: 440, minHeight: 480)
        .background(Color(nsColor: .windowBackgroundColor))
        .task { await prepareFiles() }
        .onAppear { nearby.start() }
        .task(id: client.pollID) { await client.poll() }
        .onDisappear { nearby.reset(); nearby.stop(); client.cancel(); if let staging { try? FileManager.default.removeItem(at: staging) } }
    }
    static let near = AhnaPalette.dynamicColor(light: 0x7C3AED, dark: 0xA78BFA)
    static let nearSoft = AhnaPalette.dynamicColor(light: 0xF1EBFE, dark: 0x2B2140)
    static let nearText = AhnaPalette.dynamicColor(light: 0x6D28D9, dark: 0xC4B5FD)

    @ViewBuilder private var nearbyStatus: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch nearby.phase {
            case .uploading(let fraction):
                // 파일을 서버에 맡기는 동안에도 확인 숫자를 먼저 보여 줍니다(다 올라가면 상대 화면에 같은 숫자가 뜹니다).
                HStack(spacing: 12) {
                    Text("파일을 준비하는 중 · \(Int(fraction * 100))%\n끝나면 상대 화면에 이 숫자가 뜹니다").foregroundStyle(.secondary)
                    Spacer()
                    ForEach(Array(nearby.code), id: \.self) { digit in
                        Text(String(digit)).font(.system(size: 26, weight: .bold).monospacedDigit()).foregroundStyle(Self.nearText)
                            .frame(width: 42, height: 52).background(RoundedRectangle(cornerRadius: 10).fill(Self.nearSoft))
                    }
                }
                ProgressView(value: fraction).tint(Self.near)
            case .waiting, .sending:
                HStack(spacing: 12) {
                    Text("상대 화면에 이 숫자가 보이면\n[받기]를 누르라고 알려 주세요").foregroundStyle(.secondary)
                    Spacer()
                    ForEach(Array(nearby.code), id: \.self) { digit in
                        Text(String(digit)).font(.system(size: 26, weight: .bold).monospacedDigit()).foregroundStyle(Self.nearText)
                            .frame(width: 42, height: 52).background(RoundedRectangle(cornerRadius: 10).fill(Self.nearSoft))
                    }
                }
                if case .sending(let done, let total) = nearby.phase { Text("상대가 받는 중 · \(done)/\(total)").font(.callout).foregroundStyle(.secondary) }
                else { Text("수락을 기다리는 중 · 30초 안에 받지 않으면 취소됩니다").font(.callout).foregroundStyle(.secondary) }
            case .declined: Text("상대가 받지 않았습니다.")
            case .failed(let message): Text(message).foregroundStyle(.red)
            case .done: Text("상대가 모두 받았습니다.")
            case .idle: EmptyView()
            }
            Button("다른 기기 고르기") { nearby.reset() }
        }
        .padding(18).frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 16))
    }

    private func prepareFiles() async {
        guard staging == nil else { return }
        do {
            let providers = (context?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
            guard !providers.isEmpty, providers.count <= 256 else { throw AhnaError.message("1~256개 항목을 선택해 주세요.") }
            if let shared = await SharedText.extract(providers) { text = shared; preparing = false; return }
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("AhnaDirectShare/" + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); staging = root
            var urls: [URL] = []
            for (index, provider) in providers.enumerated() {
                try Task.checkCancellation()
                let directory = root.appendingPathComponent(String(index), isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                urls.append(try await SharedItemCopy.copy(provider, to: directory))
            }
            files = try FilePreparation.collect(urls); preparing = false
        } catch { preparationError = error.localizedDescription; preparing = false }
    }
}
