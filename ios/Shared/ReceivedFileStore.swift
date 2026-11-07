import Foundation

// File contents belong in Documents; pairing and receipt metadata stay private.
final class ReceivedFileStore {
    struct Receipt: Codable {
        let name: String
        let bytes: Int64
        var photosSaved: Bool? = nil
        var acknowledgedStatus: String? = nil
    }
    let directory: URL
    private let ledger: URL
    private var receipts: [String: Receipt]
    private let manager = FileManager.default

    init(directory: URL, metadata: URL) throws {
        self.directory = directory
        self.ledger = metadata.appendingPathComponent("received-files.json")
        self.receipts = [:]
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        try manager.createDirectory(at: metadata, withIntermediateDirectories: true)
        if manager.fileExists(atPath: ledger.path) {
            receipts = try JSONDecoder().decode([String: Receipt].self, from: Data(contentsOf: ledger))
        } else {
            receipts = [:]
        }
    }

    func hasReceived(_ key: String) -> Bool { receipts[key] != nil }
    func photosSaved(_ key: String) -> Bool { receipts[key]?.photosSaved == true }
    func acknowledgedStatus(_ key: String) -> String? { receipts[key]?.acknowledgedStatus }
    func markPhotosSaved(_ key: String) throws { receipts[key]?.photosSaved = true; try persist() }
    func markAcknowledged(_ key: String, status: String) throws { receipts[key]?.acknowledgedStatus = status; try persist() }
    private func persist() throws { try JSONEncoder().encode(receipts).write(to: ledger, options: .atomic) }

    func savedURL(for key: String) -> URL? {
        guard let receipt = receipts[key], Self.validName(receipt.name) else { return nil }
        let url = directory.appendingPathComponent(receipt.name)
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true, values.isSymbolicLink != true else { return nil }
        return url
    }

    @discardableResult
    func save(temporary: URL, name: String, bytes: Int64, key: String) throws -> URL {
        guard Self.validName(name), (0...Int64(4 * 1024 * 1024 * 1024)).contains(bytes) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        let attributes = try manager.attributesOfItem(atPath: temporary.path)
        guard (attributes[.size] as? NSNumber)?.int64Value == bytes else {
            throw CocoaError(.fileReadCorruptFile)
        }
        if let previous = savedURL(for: key) { return previous }
        let original = directory.appendingPathComponent(name)
        var destination = original
        var suffix = 0
        while manager.fileExists(atPath: destination.path) {
            suffix += 1
            let ext = original.pathExtension
            let base = ext.isEmpty ? name : original.deletingPathExtension().lastPathComponent
            destination = directory.appendingPathComponent(base + " (\(suffix))" + (ext.isEmpty ? "" : "." + ext))
        }
        // Move only a completed, size-checked download; never overwrite a received file.
        try manager.moveItem(at: temporary, to: destination)
        receipts[key] = Receipt(name: destination.lastPathComponent, bytes: bytes)
        try persist()
        return destination
    }

    private static func validName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\\") && !name.contains("\0")
    }
}
