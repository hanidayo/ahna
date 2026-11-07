// Ahna v1.0 — 연결 상태 표시 (다크모드 수정)
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
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

enum AhnaText {
    /// "아이폰으로" · "Mac로"
    static func toward(_ name: String) -> String {
        guard let last = name.unicodeScalars.last, (0xAC00...0xD7A3).contains(last.value) else { return name + "로" }
        let jong = (last.value - 0xAC00) % 28
        return name + ((jong == 0 || jong == 8) ? "로" : "으로")
    }
}

enum AhnaPalette {
    /// 16진수 라이트/다크 색
    static func dynamicColor(light: UInt32, dark: UInt32) -> Color {
        func c(_ hex: UInt32) -> (Double, Double, Double) { (Double((hex >> 16) & 0xFF) / 255, Double((hex >> 8) & 0xFF) / 255, Double(hex & 0xFF) / 255) }
        return dynamic(light: c(light), dark: c(dark))
    }
    /// 앱 강조색. 바로드롭과 같은 파랑: 라이트 #005FB8 / 다크 #4CC2FF
    static let accent = dynamic(light: (0.0, 0.373, 0.722), dark: (0.298, 0.761, 1.0))
    /// 온라인. 라이트 #1E7A46 / 다크 #4ADE80 (어두운 배경 대비 9:1 이상)
    static let online = dynamic(light: (0.118, 0.478, 0.275), dark: (0.290, 0.871, 0.502))
    /// 오프라인. 라이트 #8A8F98 / 다크 #8E949E — 온라인과 밝기·채도가 크게 다름
    static let offline = dynamic(light: (0.541, 0.561, 0.596), dark: (0.557, 0.580, 0.620))
    /// 상태 배지 배경(옅은 채움)
    static let onlineFill = dynamic(light: (0.118, 0.478, 0.275), dark: (0.290, 0.871, 0.502), lightAlpha: 0.12, darkAlpha: 0.18)
    static let offlineFill = dynamic(light: (0.541, 0.561, 0.596), dark: (0.557, 0.580, 0.620), lightAlpha: 0.12, darkAlpha: 0.16)

    private static func dynamic(light: (Double, Double, Double), dark: (Double, Double, Double),
                                lightAlpha: Double = 1, darkAlpha: Double = 1) -> Color {
        #if canImport(UIKit)
        return Color(UIColor { trait in
            let (c, a) = trait.userInterfaceStyle == .dark ? (dark, darkAlpha) : (light, lightAlpha)
            return UIColor(red: c.0, green: c.1, blue: c.2, alpha: a)
        })
        #elseif canImport(AppKit)
        return Color(NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .vibrantDark, .accessibilityHighContrastDarkAqua]) != nil
            let (c, a) = isDark ? (dark, darkAlpha) : (light, lightAlpha)
            return NSColor(srgbRed: c.0, green: c.1, blue: c.2, alpha: a)
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
