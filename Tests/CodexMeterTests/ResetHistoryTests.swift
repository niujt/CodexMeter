import Foundation
import Testing
@testable import CodexMeter

struct ResetHistoryTests {
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
