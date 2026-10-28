import SwiftUI
import AppKit

/// 메인 창 2열 "클립보드" 카드. 받을 기기는 1열 "보낼 기기"에서 고른 기기(selectedTarget)를 그대로 씁니다.
@MainActor struct MacClipboardView: View {
    @ObservedObject var receiver: MacReceiverModel
    @ObservedObject var client: AhnaClient
    @Binding var selectedTarget: String
    @State private var draft = ""
    @State private var notice = ""
    @State private var sending = false
    @State private var copying = false
    @State private var copiedItem = ""
    @State private var previews: [String: String] = [:]

    private struct Entry: Identifiable {
        let id: String
        let source: String
        let item: InboxClipboard
        let connection: AhnaConnection?
    }

    private var targets: [MacSendTarget] { MacSendTarget.all(receiver: receiver, client: client) }
    private var target: MacSendTarget? { targets.first { $0.id == selectedTarget } }
    private var targetReady: Bool {
        guard let target else { return false }
        switch target.kind {
        case .device(let id): return receiver.clipboardSupported && receiver.devices.contains { $0.id == id }
        case .computer(let id): return client.connections.contains { $0.id == id && $0.state?.clipboard != nil }
        }
    }
    private var entries: [Entry] {
        receiver.clipboard.map { Entry(id: "receiver:" + $0.id, source: $0.sender, item: $0, connection: nil) } +
        client.connections.flatMap { connection in
            (connection.state?.clipboard ?? []).map { Entry(id: connection.id.uuidString + $0.id, source: connection.hostName, item: $0, connection: connection) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("클립보드").font(.system(size: 14, weight: .bold))
                Spacer(minLength: 0)
                Text(target.map { "받는 기기 · " + $0.name } ?? "받을 기기를 선택하세요")
                    .font(.system(size: 12)).foregroundColor(MacTheme.faint).lineLimit(1)
            }
            ZStack(alignment: .topLeading) {
                TextEditor(text: $draft)
                    .font(.system(size: 13))
                    .foregroundColor(MacTheme.text)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .disabled(sending)
                    .accessibilityLabel("보낼 글자")
                if draft.isEmpty {
                    Text("보낼 글자를 입력하거나 붙여넣으세요")
                        .font(.system(size: 13)).foregroundColor(MacTheme.faint)
                        .padding(.horizontal, 11).padding(.vertical, 6)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .frame(minHeight: 110, maxHeight: 170)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(MacTheme.subtle))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(MacTheme.border, lineWidth: 1))
            HStack(spacing: 8) {
                Button("붙여넣기") { pasteFromMac() }
                    .buttonStyle(MacButtonStyle(kind: .secondary, height: 34, fullWidth: true, fontSize: 13))
                    .disabled(sending)
                    .help("Mac 클립보드의 글자를 가져옵니다")
                Button("글자 보내기") { sendDraft() }
                    .buttonStyle(MacButtonStyle(kind: .primary, height: 34, fullWidth: true, fontSize: 13))
                    .disabled(sending || client.busy || receiver.clipboardBusy || draft.isEmpty || !targetReady)
            }
            if !notice.isEmpty {
                Text(notice)
                    .font(.system(size: 12)).foregroundColor(MacTheme.muted)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if targets.isEmpty {
                hint("옵션에서 상대 기기의 연결 코드로 받을 기기를 추가하세요.")
            } else if target != nil && !targetReady {
                hint("선택한 기기가 오프라인이거나 아직 글자 받기를 지원하지 않습니다.")
            }
            if !receiver.clipboardSupported {
                hint("Mac 수신 서비스를 확인하는 중입니다. 계속 표시되면 수신 구성요소도 함께 업데이트하세요.")
            }
            Text("받은 글자")
                .font(.system(size: 12, weight: .bold)).foregroundColor(MacTheme.muted)
                .padding(.top, 8)
            ScrollView {
                VStack(spacing: 0) {
                    let list = entries
                    ForEach(list) { entry in row(entry, isLast: entry.id == list.last?.id) }
                    if list.isEmpty {
                        Text("아직 받은 글자가 없습니다.")
                            .font(.system(size: 12)).foregroundColor(MacTheme.faint)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 8)
                    }
                }
            }
            Text("⌘C로 복사 → 붙여넣기 → 글자 보내기(최대 64 KB). 받은 글자는 복사한 뒤 ⌘V로 붙여넣으세요. 최근 20개를 최대 24시간 보관하며, 글자를 보관하는 컴퓨터의 아나가 종료되면 지워집니다.")
                .font(.system(size: 11.5)).foregroundColor(MacTheme.faint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .macCard(fill: true)
    }

    private func hint(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12)).foregroundColor(MacTheme.faint)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func meta(_ entry: Entry) -> String {
        if let date = MacTimeText.parse(entry.item.created) { return entry.source + " · " + MacTimeText.relative(date) }
        return entry.source
    }

    private func row(_ entry: Entry, isLast: Bool) -> some View {
        let preview = previews[entry.id]
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(meta(entry)).font(.system(size: 12)).foregroundColor(MacTheme.faint).lineLimit(1)
                Text(preview ?? "글자 " + ByteCountFormatter.string(fromByteCount: Int64(entry.item.bytes), countStyle: .file))
                    .font(.system(size: 13))
                    .foregroundColor(preview == nil ? MacTheme.muted : MacTheme.text)
                    .lineLimit(1).truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(copiedItem == entry.id ? "복사됨" : "복사") { copy(entry) }
                .buttonStyle(MacButtonStyle(kind: .soft, height: 28))
                .disabled(copying || (entry.connection == nil && receiver.clipboardBusy))
                .accessibilityLabel(entry.source + "에서 받은 글자 복사")
        }
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) { if !isLast { MacHairline() } }
    }

    private func pasteFromMac() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.isEmpty else {
            notice = "클립보드에 글자가 없습니다. 먼저 다른 앱에서 글자를 복사하세요."; return
        }
        draft = text; notice = "보낼 글자를 확인한 뒤 ‘글자 보내기’를 누르세요."
    }

    private func sendDraft() {
        let kind = target?.kind; let text = draft
        sending = true
        Task { @MainActor in
            defer { sending = false }
            do {
                if case .device(let id)? = kind { try await receiver.sendClipboard(text, target: id) }
                else if case .computer(let id)? = kind, let connection = client.connections.first(where: { $0.id == id }) { try await connection.sendClipboard(text) }
                else { throw AhnaError.message("받을 기기를 선택하고 연결을 확인하세요.") }
                notice = "글자를 보냈습니다. 받은 쪽에서 ‘복사’를 누르세요."
            } catch { notice = error.localizedDescription }
        }
    }

    private func copy(_ entry: Entry) {
        copying = true
        Task { @MainActor in
            defer { copying = false }
            do {
                let text: String
                if let connection = entry.connection { text = try await connection.clipboardText(entry.item) }
                else { text = try await receiver.clipboardText(entry.item) }
                try copyToMac(text)
                copiedItem = entry.id
                previews[entry.id] = text.replacingOccurrences(of: "\n", with: " ")
            } catch { notice = error.localizedDescription }
        }
    }

    private func copyToMac(_ text: String) throws {
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.setString(text, forType: .string) else { throw AhnaError.message("클립보드에 복사하지 못했습니다. 다시 시도하세요.") }
        notice = "복사했습니다. 원하는 앱에서 ⌘V로 붙여넣으세요."
    }
}
