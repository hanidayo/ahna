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
        entries = Array(entries.prefix(10)); persist()
    }
    func clear() { entries.removeAll(); persist() }
    private func persist() {
        if let data = try? JSONEncoder().encode(entries) { defaults.set(data, forKey: "receivedHistory060") }
        defaults.set(seen, forKey: "receivedHistorySeen060")
    }
}
