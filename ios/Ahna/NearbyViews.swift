import SwiftUI
import UIKit
import CoreImage
import CoreImage.CIFilterBuiltins

// 아나 1.2 근처 기기 · QR 화면 요소 (디자인: NearbyPhone · NearbySheet · NearbyRequest · NearbyOptions · QrShow)

/// 근처 기기 강조색(파랑). light near #7c3aed · nearSoft #f1ebfe · nearText #6d28d9 / dark #a78bfa · #2b2140 · #c4b5fd
enum NearbyPalette {
    static let near = AhnaPalette.rgb(0x7C3AED, 0xA78BFA)
    static let soft = AhnaPalette.rgb(0xF1EBFE, 0x2B2140)
    static let text = AhnaPalette.rgb(0x6D28D9, 0xC4B5FD)
}

/// Bluetooth 모양(시안의 SVG 경로 m7 7 10 10-5 5V2l5 5L7 17)
struct BluetoothGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        let scale = min(rect.width, rect.height) / 24
        let ox = rect.midX - 12 * scale, oy = rect.midY - 12 * scale
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: ox + x * scale, y: oy + y * scale) }
        var path = Path()
        path.move(to: point(7, 7)); path.addLine(to: point(17, 17)); path.addLine(to: point(12, 22))
        path.addLine(to: point(12, 2)); path.addLine(to: point(17, 7)); path.addLine(to: point(7, 17))
        return path
    }
}

struct BluetoothIcon: View {
    var size: CGFloat = 15
    var body: some View {
        BluetoothGlyph()
            .stroke(style: StrokeStyle(lineWidth: max(1.4, size / 11), lineCap: .round, lineJoin: .round))
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// 이름 첫 글자 동그라미
struct NearbyAvatar: View {
    let name: String
    var size: CGFloat = 38
    var strong = true
    var body: some View {
        Text(String(name.trimmingCharacters(in: .whitespaces).first.map { String($0).uppercased() } ?? "?"))
            .font(.system(size: size * 0.4, weight: .bold))
            .foregroundStyle(strong ? Color.white : AhnaPalette.muted)
            .frame(width: size, height: size)
            .background(Circle().fill(strong ? NearbyPalette.near : AhnaPalette.subtle))
            .accessibilityHidden(true)
    }
}

struct ProximityBadge: View {
    let device: NearbyDevice
    var body: some View {
        Text(device.proximity)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(device.veryClose ? NearbyPalette.text : AhnaPalette.muted)
            .padding(.horizontal, 8).frame(height: 24)
            .background(Capsule().fill(device.veryClose ? NearbyPalette.soft : AhnaPalette.subtle))
            .lineLimit(1).fixedSize()
    }
}

/// 확인 숫자 "47" → 두 칸
struct CodeDigits: View {
    let code: String
    var big = true
    var body: some View {
        HStack(spacing: big ? 8 : 6) {
            ForEach(Array(code.enumerated()), id: \.offset) { _, digit in
                Text(String(digit))
                    .font(.system(size: big ? 34 : 26, weight: .bold).monospacedDigit())
                    .frame(width: big ? 52 : 40, height: big ? 64 : 48)
                    .background(RoundedRectangle(cornerRadius: big ? 12 : 10, style: .continuous).fill(big ? AhnaPalette.subtle : Color.clear))
                    .overlay(RoundedRectangle(cornerRadius: big ? 12 : 10, style: .continuous).strokeBorder(AhnaPalette.border, lineWidth: 1))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("확인 숫자 " + code.map { String($0) }.joined(separator: " "))
    }
}

// MARK: - 보낼 기기 카드의 '근처 기기' (NearbyPhone)

struct NearbyTargetSection: View {
    let devices: [NearbyDevice]
    let selectedID: String
    let select: (NearbyDevice) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                BluetoothIcon(size: 15).foregroundStyle(NearbyPalette.near)
                    .frame(width: 26, height: 26)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(NearbyPalette.soft))
                Text("근처 기기").font(.system(size: 13, weight: .bold)).foregroundStyle(AhnaPalette.text).accessibilityAddTraits(.isHeader)
                Text("Bluetooth · 가까운 기기만 보입니다").font(.system(size: 12)).foregroundStyle(AhnaPalette.faint).lineLimit(1)
            }
            ForEach(devices) { device in
                let selected = "near:" + device.id.uuidString == selectedID
                Button { select(device) } label: {
                    HStack(spacing: 12) {
                        NearbyAvatar(name: device.name, size: 38, strong: selected)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(device.name).font(.system(size: 14, weight: .medium)).foregroundStyle(AhnaPalette.text).lineLimit(1)
                            if !device.platform.isEmpty { Text(device.platform).font(.system(size: 12)).foregroundStyle(AhnaPalette.faint) }
                        }
                        Spacer(minLength: 4)
                        ProximityBadge(device: device)
                    }
                    .padding(.horizontal, 12)
                    .frame(minHeight: 58)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(selected ? NearbyPalette.soft : AhnaPalette.surface))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(selected ? NearbyPalette.near : AhnaPalette.border, lineWidth: selected ? 2 : 1))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(device.name), 근처 기기, \(device.proximity)")
                .accessibilityAddTraits(selected ? AccessibilityTraits.isSelected : AccessibilityTraits())
            }
            HStack(spacing: 8) {
                Circle().fill(NearbyPalette.near).opacity(0.6).frame(width: 8, height: 8).accessibilityHidden(true)
                Text(devices.isEmpty ? "근처 기기를 찾는 중… 상대도 아나를 열어 두어야 보입니다" : "상대도 아나를 열어 두어야 보입니다")
                    .font(.system(size: 12)).foregroundStyle(AhnaPalette.faint)
            }
        }
    }
}

// MARK: - 보내는 쪽 창 (NearbySheet)

struct NearbySendSheet: View {
    @ObservedObject var center: NearbyCenter
    let summary: String
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                AhnaLogoTile(size: 40)
                VStack(alignment: .leading, spacing: 0) {
                    Text("아나로 보내기").font(.system(size: 17, weight: .bold))
                    Text(summary).font(.system(size: 12)).foregroundStyle(AhnaPalette.faint).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.bottom, 14)
            if let outgoing = center.outgoing { content(outgoing) }
            Spacer(minLength: 0)
        }
        .foregroundStyle(AhnaPalette.text)
        .padding(.horizontal, 16).padding(.top, 20).padding(.bottom, 24)
        .frame(maxWidth: 520)
        .frame(maxWidth: .infinity)
        .background(AhnaPalette.surface.ignoresSafeArea())
        .overlay { if center.incoming != nil { NearbyRequestOverlay(center: center) } }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .onAppear { center.sheetDepth += 1 }
        .onDisappear { center.sheetDepth = max(0, center.sheetDepth - 1) }
    }

    @ViewBuilder private func content(_ o: NearbyOutgoing) -> some View {
        switch o.phase {
        case .preparing:
            VStack(spacing: 10) {
                NearbyAvatar(name: o.deviceName, size: 64, strong: false)
                ProgressView().tint(NearbyPalette.near)
                Text("\(o.deviceName)에 알리는 중…").font(.system(size: 17, weight: .bold)).multilineTextAlignment(.center)
                Text("파일을 준비하고 근처 기기에 보내기 요청을 전하는 중입니다").font(.system(size: 13)).foregroundStyle(AhnaPalette.muted).multilineTextAlignment(.center)
                cancelButton("보내기 취소")
            }
        case .waiting:
            VStack(spacing: 10) {
                Text(String(o.deviceName.first.map { String($0).uppercased() } ?? "?"))
                    .font(.system(size: 24, weight: .bold)).foregroundStyle(NearbyPalette.near)
                    .frame(width: 64, height: 64).background(Circle().fill(NearbyPalette.soft)).accessibilityHidden(true)
                Text("\(o.deviceName)에서 수락을 기다리는 중").font(.system(size: 17, weight: .bold)).multilineTextAlignment(.center)
                Text("상대 화면에 같은 확인 숫자가 보이는지 확인해 달라고 하세요").font(.system(size: 13)).foregroundStyle(AhnaPalette.muted).multilineTextAlignment(.center)
                CodeDigits(code: o.code, big: true).padding(.vertical, 4)
                Text("30초 안에 받지 않으면 자동으로 취소됩니다").font(.system(size: 12)).foregroundStyle(AhnaPalette.faint)
                cancelButton("보내기 취소")
            }
        case .sending(let done, let total):
            VStack(spacing: 10) {
                NearbyAvatar(name: o.deviceName, size: 64)
                Text("\(o.deviceName)에서 받는 중").font(.system(size: 17, weight: .bold)).multilineTextAlignment(.center)
                ProgressView(value: Double(done), total: Double(max(total, 1))).tint(NearbyPalette.near)
                Text("\(done)/\(total)개 보냄 · 끝날 때까지 아나를 열어 두세요").font(.system(size: 12)).foregroundStyle(AhnaPalette.faint).multilineTextAlignment(.center)
                cancelButton("닫기")
            }
        case .done:
            result(symbol: "checkmark", positive: true, title: "\(o.deviceName)에 보냈습니다", detail: "상대가 모두 받았습니다. 공유 링크는 이제 사용할 수 없습니다.")
        case .declined:
            result(symbol: "xmark", positive: false, title: "\(o.deviceName)에서 받지 않았습니다", detail: "상대가 거절했거나 응답이 없었습니다")
        case .failed(let message):
            result(symbol: "xmark", positive: false, title: "보내지 못했습니다", detail: message)
        }
    }

    private func cancelButton(_ title: String) -> some View {
        Button(title) { center.closeOutgoing() }
            .buttonStyle(AhnaButtonStyle(kind: .subtle, height: 48))
            .padding(.top, 6)
    }
    private func result(symbol: String, positive: Bool, title: String, detail: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 24, weight: .bold))
                .foregroundStyle(positive ? AhnaPalette.accent : AhnaPalette.muted)
                .frame(width: 56, height: 56)
                .background(Circle().fill(positive ? AhnaPalette.accentSoft : AhnaPalette.subtle))
                .accessibilityHidden(true)
            Text(title).font(.system(size: 17, weight: .bold)).multilineTextAlignment(.center)
            Text(detail).font(.system(size: 12)).foregroundStyle(AhnaPalette.faint).multilineTextAlignment(.center)
            cancelButton("닫기")
        }
        .padding(.top, 14)
    }
}

// MARK: - 받는 쪽 확인 창 (NearbyRequest)

struct NearbyRequestOverlay: View {
    @ObservedObject var center: NearbyCenter
    var body: some View {
        if let request = center.incoming {
            ZStack {
                Color.black.opacity(0.5).ignoresSafeArea().accessibilityHidden(true)
                card(request)
                    .padding(.horizontal, 20).padding(.top, 22).padding(.bottom, 18)
                    .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(AhnaPalette.surface))
                    .shadow(color: .black.opacity(0.3), radius: 30, y: 20)
                    .frame(maxWidth: 440)
                    .padding(16)
                    .accessibilityElement(children: .contain)
                    .accessibilityAddTraits(.isModal)
            }
            .foregroundStyle(AhnaPalette.text)
            .transition(.opacity)
        }
    }

    private var guest: Bool {
        guard let source = center.incoming?.source, case .guest = source else { return false }
        return true
    }

    @ViewBuilder private func card(_ r: NearbyIncoming) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                if guest { Image(systemName: "qrcode").font(.system(size: 13, weight: .semibold)) } else { BluetoothIcon(size: 14) }
                Text(guest ? "QR로 연 페이지에서 보내려고 합니다" : "근처 기기에서 보내려고 합니다").font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(NearbyPalette.text)
            HStack(spacing: 12) {
                NearbyAvatar(name: r.sender, size: 52)
                VStack(alignment: .leading, spacing: 2) {
                    Text(r.sender).font(.system(size: 18, weight: .bold)).lineLimit(1)
                    Text(r.detail).font(.system(size: 12)).foregroundStyle(AhnaPalette.muted).lineLimit(2)
                }
            }
            HStack(spacing: 12) {
                Image(systemName: r.summary.hasPrefix("사진") ? "photo.on.rectangle" : (r.summary.hasPrefix("동영상") ? "film" : "doc.on.doc"))
                    .font(.system(size: 18)).foregroundStyle(AhnaPalette.muted)
                    .frame(width: 44, height: 44)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(AhnaPalette.surface))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 0) {
                    Text(r.summary).font(.system(size: 14, weight: .bold))
                    Text(fileLine(r)).font(.system(size: 12)).foregroundStyle(AhnaPalette.faint).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(AhnaPalette.subtle))
            switch r.phase {
            case .asking:
                HStack(spacing: 10) {
                    Text("보내는 사람 화면의 숫자와 같나요?").font(.system(size: 13)).foregroundStyle(AhnaPalette.muted)
                    Spacer(minLength: 4)
                    CodeDigits(code: r.code, big: false)
                }
                HStack(spacing: 10) {
                    Button("거절") { center.decline() }.buttonStyle(AhnaButtonStyle(kind: .subtle, height: 52))
                    Button("받기") { center.accept() }.buttonStyle(AhnaButtonStyle(kind: .primary, height: 52))
                }
                .padding(.top, 4)
                Text("받은 파일은 평소처럼 저장됩니다 · \(max(0, Int(r.deadline.timeIntervalSince(center.now).rounded(.up))))초 뒤 자동 거절")
                    .font(.system(size: 12)).foregroundStyle(AhnaPalette.faint).frame(maxWidth: .infinity).multilineTextAlignment(.center)
            case .receiving(let text):
                HStack(spacing: 10) {
                    ProgressView().tint(AhnaPalette.accent)
                    Text(text).font(.system(size: 13)).foregroundStyle(AhnaPalette.muted).lineLimit(2)
                }
                Text("다 받을 때까지 아나를 열어 두세요").font(.system(size: 12)).foregroundStyle(AhnaPalette.faint)
                Button("창 닫기") { center.dismissIncoming() }.buttonStyle(AhnaButtonStyle(kind: .subtle, height: 48))
            case .done(let text):
                Label(text, systemImage: "checkmark.circle.fill").font(.system(size: 14, weight: .medium)).foregroundStyle(AhnaPalette.accent)
                Button("닫기") { center.dismissIncoming() }.buttonStyle(AhnaButtonStyle(kind: .subtle, height: 48))
            case .failed(let text):
                Text(text).font(.system(size: 13)).foregroundStyle(AhnaPalette.danger)
                Button("닫기") { center.dismissIncoming() }.buttonStyle(AhnaButtonStyle(kind: .subtle, height: 48))
            }
        }
    }

    private func fileLine(_ r: NearbyIncoming) -> String {
        var parts: [String] = []
        if let first = r.firstName { parts.append(r.count > 1 ? "\(first) 외 \(r.count - 1)개" : first) }
        else if r.count > 0 { parts.append("\(r.count)개") }
        if r.bytes > 0 { parts.append(AhnaText.bytes(r.bytes)) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - QR로 보내기 / 받기 (QrShow)

enum QRCodeImage {
    static func make(_ text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let image = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: image)
    }
}

struct QrShareSheet: View {
    @ObservedObject var host: MobileHostModel
    @ObservedObject var center: NearbyCenter
    let files: [PendingFile]
    let summary: String
    let onSent: () -> Void
    @State var mode: GuestKind
    @State private var token: String?
    @State private var link: String?
    @State private var image: UIImage?
    @State private var message: String?
    @State private var working = false
    @State private var copied = false
    @State private var reported = false
    @Environment(\.dismiss) private var dismiss

    private var ticket: GuestTicketSnapshot? { token.flatMap { host.tickets[$0] } }
    private var send: Bool { mode == .send }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                HStack(spacing: 12) {
                    Image(systemName: "qrcode").font(.system(size: 19, weight: .semibold)).foregroundStyle(AhnaPalette.onAccent)
                        .frame(width: 40, height: 40)
                        .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(AhnaPalette.accent))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(send ? "QR로 보내기" : "QR로 받기").font(.system(size: 17, weight: .bold)).accessibilityAddTraits(.isHeader)
                        Text(send ? summary : "상대가 이 기기로 파일을 올릴 수 있습니다").font(.system(size: 12)).foregroundStyle(AhnaPalette.faint).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                Picker("QR", selection: $mode) {
                    Text("보내기").tag(GuestKind.send)
                    Text("받기").tag(GuestKind.receive)
                }
                .pickerStyle(.segmented)
                .disabled(working)

                content

                HStack(spacing: 10) {
                    Button(copied ? "복사했습니다" : "링크 복사") {
                        guard let link else { return }
                        UIPasteboard.general.string = link; copied = true
                        Task { @MainActor in try? await Task.sleep(nanoseconds: 1_500_000_000); copied = false }
                    }
                    .buttonStyle(AhnaButtonStyle(kind: .secondary, height: 48))
                    .disabled(link == nil || ticket?.finished == true)
                    Button("닫기") { dismiss() }
                        .buttonStyle(AhnaButtonStyle(kind: .subtle, height: 48))
                }
                .padding(.top, 4)
                Text("상대는 앱 없이 iPhone · Android 카메라로 찍기만 하면 됩니다\n이 기기에서 아나를 열어 두는 동안만 링크가 동작합니다")
                    .font(.system(size: 12)).foregroundStyle(AhnaPalette.faint).multilineTextAlignment(.center)
                // 보낼 때 안내(예전 옵션의 ‘보낼 때’ 카드)
                Text("근처 기기나 QR로 보내면 파일은 서버를 거쳐 갑니다. 상대는 그 파일만 받을 수 있고, 다 받으면 접근 권한이 바로 없어집니다.")
                    .font(.system(size: 12)).foregroundStyle(AhnaPalette.faint).multilineTextAlignment(.center)
            }
            .padding(.horizontal, 20).padding(.top, 22).padding(.bottom, 28)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .foregroundStyle(AhnaPalette.text)
        .background(AhnaPalette.surface.ignoresSafeArea())
        .overlay { if center.incoming != nil { NearbyRequestOverlay(center: center) } }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .onAppear { center.sheetDepth += 1; make() }
        .onDisappear { center.sheetDepth = max(0, center.sheetDepth - 1); release() }
        .onChange(of: mode) { _, _ in release(); make() }
        .onChange(of: ticket?.state) { _, state in
            if state == "done", send, !reported { reported = true; onSent() }
        }
    }

    @ViewBuilder private var content: some View {
        if let message {
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.circle").font(.system(size: 26)).foregroundStyle(AhnaPalette.muted).accessibilityHidden(true)
                Text(message).font(.system(size: 14)).multilineTextAlignment(.center)
                if !(send && files.isEmpty) {
                    Button("다시 시도") { release(); make() }.buttonStyle(AhnaButtonStyle(kind: .soft, height: 40, fullWidth: false))
                }
            }
            .padding(.vertical, 24)
        } else if let ticket, ticket.finished {
            VStack(spacing: 8) {
                let ok = ticket.state == "done"
                Image(systemName: ok ? "checkmark" : "clock.badge.xmark").font(.system(size: 24, weight: .bold))
                    .foregroundStyle(ok ? AhnaPalette.accent : AhnaPalette.muted)
                    .frame(width: 56, height: 56)
                    .background(Circle().fill(ok ? AhnaPalette.accentSoft : AhnaPalette.subtle))
                    .accessibilityHidden(true)
                Text(ok ? (send ? "보냈습니다" : "받았습니다") : (ticket.state == "declined" ? "받지 않았습니다" : "링크가 만료되었습니다"))
                    .font(.system(size: 17, weight: .bold))
                Text(ok ? (send ? "상대가 모두 받았습니다. 링크는 이제 사용할 수 없습니다." : "받은 파일은 파일 앱 › 아나에 있습니다.") : "새 QR을 만들어 다시 시도하세요.")
                    .font(.system(size: 12)).foregroundStyle(AhnaPalette.faint).multilineTextAlignment(.center)
                if !ok { Button("새 QR 만들기") { release(); make() }.buttonStyle(AhnaButtonStyle(kind: .soft, height: 40, fullWidth: false)).padding(.top, 4) }
            }
            .padding(.vertical, 24)
        } else if let image, let ticket {
            Image(uiImage: image)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .frame(width: 216, height: 216)
                .padding(16)
                .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color.white))
                .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(AhnaPalette.border, lineWidth: 1))
                .accessibilityLabel("QR 코드")
            Text(instruction(ticket)).font(.system(size: 15, weight: .medium)).multilineTextAlignment(.center)
            HStack(spacing: 6) {
                Text("\(NearbyCenter.clock(ticket.expires.timeIntervalSince(center.now))) 남음 · 한 번만 쓸 수 있는 링크")
                    .font(.system(size: 13, weight: .bold).monospacedDigit())
            }
            .foregroundStyle(AhnaPalette.accent)
            .padding(.horizontal, 12).frame(height: 28)
            .background(Capsule().fill(AhnaPalette.accentSoft))
        } else {
            ProgressView().tint(AhnaPalette.accent).frame(height: 248)
        }
    }

    private func instruction(_ ticket: GuestTicketSnapshot) -> String {
        switch ticket.state {
        case "transferring": return send ? "상대가 받는 중 · \(ticket.completed)/\(ticket.files.count)개" : "받는 중 · \(ticket.completed)/\(ticket.files.count)개"
        case "waiting": return "상대가 보내려고 합니다. 확인 창에서 받기를 누르세요"
        case "accepted": return "상대가 올리기를 시작합니다…"
        default: return send ? "상대에게 카메라로 이 QR을 찍게 하세요" : "상대가 찍으면 올리기 페이지가 열립니다. 받기 전에 확인 창이 뜹니다"
        }
    }

    private func make() {
        guard !working else { return }
        message = nil; image = nil; link = nil; token = nil; reported = false
        let kind = mode
        if kind == .send && files.isEmpty { message = "보낼 파일을 먼저 고르세요. ‘파일 보내기’에서 사진이나 파일을 고른 뒤 QR을 누르세요."; return }
        guard host.guestReady else {
            message = "서버 설정이 필요합니다.\n옵션 › 서버에서 ‘이 기기가 서버로 받기’를 연결하면 QR로 주고받을 수 있습니다."; return
        }
        working = true
        Task { @MainActor in
            do {
                let created = try await host.createTicket(kind: kind, files: kind == .send ? files : [], code: nil)
                working = false
                // 만드는 사이 보내기/받기를 바꿨으면 지우고 지금 고른 쪽으로 다시 만듭니다.
                guard kind == mode else { host.cancelTicket(created.token); make(); return }
                guard let url = host.guestURL(created.token), let picture = QRCodeImage.make(url) else {
                    host.cancelTicket(created.token); throw AhnaError.message("QR을 만들지 못했습니다.")
                }
                token = created.token; link = url; image = picture
            } catch { working = false; message = error.localizedDescription }
        }
    }

    /// 아직 아무도 쓰지 않은 링크는 창을 닫거나 바꿀 때 지웁니다. 받는 중·확인 대기 중이면 그대로 둡니다.
    private func release() {
        if let token, let state = host.tickets[token]?.state, state == "ready" { host.cancelTicket(token) }
        token = nil; link = nil; image = nil
    }
}

// MARK: - 옵션: 근처 기기에서 받기 (NearbyOptions)

struct NearbyOptionsCard: View {
    @ObservedObject var center: NearbyCenter
    /// 이 기기 이름(다른 기기에 보이는 이름)과 바꾸기
    var deviceName = ""
    var onEditName: (() -> Void)? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                BluetoothIcon(size: 17).foregroundStyle(NearbyPalette.near)
                    .frame(width: 34, height: 34)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(NearbyPalette.soft))
                VStack(alignment: .leading, spacing: 0) {
                    CardTitle("근처 기기에서 받기")
                    Text("등록하지 않은 사람이 가까이에서 보낼 수 있습니다").font(.system(size: 12)).foregroundStyle(AhnaPalette.faint)
                }
            }
            VStack(spacing: 8) {
                modeRow(.off, "끔", "근처 기기에 이 기기가 보이지 않습니다")
                modeRow(.registered, "등록된 기기만", "내가 등록한 기기에게만 보입니다 (기본값)")
                modeRow(.everyone, "10분 동안 모두", "근처의 누구나 보낼 수 있고, 매번 받을지 묻습니다")
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("근처 기기에서 받기")
            Button { onEditName?() } label: {
                HStack(spacing: 10) {
                    Text("내 기기 이름").font(.system(size: 13)).foregroundStyle(AhnaPalette.muted)
                    Spacer(minLength: 4)
                    Text(deviceName.isEmpty ? center.shownName : deviceName).font(.system(size: 13, weight: .medium)).foregroundStyle(AhnaPalette.text).lineLimit(1)
                    if onEditName != nil {
                        Text("바꾸기").font(.system(size: 13, weight: .medium)).foregroundStyle(AhnaPalette.accent)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                .frame(minHeight: 44)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(AhnaPalette.subtle))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(onEditName == nil)
            .accessibilityLabel("내 기기 이름, " + (deviceName.isEmpty ? center.shownName : deviceName))
            .accessibilityHint("눌러서 이름 바꾸기")
            status
        }
        .ahnaCard()
    }

    private func modeRow(_ value: NearbyMode, _ title: String, _ hint: String) -> some View {
        let on = center.mode == value
        return Button { center.setMode(value) } label: {
            HStack(spacing: 12) {
                ZStack {
                    Circle().strokeBorder(on ? NearbyPalette.near : AhnaPalette.border, lineWidth: 2)
                    if on { Circle().fill(NearbyPalette.near).frame(width: 10, height: 10) }
                }
                .frame(width: 20, height: 20)
                VStack(alignment: .leading, spacing: 0) {
                    Text(title).font(.system(size: 14, weight: .medium)).foregroundStyle(AhnaPalette.text)
                    Text(hint).font(.system(size: 12)).foregroundStyle(AhnaPalette.faint).multilineTextAlignment(.leading)
                }
                Spacer(minLength: 4)
                if on, value == .everyone, let left = center.everyoneRemaining {
                    Text("\(left) 남음").font(.system(size: 13, weight: .bold).monospacedDigit()).foregroundStyle(NearbyPalette.text)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .frame(minHeight: 56)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(on ? NearbyPalette.soft : AhnaPalette.surface))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(on ? NearbyPalette.near : AhnaPalette.border, lineWidth: on ? 2 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title + ", " + hint)
        .accessibilityAddTraits(on ? AccessibilityTraits.isSelected : AccessibilityTraits())
    }

    @ViewBuilder private var status: some View {
        switch center.bluetooth {
        case .on:
            line(AhnaPalette.online, "Bluetooth 켜짐 · 받는 동안 아나를 열어 두세요")
        case .off:
            line(AhnaPalette.offline, "Bluetooth가 꺼져 있습니다 · 제어 센터나 설정에서 켜면 근처 기기를 쓸 수 있습니다")
        case .unauthorized:
            VStack(alignment: .leading, spacing: 6) {
                line(AhnaPalette.danger, "Bluetooth 권한이 없습니다 · 설정에서 아나의 Bluetooth 권한을 허용하세요")
                Button("설정 열기") { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } }
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(AhnaPalette.accent).frame(minHeight: 32)
            }
        case .unsupported:
            line(AhnaPalette.offline, "이 기기는 Bluetooth LE를 지원하지 않아 근처 기기를 쓸 수 없습니다 · QR은 쓸 수 있습니다")
        case .unknown:
            line(AhnaPalette.offline, "Bluetooth 확인 중…")
        }
    }
    private func line(_ color: Color, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle().fill(color).frame(width: 8, height: 8).accessibilityHidden(true)
            Text(text).font(.system(size: 12)).foregroundStyle(AhnaPalette.faint)
        }
    }
}

/// 옵션: 근처 기기로 보낼 때 안내
struct NearbySendInfoCard: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("보낼 때").font(.system(size: 14, weight: .bold)).accessibilityAddTraits(.isHeader)
            Text("근처 기기나 QR로 보내면 파일은 서버를 거쳐 갑니다. 상대는 그 파일만 받을 수 있고, 다 받으면 접근 권한이 바로 없어집니다. 이 기기는 아나가 화면에 열려 있는 동안만 보내고 받을 수 있습니다.")
                .font(.system(size: 13)).foregroundStyle(AhnaPalette.muted)
        }
        .foregroundStyle(AhnaPalette.text)
        .ahnaCard(horizontal: 16, vertical: 14)
    }
}

/// 근처 기기로 보내기 버튼(파랑)
struct NearbyButtonStyle: ButtonStyle {
    var height: CGFloat = 50
    func makeBody(configuration: Configuration) -> some View { StyledLabel(configuration: configuration, height: height) }
    private struct StyledLabel: View {
        let configuration: ButtonStyleConfiguration
        let height: CGFloat
        @Environment(\.isEnabled) private var isEnabled
        var body: some View {
            let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
            configuration.label
                .font(.system(size: 15, weight: .bold))
                .lineLimit(1)
                .foregroundStyle(Color.white)
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity)
                .frame(height: height)
                .background(shape.fill(NearbyPalette.near))
                .contentShape(shape)
                .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.45)
        }
    }
}
