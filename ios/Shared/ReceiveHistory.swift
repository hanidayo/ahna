import Foundation
import Combine
@MainActor final class ReceiveHistory: ObservableObject {
    struct Entry: Codable, Identifiable { var id: String; var name: String; var source: String; var url: URL; var received: Date }
    static let shared = ReceiveHistory()
    @Published private(set) var entries: [Entry]
    private let defaults: UserDefaults
    private var seen: [String]
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        entries = Array((defaults.data(forKey: "receivedHistory060").flatMap { try? JSONDecoder().decode([Entry].self, from: $0) } ?? []).prefix(10))
        seen = defaults.stringArray(forKey: "receivedHistorySeen060") ?? []
    }
    func record(id: String, url: URL, source: String) {
        guard !seen.contains(id) else { return }
        seen.append(id); if seen.count > 512 { seen.removeFirst(seen.count - 512) }
        entries.insert(Entry(id: id, name: url.lastPathComponent, source: source, url: url, received: Date()), at: 0)
        let bytes = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        TransferLog.shared.record(sent: false, name: url.lastPathComponent, device: source, bytes: bytes)
        entries = Array(entries.prefix(10)); persist()
    }
    func clear() { entries.removeAll(); persist() }
    private func persist() {
        if let data = try? JSONEncoder().encode(entries) { defaults.set(data, forKey: "receivedHistory060") }
        defaults.set(seen, forKey: "receivedHistorySeen060")
    }
}

/// 전송 기록: 이 기기에서 보내고 받은 파일·글자 (최근 30개)
@MainActor final class TransferLog: ObservableObject {
    struct Entry: Codable, Identifiable { var id: String; var at: Date; var sent: Bool; var name: String; var device: String; var bytes: Int64; var preview: String? }
    static let shared = TransferLog()
    @Published private(set) var entries: [Entry]
    private let defaults = UserDefaults.standard
    private var seen: [String]
    init() {
        entries = Array((defaults.data(forKey: "transferLog") .flatMap { try? JSONDecoder().decode([Entry].self, from: $0) } ?? []).prefix(30))
        seen = defaults.stringArray(forKey: "transferLogSeen") ?? []
    }
    /// 글자 미리보기(한 줄, 앞 80자)
    nonisolated static func preview(_ text: String) -> String {
        let line = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        return line.count > 80 ? String(line.prefix(80)) + "…" : line
    }
    /// key: 같은 일을 두 번 적지 않도록(예: 받은 글자 ID)
    func record(sent: Bool, name: String, device: String, bytes: Int64, preview: String? = nil, key: String? = nil) {
        if let key { guard !seen.contains(key) else { return }; seen.append(key); if seen.count > 512 { seen.removeFirst(seen.count - 512) } }
        entries.insert(Entry(id: UUID().uuidString, at: Date(), sent: sent, name: name, device: device, bytes: bytes, preview: preview), at: 0)
        entries = Array(entries.prefix(30)); persist()
    }
    func seenKey(_ key: String) -> Bool { seen.contains(key) }
    func clear() { entries.removeAll(); persist() }
    private func persist() {
        if let data = try? JSONEncoder().encode(entries) { defaults.set(data, forKey: "transferLog") }
        defaults.set(seen, forKey: "transferLogSeen")
    }
}
