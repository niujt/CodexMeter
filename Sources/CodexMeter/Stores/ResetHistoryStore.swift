import Foundation
import Observation

/// Shared across page visits, with durable history isolated by directory and account identity.
@MainActor
@Observable
final class ResetHistoryStore {
    typealias Loader = @Sendable (CodexDataContext, [ResetHistoryEvent]) async throws -> [ResetHistoryEvent]
    static let cacheLifetime: TimeInterval = 5 * 60

    private(set) var events: [ResetHistoryEvent] = []
    private(set) var isLoading = false
    private(set) var hasLoaded = false
    private(set) var error: String?
    private(set) var loadedAt: Date?
    private(set) var hasSavedHistory = false
    private(set) var persistenceWarning: String?
    @ObservationIgnored private var contextID: String?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private let loader: Loader
    @ObservationIgnored private let clock: () -> Date
    @ObservationIgnored private let archive: ResetHistoryArchive?
    @ObservationIgnored private var partition: String?

    init(loader: @escaping Loader = { try await ResetHistoryClient().load(context: $0, knownEvents: $1) },
         archiveDirectory: URL? = nil,
         clock: @escaping () -> Date = { .now }) {
        self.loader = loader
        self.clock = clock
        archive = archiveDirectory.map { ResetHistoryArchive(directory: $0) }
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
        hasSavedHistory = false
        error = nil
        persistenceWarning = nil
        partition = context.flatMap(ResetHistoryArchive.partition(for:))
        if let archive, let partition {
            do {
                if let saved = try archive.load(partition: partition) {
                    events = ResetHistoryClient.sorted(saved.events)
                    loadedAt = saved.checkedAt
                    hasLoaded = true
                    hasSavedHistory = true
                }
            } catch {
                persistenceWarning = "本地历史暂时无法读取，将重新同步。"
            }
        }
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
        let knownEvents = events
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
                let loaded = try await loader(context, knownEvents)
                guard let self, self.generation == request, !Task.isCancelled else { return }
                var merged = Dictionary(knownEvents.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
                for event in loaded { merged[event.id] = event }
                self.events = ResetHistoryClient.sorted(merged.values)
                self.hasLoaded = true
                self.loadedAt = self.clock()
                self.hasSavedHistory = false
                if let archive = self.archive, let partition = self.partition, let checkedAt = self.loadedAt {
                    do {
                        try archive.save(events: self.events, checkedAt: checkedAt, partition: partition)
                        self.persistenceWarning = nil
                        self.hasSavedHistory = true
                    } catch {
                        self.persistenceWarning = "记录已读取，但本地保存失败；请检查应用数据目录是否可写。"
                    }
                }
            } catch {
                guard let self, self.generation == request, !Task.isCancelled else { return }
                if (error as? URLError)?.code == .timedOut {
                    self.error = self.hasLoaded ? "同步超时，已保留本地历史，稍后可刷新重试。" : "读取超时，请稍后刷新重试。"
                } else {
                    self.error = self.hasLoaded ? "同步失败，已保留本地历史：\(error.localizedDescription)" : error.localizedDescription
                }
            }
        }
        loadTask = task
        await task.value
    }
}
