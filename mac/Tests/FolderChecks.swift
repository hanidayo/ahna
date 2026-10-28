import Foundation
@main struct FolderChecks {
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("ahna-folder-tests-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let suite = "AhnaFolderTests-" + UUID().uuidString
        let prefs = UserDefaults(suiteName: suite)!
        defer { prefs.removePersistentDomain(forName: suite) }
        let a = root.appendingPathComponent("A"), b = root.appendingPathComponent("B")
        for url in [a,b] { try fm.createDirectory(at: url, withIntermediateDirectories: true) }
        var count = 0
        func check(_ condition: Bool, _ message: String) { precondition(condition, message); count += 1; print("PASS: " + message) }
        func rejects(_ message: String, operation: () throws -> Void) {
            do { try operation(); fatalError(message) } catch { check(true, message) }
        }
        try ReceiveFolder.choose(a, defaults: prefs)
        check(ReceiveFolder.currentURL(defaults: prefs).path == a.path, "Folder selection persists in preferences")
        check(ReceiveFolder.currentURL(defaults: UserDefaults(suiteName: suite)!).path == a.path, "A fresh preferences reader restores selection")
        let metadataA = try ReceiveFolder.metadataURL(for: a, support: root)
        let metadataB = try ReceiveFolder.metadataURL(for: b, support: root)
        check(metadataA != metadataB, "Each destination keeps a separate receipt ledger")
        func save(_ directory: URL, metadata: URL, text: String) throws -> URL {
            let source = root.appendingPathComponent(UUID().uuidString)
            try Data(text.utf8).write(to: source)
            return try ReceivedFileStore(directory: directory, metadata: metadata).save(temporary: source, name: "same.txt", bytes: Int64(text.utf8.count), key: "server-file-1")
        }
        let savedA = try save(a, metadata: metadataA, text: "first")
        try ReceiveFolder.choose(b, defaults: prefs)
        let savedB = try save(ReceiveFolder.currentURL(defaults: prefs), metadata: metadataB, text: "second")
        let contentsA = try String(contentsOf: savedA), contentsB = try String(contentsOf: savedB)
        check(contentsA == "first" && contentsB == "second", "New receipts go to the chosen folder without moving old files")
        let restored = try ReceivedFileStore(directory: a, metadata: metadataA)
        check(restored.savedURL(for: "server-file-1") == savedA, "Returning to a folder restores its receipts")
        rejects("A file cannot be selected as a destination") { try ReceiveFolder.choose(savedA, defaults: prefs) }
        check(ReceiveFolder.currentURL(defaults: prefs).path == b.path, "Rejected selection preserves the previous destination")
        let missing = root.appendingPathComponent("disconnected-volume")
        rejects("Unavailable custom folder is not recreated or replaced") { try ReceiveFolder.prepare(missing, isDefault: false) }
        check(!fm.fileExists(atPath: missing.path), "No silent fallback or empty replacement folder")
        check((try fm.contentsOfDirectory(atPath: b.path)).allSatisfy { !$0.hasPrefix(".ahna-") }, "No staging or write-probe files remain")
        print("\(count) folder checks passed")
    }
}
