import Foundation
import UniformTypeIdentifiers
@main struct ShareChecks {
    @MainActor static func main() async throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("share-check-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        var count = 0
        func check(_ valid: Bool, _ name: String) { precondition(valid, name); count += 1; print("PASS: " + name) }
        let source = root.appendingPathComponent("original.txt");try Data("original".utf8).write(to: source)
        let destination = root.appendingPathComponent("staging");try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        let fileProvider = NSItemProvider(item: source as NSURL, typeIdentifier: UTType.fileURL.identifier)
        let copied = try await SharedItemCopy.copy(fileProvider, to: destination)
        let bytes = try Data(contentsOf: copied)
        check(bytes == Data("original".utf8) && copied != source, "Shared file survives provider callback as an independent copy")
        let text = NSItemProvider(item: "선택한 텍스트" as NSString, typeIdentifier: UTType.plainText.identifier)
        let copiedText = try await SharedItemCopy.copy(text, to: destination)
        let contents = try String(contentsOf: copiedText, encoding: .utf8)
        check(contents == "선택한 텍스트", "Shared text becomes a sendable UTF-8 file")
        let web = NSItemProvider(item: URL(string: "https://example.com/test")! as NSURL, typeIdentifier: UTType.url.identifier)
        let copiedURL = try await SharedItemCopy.copy(web, to: destination)
        let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: copiedURL), format: nil) as? [String:String]
        check(plist?["URL"] == "https://example.com/test", "Shared browser URL becomes a valid webloc")
        let queue = SharedSendQueue.shared
        queue.accept([copied, copiedText])
        check(queue.files.count == 2, "Containing app receives a multi-file share")
        queue.accept([source])
        check(queue.files.count == 2 && !queue.error.isEmpty, "A second share cannot overwrite pending files")
        queue.clear();check(queue.files.isEmpty && queue.error.isEmpty, "Cancel clears pending share")
        let folder = root.appendingPathComponent("folder");try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("nested".utf8).write(to: folder.appendingPathComponent("nested.txt"))
        queue.accept([folder]);check(queue.files.count == 1 && queue.files[0].path == "folder/nested.txt", "Shared folders retain relative paths")
        queue.clear();queue.accept([URL(string:"https://example.com")!])
        check(queue.files.isEmpty && !queue.error.isEmpty, "Raw external URLs cannot become arbitrary file requests")
        queue.clear();print("\(count) sharing checks passed")
    }
}
