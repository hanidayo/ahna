import Foundation
import UniformTypeIdentifiers

enum SharedItemCopy {
    static func copy(_ provider: NSItemProvider, to directory: URL) async throws -> URL {
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            return try await withCheckedThrowingContinuation { continuation in
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                    do {
                        let url: URL?
                        if let value = item as? URL { url = value }
                        else if let data = item as? Data { url = URL(dataRepresentation: data, relativeTo: nil) }
                        else { url = nil }
                        guard let source = url, source.isFileURL else { throw error ?? CocoaError(.fileReadUnknown) }
                        let access = source.startAccessingSecurityScopedResource(); defer { if access { source.stopAccessingSecurityScopedResource() } }
                        let target = directory.appendingPathComponent(source.lastPathComponent)
                        try FileManager.default.copyItem(at: source, to: target); continuation.resume(returning: target)
                    } catch { continuation.resume(throwing: error) }
                }
            }
        }
        if let type = provider.registeredTypeIdentifiers.first(where: { UTType($0)?.conforms(to: .data) == true && UTType($0)?.conforms(to: .text) != true && UTType($0)?.conforms(to: .url) != true }) {
            return try await withCheckedThrowingContinuation { continuation in
                provider.loadFileRepresentation(forTypeIdentifier: type) { source, error in
                    do {
                        guard let source else { throw error ?? CocoaError(.fileReadUnknown) }
                        let target = directory.appendingPathComponent(source.lastPathComponent)
                        try FileManager.default.copyItem(at: source, to: target); continuation.resume(returning: target)
                    } catch { continuation.resume(throwing: error) }
                }
            }
        }
        let isURL = provider.hasItemConformingToTypeIdentifier(UTType.url.identifier)
        let type = isURL ? UTType.url.identifier : UTType.plainText.identifier
        return try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(forTypeIdentifier: type, options: nil) { item, error in
                do {
                    let target = directory.appendingPathComponent(isURL ? "공유한 링크.webloc" : "공유한 텍스트.txt")
                    if isURL {
                        let url: URL?
                        if let value = item as? URL { url = value }
                        else if let text = item as? String { url = URL(string: text) }
                        else if let data = item as? Data, let text = String(data: data, encoding: .utf8) { url = URL(string: text) }
                        else { url = nil }
                        guard let url, url.scheme != nil, !url.isFileURL else { throw CocoaError(.fileReadUnknown) }
                        try PropertyListSerialization.data(fromPropertyList: ["URL":url.absoluteString], format: .xml, options: 0).write(to: target)
                    } else if let text = item as? String { try text.write(to: target, atomically: true, encoding: .utf8) }
                    else if let data = item as? Data { try data.write(to: target) }
                    else { throw error ?? CocoaError(.fileReadUnknown) }
                    continuation.resume(returning: target)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
}
