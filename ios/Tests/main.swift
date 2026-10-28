import Foundation

var checks = 0
func check(_ value: Bool, _ message: String) {
    guard value else { fatalError(message) }
    checks += 1
    print("PASS: \(message)")
}
func mustReject(_ message: String, _ operation: () throws -> Void) {
    do { try operation(); fatalError("Accepted invalid input: \(message)") }
    catch { check(true, message) }
}
let manager = FileManager.default
let root = manager.temporaryDirectory.appendingPathComponent("ahna-store-test-" + UUID().uuidString, isDirectory: true)
let documents = root.appendingPathComponent("Documents", isDirectory: true)
let metadata = root.appendingPathComponent("ApplicationSupport", isDirectory: true)
try manager.createDirectory(at: root, withIntermediateDirectories: true)
defer {
    if root.lastPathComponent.hasPrefix("ahna-store-test-"), root.deletingLastPathComponent().standardizedFileURL == manager.temporaryDirectory.standardizedFileURL { try? manager.removeItem(at: root) }
}
func temporary(_ text: String) throws -> URL {
    let url = root.appendingPathComponent(UUID().uuidString)
    try Data(text.utf8).write(to: url)
    return url
}
let store = try ReceivedFileStore(directory: documents, metadata: metadata)
let first = try store.save(temporary: temporary("abc"), name: "한글.txt", bytes: 3, key: "server|session|1")
check(first.deletingLastPathComponent() == documents, "Files saved directly to Documents without a transfer folder")
check(try String(contentsOf: first, encoding: .utf8) == "abc", "Received contents preserved")
let second = try store.save(temporary: temporary("def"), name: "한글.txt", bytes: 3, key: "server|session|2")
check(second.lastPathComponent == "한글 (1).txt", "Duplicate filename gets a suffix")
check(try String(contentsOf: first, encoding: .utf8) == "abc", "Duplicate never overwrites the original")
let again = try store.save(temporary: temporary("abc"), name: "한글.txt", bytes: 3, key: "server|session|1")
check(again == first, "Same transfer is not stored twice")
let restored = try ReceivedFileStore(directory: documents, metadata: metadata)
check(restored.hasReceived("server|session|1") && restored.savedURL(for: "server|session|1") == first, "Receipt restored after restart")
try store.markPhotosSaved("server|session|1")
try store.markAcknowledged("server|session|1", status: "photos")
let photosRestored = try ReceivedFileStore(directory: documents, metadata: metadata)
check(photosRestored.photosSaved("server|session|1"), "Photos receipt persists to prevent repeat imports")
check(photosRestored.acknowledgedStatus("server|session|1") == "photos", "Windows confirmation receipt persists")
mustReject("Traversal path rejected") { _ = try store.save(temporary: temporary("abc"), name: "../escape.txt", bytes: 3, key: "bad1") }
mustReject("Backslash path rejected") { _ = try store.save(temporary: temporary("abc"), name: "a\\b", bytes: 3, key: "bad2") }
mustReject("Incomplete download rejected") { _ = try store.save(temporary: temporary("ab"), name: "partial.txt", bytes: 3, key: "bad3") }
check(!manager.fileExists(atPath: documents.appendingPathComponent("partial.txt").path), "Partial download not published")
let empty = try store.save(temporary: temporary(""), name: "empty", bytes: 0, key: "empty")
check(manager.fileExists(atPath: empty.path), "Zero byte file saved")
let emptyAgain = try store.save(temporary: temporary(""), name: "empty", bytes: 0, key: "empty2")
check(emptyAgain.lastPathComponent == "empty (1)", "Duplicate file without extension preserved")
try manager.removeItem(at: first)
check(restored.hasReceived("server|session|1") && restored.savedURL(for: "server|session|1") == nil, "User-deleted file keeps receipt without being automatically downloaded again")
check(!manager.fileExists(atPath: documents.appendingPathComponent("received-files.json").path), "Private receipt metadata kept outside Files-visible Documents")
print("\(checks) storage checks passed")
