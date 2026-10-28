import Foundation

// A process-local snapshot only. Secrets stay in Keychain on disk.
// Serialize the initial read so concurrent users cannot queue duplicate prompts.
final class ConfigurationCache<Value: Equatable> {
    private let lock = NSRecursiveLock()
    private let read: () throws -> Value?
    private let write: (Value) throws -> Void
    private var snapshot: Result<Value?, Error>?
    private var writeFailure: Error?
    init(read: @escaping () throws -> Value?, write: @escaping (Value) throws -> Void) {
        self.read = read; self.write = write
    }
    func value() throws -> Value? {
        lock.lock(); defer { lock.unlock() }
        if snapshot == nil { snapshot = Result { try read() } }
        return try snapshot!.get()
    }
    func update(default initial: Value, _ change: (inout Value) -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        let previous = try value()
        var next = previous ?? initial; change(&next)
        guard previous != next else { return }
        // A denied save must not become a new password prompt on every poll.
        if let writeFailure { throw writeFailure }
        do { try write(next); snapshot = .success(next) }
        catch { writeFailure = error; throw error }
    }
    // Used only when the user opens a new share operation, to see app changes.
    func invalidate() {
        lock.lock(); defer { lock.unlock() }
        snapshot = nil; writeFailure = nil
    }
}
