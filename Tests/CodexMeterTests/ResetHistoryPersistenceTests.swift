import Foundation
import Testing
@testable import CodexMeter

@MainActor
struct ResetHistoryPersistenceTests {
    private let now = Date(timeIntervalSince1970: 1_791_000_000)
    private func directory() throws -> URL {
        let path = TestFixtureDirectory.root.appendingPathComponent("reset-archive-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        return path
    }
    private func context(account: String = "A", directory: String = "one", since: Date = .distantPast) -> CodexDataContext {
        CodexDataContext(source: CodexDataSource(root: URL(fileURLWithPath: "/synthetic/\(directory)/.codex")),
                         accountIdentity: account, since: since)
    }
    private actor Loader {
        let reply: [ResetHistoryEvent]
        let timeout: Bool
        var calls = 0
        var received: [ResetHistoryEvent] = []
        init(_ reply: [ResetHistoryEvent], timeout: Bool = false) { self.reply = reply; self.timeout = timeout }
        func load(_ known: [ResetHistoryEvent]) throws -> [ResetHistoryEvent] {
            calls += 1
            received = known
            if timeout { throw URLError(.timedOut) }
            return reply
        }
    }

    @Test func relaunchRestoresBeforeNetworkAndMergesNewAndUpdatedIDs() async throws {
        let root = try directory()
        let account = context()
        let old = ResetHistoryEvent(id: "old", kind: "granted", occurredAt: now)
        let first = ResetHistoryStore(loader: { _, _ in [old] }, archiveDirectory: root, clock: { now })
        await first.refresh(context: account)
        #expect(first.hasSavedHistory)

        let newer = ResetHistoryEvent(id: "new", kind: "granted", occurredAt: now.addingTimeInterval(60))
        let updated = ResetHistoryEvent(id: "old", kind: "used", occurredAt: now)
        let loader = Loader([newer, updated, newer])
        let later = now.addingTimeInterval(301)
        let second = ResetHistoryStore(loader: { _, known in try await loader.load(known) }, archiveDirectory: root, clock: { later })
        second.synchronize(context: account)
        #expect(second.events == [old] && second.hasSavedHistory)
        #expect(await loader.calls == 0)
        await second.refresh(context: account)
        #expect(await loader.received == [old])
        #expect(second.events == [newer, updated] && second.hasSavedHistory)

        let unused = Loader([], timeout: true)
        let third = ResetHistoryStore(loader: { _, known in try await unused.load(known) }, archiveDirectory: root, clock: { later })
        await third.refresh(context: account)
        #expect(third.events == [newer, updated])
        #expect(await unused.calls == 0)
    }

    @Test func durableHistoryIsIsolatedButSurvivesSameAccountLoginBoundary() async throws {
        let root = try directory()
        let account = context()
        let event = ResetHistoryEvent(id: "private-A", kind: "used", occurredAt: now)
        let history = ResetHistoryStore(loader: { _, _ in [event] }, archiveDirectory: root, clock: { now })
        await history.refresh(context: account)
        for other in [context(account: "B"), context(directory: "two")] {
            history.synchronize(context: other)
            #expect(history.events.isEmpty && !history.hasLoaded && !history.hasSavedHistory)
        }
        history.synchronize(context: nil)
        #expect(history.events.isEmpty)
        let renewed = context(since: now)
        #expect(renewed.id != account.id)
        history.synchronize(context: renewed)
        #expect(history.events == [event] && history.hasSavedHistory)
        let file = ResetHistoryArchive(directory: root).file(for: try #require(ResetHistoryArchive.partition(for: account)))
        let json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        #expect(Set(json.keys) == ["version", "partition", "events", "checkedAt"])
        let permissions = try #require(FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)
        #expect(permissions.intValue & 0o777 == 0o600)
    }

    @Test func timeoutLeavesDurableRecordsAndLastSuccessfulTimeUnchanged() async throws {
        let root = try directory()
        let account = context()
        let event = ResetHistoryEvent(id: "saved", kind: "used", occurredAt: now)
        let first = ResetHistoryStore(loader: { _, _ in [event] }, archiveDirectory: root, clock: { now })
        await first.refresh(context: account)
        let failing = Loader([], timeout: true)
        let second = ResetHistoryStore(loader: { _, known in try await failing.load(known) }, archiveDirectory: root,
                                       clock: { now.addingTimeInterval(301) })
        await second.refresh(context: account)
        #expect(second.events == [event] && second.hasSavedHistory && !second.isLoading)
        #expect(second.loadedAt == now)
        #expect(second.error?.contains("已保留本地历史") == true)
        let partition = try #require(ResetHistoryArchive.partition(for: account))
        let saved = try ResetHistoryArchive(directory: root).load(partition: partition)
        let snapshot = try #require(saved)
        #expect(snapshot.events == [event] && snapshot.checkedAt == now)
    }

    @Test func corruptArchiveCanRecoverAndSaveFailureNeverClaimsPersistence() async throws {
        let root = try directory()
        let account = context()
        let archive = ResetHistoryArchive(directory: root)
        let file = archive.file(for: try #require(ResetHistoryArchive.partition(for: account)))
        try Data("corrupt".utf8).write(to: file)
        let event = ResetHistoryEvent(id: "recovered", kind: "used", occurredAt: now)
        let history = ResetHistoryStore(loader: { _, _ in [event] }, archiveDirectory: root, clock: { now })
        history.synchronize(context: account)
        #expect(!history.hasLoaded && history.persistenceWarning != nil)
        await history.refresh(context: account)
        #expect(history.events == [event] && history.hasSavedHistory && history.persistenceWarning == nil)
        let blocked = root.appendingPathComponent("file-not-directory")
        try Data().write(to: blocked)
        let unsaved = ResetHistoryStore(loader: { _, _ in [event] }, archiveDirectory: blocked, clock: { now })
        await unsaved.refresh(context: account)
        #expect(unsaved.hasLoaded && unsaved.events == [event] && !unsaved.hasSavedHistory)
        #expect(unsaved.persistenceWarning != nil)
    }
}
