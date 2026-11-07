// 아나 앱 정보 — 앱 · 공유 확장 · 검사 도구가 함께 씁니다.
import Foundation

enum Brand {
    static let ahna = true
    static let name = "아나"
    /// 서버 주소: 앱을 처음 실행할 때 초대 코드와 함께 사용자가 넣고, 본체와 공유 확장이 같이 보는 설정에 저장됩니다.
    static var server: String { ComputerVault.server() ?? "" }
    /// 업데이트를 확인할 GitHub 저장소(소유자/이름). 빌드할 때 scripts/set_repo.py가 넣습니다. 그대로면 업데이트 확인을 하지 않습니다.
    static let updateRepo = "OWNER/REPO"
    static var updates: Bool { !updateRepo.hasPrefix("OWNER/") }
    static var manifestURL: URL? { updates ? URL(string: "https://github.com/\(updateRepo)/releases/latest/download/latest.json") : nil }
    static var releasesURL: URL? { updates ? URL(string: "https://github.com/\(updateRepo)/releases/latest") : nil }
    /// 사용자가 넣은 주소를 https://호스트[:포트] 꼴로 맞춥니다. 올바르지 않으면 nil.
    static func normalizeServer(_ input: String) -> String? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("/") { text.removeLast() }
        if text.isEmpty { return nil }
        if !text.contains("://") { text = "https://" + text }
        guard let parts = URLComponents(string: text), parts.scheme?.lowercased() == "https", let host = parts.host, !host.isEmpty,
              parts.path.isEmpty || parts.path == "/", parts.query == nil, parts.user == nil, parts.password == nil else { return nil }
        return "https://" + host.lowercased() + (parts.port.map { ":\($0)" } ?? "")
    }
    /// 아나 서버가 발급한 기기 토큰: ahna.{기기 ID 32자}.{64자}
    static func isMemberToken(_ key: String) -> Bool {
        let p = key.split(separator: ".", omittingEmptySubsequences: false)
        return p.count == 3 && p[0] == "ahna" && p[1].count == 32 && p[2].count == 64 && p[1].allSatisfy { $0.isASCII && $0.isHexDigit } && p[2].allSatisfy { $0.isASCII && $0.isHexDigit }
    }
}
