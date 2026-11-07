import Foundation

enum InstalledKeychainGroups {
    enum Failure: Error { case invalidSignature, noCommonGroup }
    static func parse(_ data: Data) throws -> [String] {
        func word(_ offset: Int, big: Bool = false) throws -> UInt32 {
            guard offset >= 0, offset <= data.count - 4 else { throw Failure.invalidSignature }
            let bytes = Array(data[offset..<offset+4])
            return big ? bytes.reduce(0) { ($0 << 8) | UInt32($1) }
                       : bytes.reversed().reduce(0) { ($0 << 8) | UInt32($1) }
        }
        guard try word(0) == 0xfeedfacf else { throw Failure.invalidSignature }
        let count = Int(try word(16)), commandBytes = Int(try word(20))
        guard commandBytes <= data.count - 32, count <= commandBytes / 8 else { throw Failure.invalidSignature }
        var offset = 32
        for _ in 0..<count {
            let command = try word(offset), size = Int(try word(offset+4))
            guard size >= 8, offset + size <= 32 + commandBytes else { throw Failure.invalidSignature }
            if command == 0x1d {
                guard size >= 16 else { throw Failure.invalidSignature }
                let start = Int(try word(offset+8)), length = Int(try word(offset+12))
                guard length >= 12, start <= data.count - length,
                      try word(start, big: true) == 0xfade0cc0 else { throw Failure.invalidSignature }
                let blobLength = Int(try word(start+4, big: true))
                let slots = Int(try word(start+8, big: true))
                guard blobLength <= length, blobLength >= 12, slots <= (blobLength-12)/8 else { throw Failure.invalidSignature }
                for i in 0..<slots {
                    let entry = start+12+i*8
                    if try word(entry, big: true) != 5 { continue }
                    let relative = Int(try word(entry+4, big: true))
                    guard relative >= 12+slots*8, relative <= blobLength-8 else { throw Failure.invalidSignature }
                    let blob = start+relative, n = Int(try word(blob+4, big: true))
                    guard try word(blob, big: true) == 0xfade7171, n >= 8, n <= blobLength-relative else { throw Failure.invalidSignature }
                    let plist = try PropertyListSerialization.propertyList(from: data.subdata(in: blob+8..<blob+n), format: nil)
                    guard let dict = plist as? [String: Any], let groups = dict["keychain-access-groups"] as? [String] else { throw Failure.invalidSignature }
                    return groups
                }
                throw Failure.invalidSignature
            }
            offset += size
        }
        throw Failure.invalidSignature
    }
    static func select(configured: String, groups: [String]) throws -> String {
        if groups.contains(configured) { return configured }
        let shared = groups.filter { $0.hasSuffix(".com.hanidayo.ahna.shared") }
        if shared.count == 1 { return shared[0] }
        // iLoader can sign both bundles with the profile's literal TEAM.* group.
        // Never use an arbitrary private default group: that splits settings.
        let common = groups.filter { group in
            let parts = group.split(separator: ".", omittingEmptySubsequences: false)
            return parts.count == 2 && parts[0].count == 10 && parts[1] == "*"
        }
        if common.count == 1 { return common[0] }
        throw Failure.noCommonGroup
    }
    static let resolved: Result<String, Error> = Result {
        guard let configured = Bundle.main.object(forInfoDictionaryKey: "AhnaKeychainGroup") as? String,
              !configured.isEmpty, !configured.contains("$("), let executable = Bundle.main.executableURL else { throw Failure.invalidSignature }
        return try select(configured: configured, groups: parse(Data(contentsOf: executable, options: .mappedIfSafe)))
    }
}
