import SwiftUI
import AppKit
import CoreImage

// 아나 — Mac 근처 기기 · QR 화면 요소 (아이폰 NearbyViews와 같은 문구 · 보라색)

enum MacNear {
    static let near = MacTheme.color(0x7c3aed, 0xa78bfa)
    static let soft = MacTheme.color(0xf1ebfe, 0x2b2140)
    static let text = MacTheme.color(0x6d28d9, 0xc4b5fd)
}

/// 보낼 기기 카드 아래: 근처에서 찾은 등록하지 않은 기기
struct MacNearbyRows: View {
    @ObservedObject var center: NearbyCenter
    let selected: String
    let select: (NearbyDevice) -> Void
    var body: some View {
        if center.available, !center.devices.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 5) {
                    Image(systemName: "dot.radiowaves.left.and.right").font(.system(size: 11, weight: .semibold))
                    Text("근처 기기").font(.system(size: 12, weight: .bold))
                }
                .foregroundColor(MacNear.text)
                .padding(.top, 8)
                ForEach(center.devices) { device in
                    let isSelected = selected == "nearby:" + device.id.uuidString
                    Button(action: { select(device) }) {
                        HStack(spacing: 10) {
                            Text(String(device.name.prefix(1)).uppercased())
                                .font(.system(size: 12, weight: .bold)).foregroundColor(.white)
                                .frame(width: 26, height: 26).background(Circle().fill(MacNear.near))
                            Text(device.name).font(.system(size: 13, weight: .medium)).lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Text(device.proximity).font(.system(size: 11, weight: device.veryClose ? .bold : .regular))
                                .foregroundColor(device.veryClose ? MacNear.text : MacTheme.muted)
                                .padding(.horizontal, 7).padding(.vertical, 2)
                                .background(Capsule().fill(device.veryClose ? MacNear.soft : MacTheme.subtle))
                        }
                        .padding(.horizontal, 10)
                        .frame(minHeight: 44)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(isSelected ? MacNear.soft : MacTheme.surface))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(isSelected ? MacNear.near : MacTheme.border, lineWidth: isSelected ? 2 : 1))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(device.name + ", 근처 기기, " + device.proximity)
                }
            }
        }
    }
}

/// 받을지 묻는 창 · 받는 중 · 완료
struct MacIncomingCard: View {
    @ObservedObject var center: NearbyCenter
    let incoming: NearbyIncoming
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Text(String(incoming.sender.prefix(1)).uppercased())
                    .font(.system(size: 17, weight: .bold)).foregroundColor(.white)
                    .frame(width: 42, height: 42).background(Circle().fill(MacNear.near))
                VStack(alignment: .leading, spacing: 2) {
                    Text(incoming.sender + "에서 보내려고 합니다").font(.system(size: 15, weight: .bold)).lineLimit(1)
                    Text(incoming.detail).font(.system(size: 12)).foregroundColor(MacTheme.muted).lineLimit(1)
                }
            }
            HStack(spacing: 10) {
                Image(systemName: "doc").font(.system(size: 15)).foregroundColor(MacTheme.accent)
                    .frame(width: 34, height: 34).background(RoundedRectangle(cornerRadius: 8).fill(MacTheme.accentSoft))
                VStack(alignment: .leading, spacing: 1) {
                    Text(incoming.summary).font(.system(size: 13, weight: .semibold))
                    Text(ByteCountFormatter.string(fromByteCount: incoming.bytes, countStyle: .file) + " · 받은 파일 폴더에 저장됩니다")
                        .font(.system(size: 11.5)).foregroundColor(MacTheme.muted)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10).fill(MacTheme.subtle))
            switch incoming.phase {
            case .asking:
                HStack {
                    Text("보내는 사람 화면의 숫자와 같나요?").font(.system(size: 12.5)).foregroundColor(MacTheme.muted)
                    Spacer()
                    ForEach(Array(incoming.code), id: \.self) { digit in
                        Text(String(digit)).font(.system(size: 22, weight: .bold).monospacedDigit())
                            .frame(width: 36, height: 42)
                            .background(RoundedRectangle(cornerRadius: 8).strokeBorder(MacTheme.border))
                    }
                }
                HStack(spacing: 8) {
                    Text("\(max(0, Int(incoming.deadline.timeIntervalSince(center.now).rounded(.up))))초 뒤 자동 거절")
                        .font(.system(size: 11.5)).foregroundColor(MacTheme.faint)
                    Spacer()
                    Button("거절") { center.decline() }.buttonStyle(MacButtonStyle(kind: .secondary, height: 32, fontSize: 13))
                    Button("받기") { center.accept() }.buttonStyle(MacButtonStyle(kind: .primary, height: 32, fontSize: 13)).keyboardShortcut(.defaultAction)
                }
            case .receiving(let text):
                HStack { ProgressView().controlSize(.small); Text(text).font(.system(size: 12.5)); Spacer()
                    Button("닫기") { center.dismissIncoming() }.buttonStyle(MacButtonStyle(kind: .secondary, height: 28)) }
            case .done(let text):
                HStack { Image(systemName: "checkmark.circle.fill").foregroundColor(MacTheme.on); Text(text).font(.system(size: 12.5)); Spacer()
                    Button("닫기") { center.dismissIncoming() }.buttonStyle(MacButtonStyle(kind: .secondary, height: 28)) }
            case .failed(let text):
                HStack { Image(systemName: "exclamationmark.triangle.fill").foregroundColor(MacTheme.danger); Text(text).font(.system(size: 12.5)).fixedSize(horizontal: false, vertical: true); Spacer()
                    Button("닫기") { center.dismissIncoming() }.buttonStyle(MacButtonStyle(kind: .secondary, height: 28)) }
            }
        }
        .padding(20)
        .frame(width: 420)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(MacTheme.surface))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(MacTheme.border))
        .shadow(color: .black.opacity(0.22), radius: 24, y: 8)
    }
}

/// 근처 기기로 보내는 중
struct MacOutgoingCard: View {
    @ObservedObject var center: NearbyCenter
    let outgoing: NearbyOutgoing
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(outgoing.deviceName + "(으)로 보내기").font(.system(size: 15, weight: .bold))
            switch outgoing.phase {
            case .preparing:
                HStack { ProgressView().controlSize(.small); Text("보낼 준비를 하는 중…").font(.system(size: 12.5)) }
            case .waiting:
                HStack(spacing: 12) {
                    Text("상대 화면에 이 숫자가 보이면 [받기]를 누르라고 알려 주세요").font(.system(size: 12.5)).foregroundColor(MacTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    ForEach(Array(outgoing.code), id: \.self) { digit in
                        Text(String(digit)).font(.system(size: 24, weight: .bold).monospacedDigit()).foregroundColor(MacNear.text)
                            .frame(width: 38, height: 46).background(RoundedRectangle(cornerRadius: 8).fill(MacNear.soft))
                    }
                }
                Text("수락을 기다리는 중 · 30초 안에 받지 않으면 취소됩니다").font(.system(size: 11.5)).foregroundColor(MacTheme.faint)
            case .sending(let done, let total):
                HStack { ProgressView().controlSize(.small); Text("보내는 중 · \(done)/\(total)").font(.system(size: 12.5)) }
            case .done:
                HStack { Image(systemName: "checkmark.circle.fill").foregroundColor(MacTheme.on); Text("상대가 모두 받았습니다.").font(.system(size: 12.5)) }
            case .declined:
                HStack { Image(systemName: "xmark.circle.fill").foregroundColor(MacTheme.muted); Text("상대가 받지 않았습니다.").font(.system(size: 12.5)) }
            case .failed(let text):
                HStack { Image(systemName: "exclamationmark.triangle.fill").foregroundColor(MacTheme.danger); Text(text).font(.system(size: 12.5)).fixedSize(horizontal: false, vertical: true) }
            }
            HStack { Spacer()
                Button(isActive ? "취소" : "닫기") { center.closeOutgoing() }.buttonStyle(MacButtonStyle(kind: .secondary, height: 30, fontSize: 13)).keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 420)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(MacTheme.surface))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(MacTheme.border))
        .shadow(color: .black.opacity(0.22), radius: 24, y: 8)
    }
    private var isActive: Bool { switch outgoing.phase { case .preparing, .waiting: return true; default: return false } }
}

/// QR로 보내기 · 받기
struct MacQRCard: View {
    @ObservedObject var center: NearbyCenter
    let qr: NearbyQR
    var body: some View {
        let ticket = center.ticket(qr.token)
        VStack(spacing: 14) {
            Text(qr.kind == .send ? "QR로 보내기" : "QR로 받기").font(.system(size: 16, weight: .bold))
            if let error = qr.error {
                Text(error).font(.system(size: 12.5)).foregroundColor(MacTheme.danger).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            } else if let url = qr.url {
                if let image = Self.image(url) {
                    Image(nsImage: image).interpolation(.none).resizable().frame(width: 220, height: 220)
                        .padding(12).background(RoundedRectangle(cornerRadius: 12).fill(Color.white))
                }
                Text(qr.kind == .send ? "상대는 앱 없이 휴대폰 카메라로 찍기만 하면 됩니다" : "상대가 카메라로 찍으면 웹 페이지에서 파일을 골라 보낼 수 있습니다")
                    .font(.system(size: 12.5)).foregroundColor(MacTheme.muted).multilineTextAlignment(.center)
                Text(status(ticket)).font(.system(size: 12.5, weight: .semibold)).foregroundColor(MacNear.text)
                Button("링크 복사") {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url, forType: .string)
                }.buttonStyle(MacButtonStyle(kind: .soft, height: 28))
            } else {
                ProgressView().controlSize(.small)
                Text("링크를 만드는 중…").font(.system(size: 12.5)).foregroundColor(MacTheme.muted)
            }
            Button("닫기") { center.closeQR() }.buttonStyle(MacButtonStyle(kind: .secondary, height: 30, fontSize: 13)).keyboardShortcut(.cancelAction)
        }
        .padding(22)
        .frame(width: 340)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(MacTheme.surface))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(MacTheme.border))
        .shadow(color: .black.opacity(0.22), radius: 24, y: 8)
    }
    private func status(_ ticket: GuestTicketSnapshot?) -> String {
        guard let ticket else { return "10분 동안 쓸 수 있습니다 · 아나를 열어 두세요" }
        switch ticket.state {
        case "transferring", "accepted": return ticket.kind == .send ? "보내는 중 · \(ticket.completed)/\(ticket.files.count)" : "받는 중 · \(ticket.completed)/\(ticket.files.count)"
        case "done": return ticket.kind == .send ? "상대가 모두 받았습니다" : "\(ticket.files.count)개를 받았습니다 · 받은 파일 폴더"
        case "declined", "expired": return "링크가 끝났습니다 · 새로 만들어 주세요"
        case "waiting": return "상대가 보내려고 합니다 · 확인 창을 보세요"
        default: return "10분 동안 쓸 수 있습니다 · 아나를 열어 두세요"
        }
    }
    static func image(_ text: String) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage"); filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)) else { return nil }
        let rep = NSCIImageRep(ciImage: output)
        let image = NSImage(size: rep.size); image.addRepresentation(rep)
        return image
    }
}

/// 옵션: 근처 기기에서 받기 · QR
struct MacNearbyOptions: View {
    @ObservedObject var center: NearbyCenter
    let guestReady: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: "dot.radiowaves.left.and.right").font(.system(size: 11, weight: .semibold))
                Text("근처 기기에서 받기").font(.system(size: 12, weight: .bold))
            }
            .foregroundColor(MacNear.text)
            Picker("", selection: Binding(get: { center.mode }, set: { center.setMode($0) })) {
                Text("끔").tag(NearbyMode.off)
                Text("등록된 기기만").tag(NearbyMode.registered)
                Text("10분 동안 모두").tag(NearbyMode.everyone)
            }
            .pickerStyle(.segmented).labelsHidden()
            Text(note).font(.system(size: 11.5)).foregroundColor(MacTheme.faint).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("QR로 보내기…") { pickAndShare() }.buttonStyle(MacButtonStyle(kind: .soft, height: 28))
                Button("QR로 받기") { center.openQR(urls: []) }.buttonStyle(MacButtonStyle(kind: .soft, height: 28))
            }
            .disabled(!guestReady)
            if !guestReady { Text("QR은 서버에 연결된 뒤 쓸 수 있습니다.").font(.system(size: 11.5)).foregroundColor(MacTheme.faint) }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(MacNear.soft.opacity(0.5)))
    }
    private var note: String {
        switch center.bluetooth {
        case .unsupported: return "이 Mac은 Bluetooth LE를 지원하지 않습니다."
        case .unauthorized: return "시스템 설정 › 개인정보 보호 및 보안 › Bluetooth에서 아나를 허용해 주세요."
        case .off: return "Bluetooth가 꺼져 있습니다."
        default:
            switch center.mode {
            case .off: return "근처 기기에 이 Mac을 보이지 않습니다."
            case .registered: return "등록하지 않은 사람에게는 보이지 않습니다."
            case .everyone: return "근처 누구나 이 Mac에 보낼 수 있습니다 · 남은 시간 " + (center.everyoneRemaining ?? "") + " · 받을 때마다 확인합니다"
            }
        }
    }
    private func pickAndShare() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true; panel.canChooseDirectories = true; panel.canChooseFiles = true
        panel.prompt = "QR로 보내기"
        if panel.runModal() == .OK, !panel.urls.isEmpty { center.openQR(urls: panel.urls) }
    }
}
