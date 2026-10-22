import Foundation
import Testing
@testable import CodexMeter

struct ResetHistoryTests {
    @MainActor private final class Clock {
        var now = Date(timeIntervalSince1970: 1_791_000_000)
    }

    private actor Loader {
        var calls = 0
        var fails = false
        func setFails(_ value: Bool) { fails = value }
        func load(_ context: CodexDataContext) throws -> [ResetHistoryEvent] {
            calls += 1
            if fails { throw ResetHistoryError.rejected(503) }
            return []
        }
    }

    private actor PendingLoader {
        private var pending: [CheckedContinuation<[ResetHistoryEvent], any Error>] = []
        private var started = 0
        private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
        func load(_ context: CodexDataContext) async throws -> [ResetHistoryEvent] {
            try await withCheckedThrowingContinuation { continuation in
                pending.append(continuation)
                started += 1
                let ready = waiters.filter { $0.0 <= started }
                waiters.removeAll { $0.0 <= started }
                ready.forEach { $0.1.resume() }
            }
        }
        func waitForCalls(_ count: Int) async {
            if started >= count { return }
            await withCheckedContinuation { waiters.append((count, $0)) }
        }
        func finishFirst(with events: [ResetHistoryEvent]) {
            pending.removeFirst().resume(returning: events)
        }
        var calls: Int { started }
    }

    private func context(account: String = "A", directory: String = "one") -> CodexDataContext {
        CodexDataContext(source: CodexDataSource(root: URL(fileURLWithPath: "/synthetic/\(directory)/.codex")),
                         accountIdentity: account, since: Date(timeIntervalSince1970: 1_790_000_000))
    }

    @Test @MainActor func cachesEmptyHistoryUntilExpiryAndManualRefreshBypassesCache() async {
        let clock = Clock()
        let loader = Loader()
        let history = ResetHistoryStore(loader: { context, _ in try await loader.load(context) }, clock: { clock.now })
        let account = context()
        await history.refresh(context: account)
        #expect(history.hasLoaded && history.events.isEmpty)
        clock.now += ResetHistoryStore.cacheLifetime - 1
        await history.refresh(context: account)
        #expect(await loader.calls == 1)
        await history.refresh(context: account, force: true)
        #expect(await loader.calls == 2)
        clock.now += ResetHistoryStore.cacheLifetime
        await history.refresh(context: account)
        #expect(await loader.calls == 3)
    }

    @Test @MainActor func accountDirectoryAndLogoutClearCachedHistory() async {
        let event = ResetHistoryEvent(id: "grant", kind: "granted", occurredAt: .now)
        let history = ResetHistoryStore(loader: { _, _ in [event] })
        let original = context()
        for changed in [context(account: "B"), context(directory: "two")] {
            await history.refresh(context: original)
            #expect(history.events == [event])
            history.synchronize(context: changed)
            #expect(history.events.isEmpty && !history.hasLoaded && history.loadedAt == nil)
        }
        await history.refresh(context: original)
        history.synchronize(context: nil)
        #expect(history.events.isEmpty && !history.hasLoaded)
        await history.refresh(context: nil)
        #expect(!history.isLoading && history.error == nil)
    }

    @Test @MainActor func lateResponseCannotRepopulateCacheAfterSwitchingAwayAndBack() async {
        let loader = PendingLoader()
        let history = ResetHistoryStore(loader: { context, _ in try await loader.load(context) })
        let original = context()
        let first = Task { await history.refresh(context: original) }
        await loader.waitForCalls(1)
        history.synchronize(context: context(account: "B"))
        history.synchronize(context: original)
        let second = Task { await history.refresh(context: original) }
        await loader.waitForCalls(2)
        let obsolete = ResetHistoryEvent(id: "obsolete", kind: "used", occurredAt: .now)
        await loader.finishFirst(with: [obsolete])
        await first.value
        #expect(history.events.isEmpty && !history.hasLoaded && history.isLoading)
        let current = ResetHistoryEvent(id: "current", kind: "granted", occurredAt: .now)
        await loader.finishFirst(with: [current])
        await second.value
        #expect(history.events == [current] && !history.isLoading)
    }

    @Test @MainActor func concurrentPageVisitsShareInFlightRequest() async {
        let loader = PendingLoader()
        let history = ResetHistoryStore(loader: { context, _ in try await loader.load(context) })
        let account = context()
        let first = Task { await history.refresh(context: account) }
        await loader.waitForCalls(1)
        let second = Task { await history.refresh(context: account) }
        await Task.yield()
        #expect(await loader.calls == 1)
        await loader.finishFirst(with: [])
        await first.value
        await second.value
        #expect(await loader.calls == 1)
        #expect(history.hasLoaded && !history.isLoading)
    }

    @Test @MainActor func failedLoadRetriesOnNextVisitAndKeepsPriorResult() async {
        let loader = Loader()
        let clock = Clock()
        let history = ResetHistoryStore(loader: { context, _ in try await loader.load(context) }, clock: { clock.now })
        let account = context()
        await loader.setFails(true)
        await history.refresh(context: account)
        #expect(!history.hasLoaded && history.error != nil && !history.isLoading)
        await loader.setFails(false)
        await history.refresh(context: account)
        #expect(history.hasLoaded && history.error == nil)
        let loadedAt = history.loadedAt
        clock.now += ResetHistoryStore.cacheLifetime
        await loader.setFails(true)
        await history.refresh(context: account)
        #expect(history.hasLoaded && history.loadedAt == loadedAt && history.error != nil)
        await loader.setFails(false)
        await history.refresh(context: account)
        #expect(history.error == nil && history.loadedAt == clock.now)
        #expect(await loader.calls == 4)
    }

    @Test func decodesActualEventTimesAndKinds() throws {
        let data = Data(#"{"events":[{"id":"used","kind":"used","occurred_at":"2026-09-06T05:16:00Z"},{"id":"grant","kind":"granted","occurred_at":"2026-09-05T04:19:00.123Z"},{"id":"other","kind":"future_kind","occurred_at":"2026-09-04T10:09:00+08:00"}],"next_cursor":"page 2"}"#.utf8)
        let page = try ResetHistoryPage.decode(data)
        #expect(page.events.count == 3)
        #expect(page.events[0].title == "已使用重置次数")
        #expect(page.events[1].title == "已获得重置次数")
        #expect(page.events[2].title == "其他重置记录")
        #expect(page.events[0].occurredAt == ISO8601DateFormatter().date(from: "2026-09-06T05:16:00Z"))
        #expect(page.nextCursor == "page 2")
    }

    @Test func emptyHistoryIsDistinctFromMalformedResponse() throws {
        #expect(try ResetHistoryPage.decode(Data(#"{"events":[],"next_cursor":null}"#.utf8)).events.isEmpty)
        #expect(throws: (any Error).self) {
            try ResetHistoryPage.decode(Data(#"{"events":[{"id":"bad","kind":"redeemed","occurred_at":"not a date"}]}"#.utf8))
        }
        #expect(throws: (any Error).self) {
            try ResetHistoryPage.decode(Data(#"{"error":"unauthorized"}"#.utf8))
        }
    }

    @Test func buildsReadOnlyRequestWithEncodedCursor() {
        let request = ResetHistoryClient.request(token: "synthetic-token", accountID: "synthetic-account", cursor: "page&= +/2")
        #expect(request.httpMethod == "GET")
        #expect(request.url?.host == "chatgpt.com")
        #expect(request.url?.path == "/backend-api/wham/rate-limit-reset-credits/history")
        #expect(request.httpBody == nil)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-token")
        #expect(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first?.value == "page&= +/2")
    }
}
