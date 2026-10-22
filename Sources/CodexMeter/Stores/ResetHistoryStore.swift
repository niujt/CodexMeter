import Foundation
import Observation

/// Shared across history-page visits; results never outlive the current login/directory scope.
@MainActor
@Observable
final class ResetHistoryStore {
    typealias Loader = @Sendable (CodexDataContext) async throws -> [ResetHistoryEvent]
    static let cacheLifetime: TimeInterval = 5 * 60

    private(set) var events: [ResetHistoryEvent] = []
    private(set) var isLoading = false
    private(set) var hasLoaded = false
    private(set) var error: String?
    private(set) var loadedAt: Date?
    @ObservationIgnored private var contextID: String?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private let loader: Loader
    @ObservationIgnored private let clock: () -> Date

    init(loader: @escaping Loader = { try await ResetHistoryClient().load(context: $0) },
         clock: @escaping () -> Date = { .now }) {
        self.loader = loader
        self.clock = clock
    }

    func synchronize(context: CodexDataContext?) {
        let nextID = context?.quotaScope?.id
        guard contextID != nextID else { return }
        loadTask?.cancel()
        loadTask = nil
        generation = UUID()
        contextID = nextID
        events = []
        isLoading = false
        hasLoaded = false
        loadedAt = nil
        error = nil
    }

    func refresh(context: CodexDataContext?, force: Bool = false) async {
        synchronize(context: context)
        guard let context, context.quotaScope != nil else { return }
        if let loadTask { await loadTask.value; return }
        if !force, let loadedAt {
            let age = clock().timeIntervalSince(loadedAt)
            if age >= 0 && age < Self.cacheLifetime { return }
        }

        let request = generation
        let loader = loader
        isLoading = true
        error = nil
        // The request belongs to the shared store, so leaving the page can still populate its cache.
        let task = Task { [weak self] in
            defer {
                if let self, self.generation == request {
                    self.isLoading = false
                    self.loadTask = nil
                }
            }
            do {
                let loaded = try await loader(context)
                guard let self, self.generation == request, !Task.isCancelled else { return }
                self.events = loaded
                self.hasLoaded = true
                self.loadedAt = self.clock()
            } catch {
                guard let self, self.generation == request, !Task.isCancelled else { return }
                self.error = error.localizedDescription
            }
        }
        loadTask = task
        await task.value
    }
}
