import Foundation
import Combine

@MainActor final class BackgroundPolling {
    private let client: AhnaClient
    private var subscription: AnyCancellable?
    private var polling: Task<Void, Never>?
    private var revision = 0
    private(set) var started = false
    init(client: AhnaClient) { self.client = client }
    func start() {
        guard !started else { return }
        started = true
        subscription = client.$connections.map { $0.map(\.id) }.removeDuplicates().sink { [weak self] _ in
            guard let self else { return }
            self.revision += 1
            let current = self.revision
            Task { @MainActor [weak self] in
                guard let self, self.started, current == self.revision else { return }
                self.polling?.cancel()
                self.polling = Task { [weak self] in guard let self else { return }; await self.client.poll() }
            }
        }
    }
    func stop() { started = false; revision += 1; subscription = nil; polling?.cancel(); polling = nil }
}
