import Foundation
import Testing
@testable import CodexMeter

struct LiveQuotaTests {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    private func response(percent: Double = 1, primary: Bool = true) -> Data {
        Data("""
        {"rate_limit":{"\(primary ? "primary_window" : "secondary_window")":{"used_percent":\(percent),"limit_window_seconds":604800,"reset_at":\(now.timeIntervalSince1970 + 86400)}},"additional_rate_limits":[{"rate_limit":{"primary_window":{"used_percent":99,"limit_window_seconds":604800,"reset_at":2000086400}}}]}
        """.utf8)
    }

    private func auth(_ root: URL, account: String = "synthetic-A") throws {
        let payload = Data(#"{"sub":"synthetic-user"}"#.utf8).base64EncodedString()
        let data = try JSONSerialization.data(withJSONObject: ["auth_mode": "chatgpt", "tokens": [
            "account_id": account, "access_token": "synthetic", "id_token": "header.\(payload).signature"]])
        try data.write(to: root.appendingPathComponent("auth.json"), options: .atomic)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-3600)], ofItemAtPath: root.appendingPathComponent("auth.json").path)
    }

    @Test func primaryAndSecondaryWeeklyWindowsUseCanonicalQuotaOnly() throws {
        for primary in [true, false] {
            let observation = try LiveQuotaClient.decode(response(primary: primary), sampledAt: now)
            var snapshot = UsageSnapshot.empty
            observation.apply(to: &snapshot, now: now)
            #expect(snapshot.sevenDayRate?.usedPercent == 1)
            #expect(snapshot.mainRateSampledAt == now)
            #expect(snapshot.selectedRateLimitID == "codex")
        }
        for body in [#"{}"#, #"{"rate_limit":null}"#, String(decoding: response(percent: 101), as: UTF8.self)] {
            #expect(throws: LiveQuotaError.self) { try LiveQuotaClient.decode(Data(body.utf8), sampledAt: now) }
        }
    }

    private actor Transport {
        var calls = 0
        var fail = false
        let body: Data
        init(_ body: Data) { self.body = body }
        func setFailure() { fail = true }
        func send(_ request: URLRequest) throws -> (Data, Int) {
            calls += 1
            #expect(request.url?.absoluteString == "https://chatgpt.com/backend-api/wham/usage")
            #expect(request.httpMethod == "GET")
            #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
            #expect(request.value(forHTTPHeaderField: "ChatGPT-Account-Id") == "synthetic-A")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic")
            if fail { throw URLError(.notConnectedToInternet) }
            return (body, 200)
        }
    }

    @MainActor @Test func manualRefreshFetchesWithoutNewSessionAndOfflineRefreshKeepsNewerQuota() async throws {
        let root = TestFixtureDirectory.root.appendingPathComponent("live-quota-" + UUID().uuidString)
        let sessions = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try auth(root)
        // The unchanged local file still says 80% used before an account reset.
        let local = """
        {"timestamp":"\(now.addingTimeInterval(-1800).ISO8601Format())","type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":{"limit_id":"codex","primary":{"used_percent":80,"window_minutes":10080,"resets_at":2000080000}}}}
        """
        try local.write(to: sessions.appendingPathComponent("synthetic.jsonl"), atomically: true, encoding: .utf8)
        let defaults = try #require(UserDefaults(suiteName: "CodexMeterTests.LiveQuota." + UUID().uuidString))
        let transport = Transport(response())
        let time = now
        let client = LiveQuotaClient(transport: { try await transport.send($0) }, clock: { time })
        let store = UsageStore(folderAccess: CodexFolderAccess(defaults: defaults, selectedURL: root), defaults: defaults,
                               effectsEnabled: false, clock: { time }, quotaClient: client)
        await store.refresh(userInitiated: true)
        #expect(store.snapshot.sevenDayRate?.usedPercent == 1)
        #expect(store.snapshot.mainRateSampledAt == now)
        #expect(store.refreshFeedback?.outcome == .newSample)
        #expect(store.errorMessage == nil)
        #expect(store.snapshot.allTime.total == 0)
        await store.refresh() // No extra query on an incidental refresh inside the polling interval.
        #expect(await transport.calls == 1)
        #expect(store.snapshot.sevenDayRate?.usedPercent == 1)
        await transport.setFailure()
        await store.refresh(userInitiated: true)
        #expect(await transport.calls == 2)
        #expect(store.snapshot.sevenDayRate?.usedPercent == 1)
        #expect(store.snapshot.mainRateSampledAt == now)
        #expect(store.refreshFeedback?.outcome == .incomplete)
        #expect(store.errorMessage?.contains("账户额度服务") == true)
        // A fresh launch must also prefer a newer account sample over the old file.
        let restarted = UsageStore(folderAccess: CodexFolderAccess(defaults: defaults, selectedURL: root), defaults: defaults,
                                   effectsEnabled: false, clock: { time })
        await restarted.refresh()
        #expect(restarted.snapshot.sevenDayRate?.usedPercent == 1)
        #expect(restarted.snapshot.mainRateSampledAt == now)
    }

    @Test func changedAccountAndRejectedResponsesNeverApplyQuota() async throws {
        let root = TestFixtureDirectory.root.appendingPathComponent("live-quota-account-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try auth(root)
        let source = CodexDataSource(root: root)
        let identity = try #require(CodexCredentials.read(home: root)?.identity)
        let context = CodexDataContext(source: source, accountIdentity: identity, since: now.addingTimeInterval(-3600))
        for status in [401, 429, 500, 302] {
            let client = LiveQuotaClient(transport: { _ in (Data(), status) })
            await #expect(throws: LiveQuotaError.self) { try await client.load(context: context) }
        }
        let body = response()
        let client = LiveQuotaClient(transport: { _ in
            try auth(root, account: "synthetic-B")
            return (body, 200)
        })
        await #expect(throws: LiveQuotaError.self) { try await client.load(context: context) }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["CODEX_HEALTH_LIVE_QUOTA_CHECK"] == "1"))
    func authorizedLiveEndpointCheck() async throws {
        let source = CodexDataSource(root: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex"))
        let identity = try #require(CodexCredentials.read(home: source.home)?.identity)
        let context = CodexDataContext(source: source, accountIdentity: identity, since: .distantPast)
        let result = try await LiveQuotaClient().load(context: context)
        let weekly = try #require([result.primary, result.secondary].compactMap { $0 }.first { $0.windowMinutes == 10_080 })
        print("Live quota verified: remaining \(100 - weekly.usedPercent)%, sampled \(result.sampledAt.ISO8601Format())")
    }
}
