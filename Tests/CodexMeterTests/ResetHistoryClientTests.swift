import Foundation
import Testing
@testable import CodexMeter

struct ResetHistoryClientTests {
    private let now = Date(timeIntervalSince1970: 1_791_000_000)
    private func event(_ id: String, _ seconds: TimeInterval, kind: String = "granted") -> ResetHistoryEvent {
        ResetHistoryEvent(id: id, kind: kind, occurredAt: now.addingTimeInterval(seconds))
    }
    private actor Pages {
        let pages: [ResetHistoryPage]
        var cursors: [String?] = []
        init(_ pages: [ResetHistoryPage]) { self.pages = pages }
        func load(_ cursor: String?) throws -> ResetHistoryPage {
            cursors.append(cursor)
            guard cursors.count <= pages.count else { throw ResetHistoryError.incomplete }
            return pages[cursors.count - 1]
        }
    }

    @Test func initialSyncWalksAllPagesAndIncrementalSyncStopsAfterSavedOverlap() async throws {
        let a = event("a", 3), b = event("b", 2), c = event("c", 1), newer = event("new", 4)
        let initial = Pages([.init(events: [a], nextCursor: "p2"), .init(events: [b], nextCursor: "p3"),
                             .init(events: [c], nextCursor: nil)])
        let first = try await ResetHistoryClient.collect(knownEvents: []) { try await initial.load($0) }
        #expect(first == [a, b, c])
        #expect(await initial.cursors == [nil, "p2", "p3"])
        let delta = Pages([.init(events: [newer, a], nextCursor: "p2"), .init(events: [b], nextCursor: "p3"),
                           .init(events: [c], nextCursor: "unneeded-old-history")])
        let result = try await ResetHistoryClient.collect(knownEvents: first) { try await delta.load($0) }
        #expect(result == [newer, a, b, c])
        #expect(await delta.cursors.count == 3)
    }

    @Test func unchangedHistoryUsuallyNeedsOnlyTwoOverlappingPages() async throws {
        let a = event("a", 3), b = event("b", 2), c = event("c", 1)
        let pages = Pages([.init(events: [a], nextCursor: "p2"), .init(events: [b], nextCursor: "not-needed")])
        _ = try await ResetHistoryClient.collect(knownEvents: [a, b, c]) { try await pages.load($0) }
        #expect(await pages.cursors.count == 2)
    }

    @Test func sameTimestampNewIDAndChangedEventAreNotSkipped() async throws {
        let a = event("a", 3), sameTime = event("new-same-time", 3), b = event("b", 2), c = event("c", 1)
        let updated = event("b", 2, kind: "used")
        let pages = Pages([.init(events: [a], nextCursor: "p2"), .init(events: [sameTime], nextCursor: "p3"),
                           .init(events: [updated], nextCursor: "p4"), .init(events: [c], nextCursor: nil)])
        let result = try await ResetHistoryClient.collect(knownEvents: [a, b, c]) { try await pages.load($0) }
        #expect(result.contains(sameTime) && result.contains(updated) && !result.contains(b))
        #expect(await pages.cursors.count == 4)
    }

    @Test func observedDisorderDisablesBoundaryAndRepeatedCursorFails() async throws {
        let a = event("a", 5), b = event("b", 4), c = event("c", 3), d = event("d", 2), backdated = event("late", 0)
        let pages = Pages([.init(events: [a, b], nextCursor: "p2"), .init(events: [c, b], nextCursor: "p3"),
                           .init(events: [d], nextCursor: "p4"), .init(events: [backdated], nextCursor: nil)])
        let result = try await ResetHistoryClient.collect(knownEvents: [a, b, c, d]) { try await pages.load($0) }
        #expect(result.contains(backdated))
        #expect(await pages.cursors.count == 4)
        let loop = Pages([.init(events: [], nextCursor: "repeat"), .init(events: [], nextCursor: "repeat")])
        await #expect(throws: (any Error).self) {
            try await ResetHistoryClient.collect(knownEvents: []) { try await loop.load($0) }
        }
        #expect(await loop.cursors.count == 2)
    }

    private actor Transport {
        enum Reply: Sendable { case timeout, cancelled, success, unauthorized }
        let replies: [Reply]
        var calls = 0
        var delays = 0
        init(_ replies: [Reply]) { self.replies = replies }
        func delay() { delays += 1 }
        func send(_ request: URLRequest) throws -> (Data, Int) {
            calls += 1
            guard calls <= replies.count else { throw ResetHistoryError.incomplete }
            switch replies[calls - 1] {
            case .timeout: throw URLError(.timedOut)
            case .cancelled: throw URLError(.cancelled)
            case .unauthorized: return (Data(), 401)
            case .success: return (Data(#"{"events":[],"next_cursor":null}"#.utf8), 200)
            }
        }
    }
    private func syntheticContext() throws -> CodexDataContext {
        let home = TestFixtureDirectory.root.appendingPathComponent("reset-client-" + UUID().uuidString + "/.codex")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let payload = Data(#"{"sub":"synthetic-user"}"#.utf8).base64EncodedString()
        let auth: [String: Any] = ["tokens": ["account_id": "synthetic-account", "access_token": "synthetic-token",
                                             "id_token": "header.\(payload).signature"]]
        try JSONSerialization.data(withJSONObject: auth).write(to: home.appendingPathComponent("auth.json"))
        let credentials = try #require(CodexCredentials.read(home: home))
        return CodexDataContext(source: CodexDataSource(root: home), accountIdentity: credentials.identity, since: now)
    }

    @Test func timeoutRetriesSameReadOnceAndCanRecoverWithoutAnotherClick() async throws {
        let context = try syntheticContext()
        let transport = Transport([.timeout, .success])
        let client = ResetHistoryClient(transport: { try await transport.send($0) }, retryDelay: { await transport.delay() })
        let events = try await client.load(context: context)
        #expect(events.isEmpty)
        #expect(await transport.calls == 2)
        #expect(await transport.delays == 1)
    }

    @Test func retryIsBoundedAndAuthenticationOrCancellationAreNeverRetried() async throws {
        let context = try syntheticContext()
        let scenarios: [[Transport.Reply]] = [[.timeout, .timeout, .success], [.unauthorized, .success], [.cancelled, .success]]
        for replies in scenarios {
            let transport = Transport(replies)
            let client = ResetHistoryClient(transport: { try await transport.send($0) }, retryDelay: { await transport.delay() })
            await #expect(throws: (any Error).self) { try await client.load(context: context) }
            #expect(await transport.calls == (replies.count == 3 ? 2 : 1))
            #expect(await transport.delays == (replies.count == 3 ? 1 : 0))
        }
    }
}
