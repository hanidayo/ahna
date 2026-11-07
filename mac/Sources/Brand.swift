// 아나 / 아나(Ahna) 빌드 구분 — 앱 · 공유 확장 · 검사 도구가 함께 씁니다.

/// 빌드 종류. scripts/ahna-brand.py 가 지인용 앱 '아나(Ahna)'를 만들 때 이 세 줄을 바꿉니다.
enum Brand {
    static let ahna = true
    static let name = "아나"
    static let server = "https://example.synology.me"
    /// 아나 서버가 발급한 기기 토큰: ahna.{기기 ID 32자}.{64자}
    static func isMemberToken(_ key: String) -> Bool {
        let p = key.split(separator: ".", omittingEmptySubsequences: false)
        return p.count == 3 && p[0] == "ahna" && p[1].count == 32 && p[2].count == 64 && p[1].allSatisfy { $0.isASCII && $0.isHexDigit } && p[2].allSatisfy { $0.isASCII && $0.isHexDigit }
    }
}
