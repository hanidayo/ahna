import Foundation

@main struct CacheChecks {
    struct Settings: Equatable { var connections: [String]; var name: String }
    enum Denied: Error { case access }
    static func main() throws {
        var count = 0
        func check(_ ok: Bool, _ label: String) { precondition(ok, label); count += 1; print("PASS: " + label) }
        let original = Settings(connections: ["existing-A", "existing-B"], name: "Existing Mac")
        var disk = original; var reads = 0; var writes = 0
        let cache = ConfigurationCache<Settings>(read: { reads += 1; return disk }, write: { writes += 1; disk = $0 })
        for _ in 0..<1000 { _ = try cache.value(); try cache.update(default: original) { $0.connections = original.connections } }
        check(reads == 1 && writes == 0, "1000 unchanged polls cause one initial read and zero writes")
        try cache.update(default: original) { $0.connections.append("new-C") }
        check(reads == 1 && writes == 1 && disk.name == original.name, "A real connection change saves once and preserves the device name")
        try cache.update(default: original) { $0.name = "Renamed Mac" }
        check(writes == 2 && disk.connections.count == 3, "Renaming preserves all existing connections")
        let cached = try cache.value()
        check(cached == disk && reads == 1, "Successful writes update the in-memory snapshot")
        var deniedReads = 0
        let denied = ConfigurationCache<Settings>(read: { deniedReads += 1; throw Denied.access }, write: { _ in preconditionFailure() })
        for _ in 0..<1000 { do { _ = try denied.value(); preconditionFailure() } catch {} }
        check(deniedReads == 1, "Denied reads never automatically request another password")
        var deniedWrites = 0
        let locked = ConfigurationCache<Settings>(read: { original }, write: { _ in deniedWrites += 1; throw Denied.access })
        for _ in 0..<1000 { do { try locked.update(default: original) { $0.name = "Changed" }; preconditionFailure() } catch {} }
        check(deniedWrites == 1, "Denied saves never become a repeated prompt loop")
        let retained = try locked.value()
        check(retained == original, "Failed writes retain the previous connection and name snapshot")
        cache.invalidate(); _ = try cache.value()
        check(reads == 2, "A new explicit share operation can reload changed app settings")
        let concurrent = ConfigurationCache<Settings>(read: { reads += 1; Thread.sleep(forTimeInterval: 0.005); return original }, write: { _ in })
        let before = reads
        DispatchQueue.concurrentPerform(iterations: 100) { _ in _ = try! concurrent.value() }
        check(reads == before + 1, "Concurrent consumers share one serialized initial read")
        var missingReads = 0; var created = 0
        let missing = ConfigurationCache<Settings>(read: { missingReads += 1; return nil }, write: { _ in created += 1 })
        for _ in 0..<100 { _ = try missing.value() }
        try missing.update(default: original) { _ in }
        check(missingReads == 1 && created == 1, "Missing configuration is cached and can be migrated exactly once")
        print("\(count) configuration cache checks passed")
    }
}
