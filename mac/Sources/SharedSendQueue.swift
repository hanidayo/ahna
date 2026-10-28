import Foundation
import AppKit

@MainActor final class SharedSendQueue: ObservableObject {
    static let shared = SharedSendQueue()
    @Published private(set) var files: [PendingFile] = []
    @Published private(set) var error = ""
    private var scopes: [URL] = []
    func accept(_ urls: [URL]) {
        guard files.isEmpty else { error = "먼저 현재 공유 파일을 전송하거나 취소해 주세요. 새로 선택한 파일은 다시 공유해 주세요."; return }
        do {
            guard !urls.isEmpty, urls.allSatisfy(\.isFileURL) else { throw CocoaError(.fileReadUnsupportedScheme) }
            for url in urls { if url.startAccessingSecurityScopedResource() { scopes.append(url) } }
            files = try FilePreparation.collect(urls)
            guard !files.isEmpty else { throw CocoaError(.fileReadUnknown) }
            error = ""
        } catch { clear(); self.error = error.localizedDescription }
    }
    func clear() { for url in scopes { url.stopAccessingSecurityScopedResource() }; scopes = []; files = []; error = "" }
}
