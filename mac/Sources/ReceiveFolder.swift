import Foundation
import CryptoKit

enum ReceiveFolder {
    static let preferenceKey = "receivedFolderPath"
    static func currentURL(defaults: UserDefaults = .standard) -> URL {
        if let path = defaults.string(forKey: preferenceKey), !path.isEmpty { return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads/Ahna", isDirectory: true)
    }
    static func validate(_ url: URL) throws {
        let manager = FileManager.default
        var directory: ObjCBool = false
        guard manager.fileExists(atPath: url.path, isDirectory: &directory), directory.boolValue else {
            throw NSError(domain: "Ahna.Folder", code: 1, userInfo: [NSLocalizedDescriptionKey: "수신 폴더에 접근할 수 없습니다. 드라이브 연결과 폴더 경로를 확인하세요."])
        }
        let probe = url.appendingPathComponent(".ahna-write-test-" + UUID().uuidString)
        defer { try? manager.removeItem(at: probe) }
        try Data().write(to: probe, options: .withoutOverwriting)
    }
    static func choose(_ url: URL, defaults: UserDefaults = .standard) throws {
        try validate(url)
        defaults.set(url.standardizedFileURL.path, forKey: preferenceKey)
    }
    static func metadataURL(for directory: URL, support: URL? = nil) throws -> URL {
        let base = try support ?? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let key = SHA256.hash(data: Data(directory.standardizedFileURL.path.utf8)).map { String(format: "%02x", $0) }.joined()
        return base.appendingPathComponent("AhnaMac/Receipts/" + key, isDirectory: true)
    }
    static func prepare(_ url: URL, isDefault: Bool) throws {
        if isDefault { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        try validate(url)
    }
}
