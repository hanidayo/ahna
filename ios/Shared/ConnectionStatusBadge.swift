// 아나 1.1 — 팔레트 · 연결 상태 표시 · 공용 카드/버튼 (앱과 공유 확장이 함께 사용)
// (v1.0 다크모드 수정 내용 유지)
//
// 문제: 등록된 기기 목록의 온라인/오프라인이 라이트 모드에서는 구분되지만 다크 모드에서는 구분되지 않음.
// 원인: 상태를 고정 RGB 색(앱 tint: 어두운 초록 0.13/0.34/0.28)과 .secondary 회색의 '밝기 차이'로만 구분했습니다.
//      어두운 배경에서는 어두운 초록과 회색이 둘 다 흐릿하게 보여 차이가 사라집니다.
// 해결: 1) 라이트/다크마다 다른 값을 갖는 동적 색을 사용하고
//      2) 색 외에 모양(채운 점 ● / 빈 점 ○)과 글자(온라인 / 오프라인)로도 구분하며
//      3) 오프라인 행 전체를 흐리게(opacity) 해 한눈에 보이게 합니다.
//
// 사용 예
//   ConnectionStatusBadge(isOnline: connection.state != nil)
//   AhnaRowStyle(isOnline: …) 수정자로 행을 흐리게 표시
//   .tint(AhnaPalette.accent)   // 앱 전체 tint도 다크모드 대응 색으로 교체

import SwiftUI
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

enum AhnaPalette {
    // 아나 1.1 팔레트 (라이트 / 다크). 시스템 다크 모드를 따릅니다.
    static let bg = rgb(0xEEF1F5, 0x1c1c1c)
    static let surface = rgb(0xFFFFFF, 0x272727)
    static let subtle = rgb(0xF7F8FA, 0x2E2E2E)
    static let border = rgb(0xE3E6EA, 0x3A3A3A)
    static let borderStrong = rgb(0xC5CAD1, 0x555555)
    static let text = rgb(0x1F2328, 0xE8EAED)
    static let muted = rgb(0x5B636E, 0xA7AEB8)
    static let faint = rgb(0x6B7280, 0x9AA1AB)
    /// 앱 강조색. 라이트 #005FB8 / 다크 #4CC2FF
    static let accent = rgb(0x005FB8, 0x4CC2FF)
    static let onAccent = rgb(0xFFFFFF, 0x002033)
    static let onAccentLine = rgb(0xFFFFFF, 0x002033, lightAlpha: 0.45, darkAlpha: 0.35)
    static let accentSoft = rgb(0xE5EFF9, 0x16303F)
    /// 온라인. 라이트 #1E7A48 / 다크 #4ADE80
    static let online = rgb(0x1E7A48, 0x4ADE80)
    /// 오프라인. 라이트 #9AA1AB / 다크 #8B929C — 온라인과 밝기·채도가 크게 다름
    static let offline = rgb(0x9AA1AB, 0x8B929C)
    static let danger = rgb(0xC4372F, 0xF2786F)
    static let dangerSoft = rgb(0xFDECEA, 0x3A2321)
    /// 상태 배지 배경(옅은 채움)
    static let onlineFill = rgb(0x1E7A48, 0x4ADE80, lightAlpha: 0.12, darkAlpha: 0.18)
    static let offlineFill = rgb(0x9AA1AB, 0x8B929C, lightAlpha: 0.12, darkAlpha: 0.16)

    /// 라이트/다크 16진수 색으로 동적 Color를 만듭니다. 예: AhnaPalette.rgb(0xFFFFFF, 0x272727)
    static func rgb(_ light: UInt32, _ dark: UInt32, lightAlpha: Double = 1, darkAlpha: Double = 1) -> Color {
        dynamic(light: components(light), dark: components(dark), lightAlpha: lightAlpha, darkAlpha: darkAlpha)
    }

    private static func components(_ hex: UInt32) -> (Double, Double, Double) {
        (Double((hex >> 16) & 0xFF) / 255.0, Double((hex >> 8) & 0xFF) / 255.0, Double(hex & 0xFF) / 255.0)
    }

    private static func dynamic(light: (Double, Double, Double), dark: (Double, Double, Double),
                                lightAlpha: Double = 1, darkAlpha: Double = 1) -> Color {
        #if canImport(UIKit)
        return Color(UIColor { trait in
            let (c, a) = trait.userInterfaceStyle == .dark ? (dark, darkAlpha) : (light, lightAlpha)
            return UIColor(red: CGFloat(c.0), green: CGFloat(c.1), blue: CGFloat(c.2), alpha: CGFloat(a))
        })
        #elseif canImport(AppKit)
        return Color(NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .vibrantDark, .accessibilityHighContrastDarkAqua]) != nil
            let (c, a) = isDark ? (dark, darkAlpha) : (light, lightAlpha)
            return NSColor(srgbRed: CGFloat(c.0), green: CGFloat(c.1), blue: CGFloat(c.2), alpha: CGFloat(a))
        })
        #else
        return Color(red: light.0, green: light.1, blue: light.2).opacity(lightAlpha)
        #endif
    }
}

/// 온라인/오프라인 배지: 색 + 모양 + 글자로 구분 (색약·다크모드 모두 대응)
struct ConnectionStatusBadge: View {
    let isOnline: Bool
    var onlineText = "온라인"
    var offlineText = "오프라인"

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: isOnline ? "circle.fill" : "circle")
                .font(.system(size: 8, weight: .bold))
            Text(isOnline ? onlineText : offlineText)
                .font(.caption.weight(.semibold))
        }
        .foregroundStyle(isOnline ? AhnaPalette.online : AhnaPalette.offline)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(isOnline ? AhnaPalette.onlineFill : AhnaPalette.offlineFill))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isOnline ? onlineText : offlineText)
    }
}

/// 오프라인 기기 행을 흐리게 표시
struct AhnaRowStyle: ViewModifier {
    let isOnline: Bool
    func body(content: Content) -> some View {
        content.opacity(isOnline ? 1 : 0.55)
    }
}

extension View {
    func ahnaRow(isOnline: Bool) -> some View { modifier(AhnaRowStyle(isOnline: isOnline)) }
}

/// 기기 아이콘: 온라인은 강조색, 오프라인은 회색 + 사선
struct DeviceStatusIcon: View {
    let systemName: String
    let isOnline: Bool
    var body: some View {
        Image(systemName: systemName)
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(isOnline ? AhnaPalette.online : AhnaPalette.offline)
            .overlay(alignment: .bottomTrailing) {
                Circle()
                    .fill(isOnline ? AhnaPalette.online : AhnaPalette.offline)
                    .frame(width: 8, height: 8)
                    .overlay(Circle().stroke(Color(white: 0.5, opacity: 0.35), lineWidth: isOnline ? 0 : 1))
                    .offset(x: 3, y: 2)
            }
    }
}

// MARK: - 아나 1.1 공용 화면 요소 (앱 · 공유 확장 공용)

/// 화면 배치 기준: 지금 창(Split View · Slide Over 칸 포함)의 너비. 크기 등급(size class)이나 기기 종류는 보지 않습니다.
/// iPad 세로도 horizontalSizeClass가 regular라서 예전에는 3열이 되어 칸이 너무 좁았습니다.
enum AhnaLayout {
    /// 700pt 미만 = 1열(휴대폰 배치) · 700~999pt = 2열(태블릿 세로) · 1000pt 이상 = 3열(태블릿 가로)
    static func columns(forWidth width: CGFloat) -> Int {
        if width >= 1000 { return 3 }
        if width >= 700 { return 2 }
        return 1
    }
    /// 공유 창: 700pt 이상이면 가운데 대화상자 + 기기 카드 격자, 아니면 아래 시트 + 목록
    static func isWide(_ width: CGFloat) -> Bool { width >= 700 }
}

/// 상태 점: 온라인 = 꽉 찬 점(online 색), 오프라인 = 속이 빈 테두리 점(offline 색)
struct StatusDot: View {
    let isOnline: Bool
    var size: CGFloat = 8
    var body: some View {
        ZStack {
            if isOnline {
                Circle().fill(AhnaPalette.online)
            } else {
                Circle().strokeBorder(AhnaPalette.offline, lineWidth: 1.5)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// 점 + "연결됨"/"오프라인" 글자 (배경 없음)
struct DeviceStateLabel: View {
    let isOnline: Bool
    var onlineText = "연결됨"
    var offlineText = "오프라인"
    var body: some View {
        HStack(spacing: 5) {
            StatusDot(isOnline: isOnline, size: 7)
            Text(isOnline ? onlineText : offlineText)
                .font(.system(size: 12, weight: isOnline ? .medium : .regular))
                .lineLimit(1)
        }
        .foregroundStyle(isOnline ? AhnaPalette.online : AhnaPalette.faint)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isOnline ? onlineText : offlineText)
    }
}

/// 공유 창의 상태 배지: 온라인은 옅은 초록 캡슐, 오프라인은 테두리 캡슐
struct DeviceStatePill: View {
    let isOnline: Bool
    var body: some View {
        HStack(spacing: 5) {
            StatusDot(isOnline: isOnline, size: 7)
            Text(isOnline ? "연결됨" : "오프라인")
                .font(.system(size: 12, weight: isOnline ? .medium : .regular))
        }
        .foregroundStyle(isOnline ? AhnaPalette.online : AhnaPalette.faint)
        .padding(.horizontal, 9)
        .frame(height: 26)
        .background(Capsule().fill(isOnline ? AhnaPalette.accentSoft : Color.clear))
        .overlay(Capsule().strokeBorder(isOnline ? Color.clear : AhnaPalette.border, lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isOnline ? "연결됨" : "오프라인")
    }
}

/// 머리글의 서버 상태 캡슐
struct NASStatusPill: View {
    /// MobileHostModel.remoteStatus 값
    let status: String
    var isConnected: Bool { status.contains("연결됨") }
    private var label: String {
        if isConnected { return "서버 연결됨" }
        if status.contains("연결 중") { return "서버 연결 중" }
        return "서버 연결 안 됨"
    }
    var body: some View {
        HStack(spacing: 6) {
            StatusDot(isOnline: isConnected, size: 8)
            Text(label).font(.system(size: 12, weight: .medium)).lineLimit(1)
        }
        .foregroundStyle(isConnected ? AhnaPalette.online : AhnaPalette.muted)
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(Capsule().fill(isConnected ? AhnaPalette.accentSoft : AhnaPalette.subtle))
        .overlay(Capsule().strokeBorder(isConnected ? Color.clear : AhnaPalette.border, lineWidth: 1))
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityHint(status)
    }
}

/// 강조색 바탕의 앱 로고 타일
struct AhnaLogoTile: View {
    var size: CGFloat = 32
    var body: some View {
        Image(systemName: "paperplane")
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(AhnaPalette.onAccent)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous).fill(AhnaPalette.accent))
            .accessibilityHidden(true)
    }
}

/// 기기 아이콘 타일: 온라인은 옅은 초록 바탕, 오프라인은 회색 바탕
struct DeviceIconTile: View {
    let symbol: String
    let isOnline: Bool
    var size: CGFloat = 40
    /// 오프라인일 때 바탕색(공유 창처럼 행 자체가 subtle이면 surface로 바꿉니다)
    var offlineFill: Color = AhnaPalette.subtle
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.42, weight: .regular))
            .foregroundStyle(isOnline ? AhnaPalette.accent : AhnaPalette.faint)
            .frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
                .fill(isOnline ? AhnaPalette.accentSoft : offlineFill))
            .accessibilityHidden(true)
    }
}

enum AhnaText {
    /// 기기 이름으로 아이콘을 고릅니다(기기 종류 정보가 없어 이름으로 추정).
    static func deviceSymbol(_ name: String) -> String {
        let n = name.lowercased()
        if n.contains("ipad") || n.contains("태블릿") || n.contains("탭") || n.contains("tab") { return "ipad" }
        if n.contains("iphone") || n.contains("아이폰") || n.contains("갤럭시") || n.contains("galaxy") || n.contains("android") || n.contains("폰") || n.contains("phone") { return "iphone" }
        if n.contains("mac") || n.contains("맥") || n.contains("노트북") || n.contains("laptop") { return "laptopcomputer" }
        return "desktopcomputer"
    }
    /// "사무실 PC" → "사무실 PC로", "나의 맥북" → "나의 맥북으로"
    static func toward(_ name: String) -> String {
        guard let last = name.unicodeScalars.last, (0xAC00...0xD7A3).contains(last.value) else { return name + "로" }
        let jong = (last.value - 0xAC00) % 28
        return name + ((jong == 0 || jong == 8) ? "로" : "으로")
    }
    /// 연결 코드 "482913" → "482 913"
    static func spacedCode(_ pin: String) -> String {
        guard pin.count == 6 else { return pin.isEmpty ? "------" : pin }
        return String(pin.prefix(3)) + " " + String(pin.suffix(3))
    }
    static func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }
    /// 파일 확장자로 아이콘을 고릅니다.
    static func fileSymbol(_ name: String) -> String {
        let ext = (name as NSString).pathExtension
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext) else { return "doc" }
        if type.conforms(to: .image) { return "photo" }
        if type.conforms(to: .movie) || type.conforms(to: .audiovisualContent) { return "film" }
        if type.conforms(to: .pdf) { return "doc.richtext" }
        if type.conforms(to: .archive) { return "doc.zipper" }
        return "doc"
    }
}

/// 카드: 16pt 모서리, surface 채움, 1px 테두리
struct AhnaCardModifier: ViewModifier {
    var insets: EdgeInsets
    func body(content: Content) -> some View {
        content
            .padding(insets)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(AhnaPalette.surface))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(AhnaPalette.border, lineWidth: 1))
    }
}

extension View {
    func ahnaCard(padding: CGFloat = 16) -> some View {
        modifier(AhnaCardModifier(insets: EdgeInsets(top: padding, leading: padding, bottom: padding, trailing: padding)))
    }
    func ahnaCard(horizontal: CGFloat, vertical: CGFloat) -> some View {
        modifier(AhnaCardModifier(insets: EdgeInsets(top: vertical, leading: horizontal, bottom: vertical, trailing: horizontal)))
    }
    /// 카드 안의 입력칸 모양(subtle 바탕 + 테두리)
    func ahnaField(height: CGFloat? = nil, radius: CGFloat = 12) -> some View {
        self
            .frame(height: height)
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(AhnaPalette.subtle))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(AhnaPalette.border, lineWidth: 1))
    }
}

/// 카드 사이 구분선(1px border 색)
struct AhnaDivider: View {
    var body: some View { Rectangle().fill(AhnaPalette.border).frame(height: 1).accessibilityHidden(true) }
}

/// 시안의 버튼 모양들
struct AhnaButtonStyle: ButtonStyle {
    enum Kind { case primary, outline, soft, secondary, subtle }
    var kind: Kind
    var height: CGFloat = 46
    var fullWidth = true

    func makeBody(configuration: Configuration) -> some View {
        StyledLabel(configuration: configuration, kind: kind, height: height, fullWidth: fullWidth)
    }

    private struct StyledLabel: View {
        let configuration: ButtonStyleConfiguration
        let kind: Kind
        let height: CGFloat
        let fullWidth: Bool
        @Environment(\.isEnabled) private var isEnabled

        private var radius: CGFloat { height <= 36 ? 10 : 12 }
        private var foreground: Color {
            switch kind {
            case .primary: return AhnaPalette.onAccent
            case .outline, .soft: return AhnaPalette.accent
            case .secondary, .subtle: return AhnaPalette.text
            }
        }
        private var fill: Color {
            switch kind {
            case .primary: return AhnaPalette.accent
            case .outline, .secondary: return AhnaPalette.surface
            case .soft: return AhnaPalette.accentSoft
            case .subtle: return AhnaPalette.subtle
            }
        }
        private var line: Color {
            switch kind {
            case .outline: return AhnaPalette.accent
            case .secondary: return AhnaPalette.border
            default: return Color.clear
            }
        }
        private var labelFont: Font {
            switch kind {
            case .primary: return .system(size: height >= 48 ? 15 : 14, weight: .bold)
            case .outline: return .system(size: 14, weight: .bold)
            case .soft: return .system(size: 13, weight: .bold)
            case .secondary: return .system(size: 13, weight: .regular)
            case .subtle: return .system(size: 14, weight: .medium)
            }
        }

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
            configuration.label
                .font(labelFont)
                .lineLimit(1)
                .foregroundStyle(foreground)
                .padding(.horizontal, fullWidth ? 16 : 12)
                .frame(maxWidth: fullWidth ? .infinity : nil)
                .frame(height: height)
                .background(shape.fill(fill))
                .overlay(shape.strokeBorder(line, lineWidth: 1))
                .contentShape(shape)
                .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.45)
        }
    }
}
