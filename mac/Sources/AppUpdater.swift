// Ahna v1.0 — GitHub Releases 업데이트 (iOS / macOS 공용)
//
// macOS: 새 버전을 내려받아 SHA-256 검증 → 앱 종료 → .app 교체 → 다시 실행 (완전 자동)
// iOS  : 사이드로드 앱은 스스로 설치할 수 없습니다(Apple 제한). 새 버전을 알리고 IPA 내려받기 페이지를 엽니다.
//
// 연결 방법
//   @StateObject var updater = AppUpdater()
//   .task { await updater.check() }                 // 앱 시작 시
//   UpdateBanner(updater: updater)                   // 목록 상단 등에 배치
//
// 저장소: scripts/set_owner.py가 hanidayo를 실제 GitHub 계정으로 바꿉니다.

import Foundation
import SwiftUI
import CryptoKit
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

struct AhnaUpdateAsset: Decodable { let url: URL; let sha256: String; let size: Int64 }
struct AhnaUpdateManifest: Decodable {
    let version: String
    let notesUrl: URL?
    let fullInstallRequired: Bool?
    let platforms: [String: AhnaUpdateAsset]
}

@MainActor
final class AppUpdater: ObservableObject {
    static let shared = AppUpdater()
    // 아나 서버가 업데이트 파일을 보관합니다(GitHub Actions가 빌드 후 자동으로 올림).
    static let manifestURL = URL(string: Brand.server + "/_ahna/update/latest.json")!
    static let releasesURL = URL(string: Brand.server + "/_ahna/download")!

    enum Phase: Equatable { case idle, checking, upToDate, available(String), downloading, failed(String) }
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var manifest: AhnaUpdateManifest?

    private let lastCheckKey = "Ahna.update.lastCheck"
    private var platformKey: String {
        #if os(macOS)
        return "mac"
        #else
        return "ios"
        #endif
    }

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    /// force=false면 6시간에 한 번만 네트워크 확인
    func check(force: Bool = false) async {
        let defaults = UserDefaults.standard
        if !force, manifest != nil, let last = defaults.object(forKey: lastCheckKey) as? Date,
           Date().timeIntervalSince(last) < 6 * 3600 { return }
        phase = .checking
        do {
            var request = URLRequest(url: Self.manifestURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
            request.setValue("Ahna-\(platformKey)/\(Self.currentVersion)", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            let latest = try JSONDecoder().decode(AhnaUpdateManifest.self, from: data)
            defaults.set(Date(), forKey: lastCheckKey)
            manifest = latest
            if Self.isNewer(latest.version, than: Self.currentVersion), latest.platforms[platformKey] != nil {
                phase = .available(latest.version)
            } else {
                phase = .upToDate
            }
        } catch {
            phase = force ? .failed("업데이트 확인 실패: \(error.localizedDescription)") : .idle
        }
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            (s.trimmingCharacters(in: CharacterSet(charactersIn: "vV")).split(separator: "-").first ?? "")
                .split(separator: ".").map { Int($0) ?? 0 } + [0, 0, 0]
        }
        let x = parts(a), y = parts(b)
        for i in 0..<3 where x[i] != y[i] { return x[i] > y[i] }
        return false
    }

    #if os(iOS)
    func openReleasePage() { UIApplication.shared.open(manifest?.notesUrl ?? Self.releasesURL) }
    #endif

    #if os(macOS)
    /// 내려받기 → 검증 → 교체 스크립트 실행 → 종료
    func installMac() async {
        guard let manifest, let asset = manifest.platforms["mac"] else { return }
        phase = .downloading
        do {
            let (tmp, response) = try await URLSession.shared.download(from: asset.url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            let data = try Data(contentsOf: tmp, options: .mappedIfSafe)
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard digest.caseInsensitiveCompare(asset.sha256) == .orderedSame else {
                throw NSError(domain: "아나", code: 1, userInfo: [NSLocalizedDescriptionKey: "SHA-256이 일치하지 않습니다."])
            }
            let work = FileManager.default.temporaryDirectory.appendingPathComponent("Ahna-update-\(manifest.version)", isDirectory: true)
            try? FileManager.default.removeItem(at: work)
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let zip = work.appendingPathComponent("Ahna.zip")
            try FileManager.default.moveItem(at: tmp, to: zip)
            try run("/usr/bin/ditto", ["-x", "-k", zip.path, work.path])
            guard let newApp = try FileManager.default.contentsOfDirectory(at: work, includingPropertiesForKeys: nil)
                .first(where: { $0.pathExtension == "app" }) else {
                throw NSError(domain: "아나", code: 2, userInfo: [NSLocalizedDescriptionKey: "패키지에 .app이 없습니다."])
            }
            let target = Bundle.main.bundleURL
            let script = work.appendingPathComponent("apply.sh")
            let body = """
            #!/bin/bash
            set -e
            PID=\(ProcessInfo.processInfo.processIdentifier)
            for i in $(seq 1 60); do kill -0 $PID 2>/dev/null || break; sleep 1; done
            TARGET=\(shellQuote(target.path))
            NEW=\(shellQuote(newApp.path))
            BACKUP="${TARGET%.app}-backup-$(date +%s).app"
            trap '/usr/bin/open "$TARGET" 2>/dev/null || /usr/bin/open "$BACKUP"' EXIT
            mv "$TARGET" "$BACKUP"
            if /usr/bin/ditto "$NEW" "$TARGET"; then
              /usr/bin/xattr -dr com.apple.quarantine "$TARGET" 2>/dev/null || true
              rm -rf "$BACKUP"
            else
              rm -rf "$TARGET"; mv "$BACKUP" "$TARGET"
            fi
            """
            try body.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/bash")
            p.arguments = [script.path]
            try p.run()
            NSApp.terminate(nil)
        } catch {
            phase = .failed("업데이트 설치 실패: \(error.localizedDescription)")
        }
    }

    private func run(_ tool: String, _ args: [String]) throws {
        let p = Process(); p.executableURL = URL(fileURLWithPath: tool); p.arguments = args
        try p.run(); p.waitUntilExit()
        if p.terminationStatus != 0 { throw NSError(domain: "아나", code: Int(p.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "\(tool) 실패"]) }
    }
    private func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    #endif
}

/// 새 버전이 있을 때만 보이는 배너
struct UpdateBanner: View {
    @ObservedObject var updater: AppUpdater
    var body: some View {
        switch updater.phase {
        case .available(let version):
            VStack(alignment: .leading, spacing: 8) {
                Label("새 버전 v\(version)이 있습니다 (현재 v\(AppUpdater.currentVersion))", systemImage: "arrow.down.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AhnaPalette.accent)
                #if os(macOS)
                Button("지금 설치하고 다시 시작") { Task { await updater.installMac() } }
                #else
                Button("새 IPA 받기") { updater.openReleasePage() }
                    .buttonStyle(.bordered)
                Text("받은 IPA를 기존 앱 위에 같은 Apple 계정으로 설치하세요. 설정과 연결은 유지됩니다.")
                    .font(.footnote).foregroundStyle(.secondary)
                #endif
            }
            .padding(.vertical, 4)
        case .downloading:
            Label("업데이트 내려받는 중…", systemImage: "arrow.down.circle").foregroundStyle(.secondary)
        case .failed(let message):
            Text(message).font(.footnote).foregroundStyle(.red)
        default:
            EmptyView()
        }
    }
}
