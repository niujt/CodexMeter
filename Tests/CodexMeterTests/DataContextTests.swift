import Foundation
import Testing
@testable import CodexMeter

struct DataContextTests {
    private let now = Date(timeIntervalSince1970: 1_791_000_000)

    private func fixture() throws -> (URL, UserDefaults) {
        let root = TestFixtureDirectory.root.appendingPathComponent("account-fixture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (root, try #require(UserDefaults(suiteName: "CodexMeterTests.Account." + UUID().uuidString)))
    }

    private static func auth(home: URL, account: String, user: String = "person", token: String = "synthetic", at: Date) throws {
        let payload = try JSONSerialization.data(withJSONObject: ["sub": user]).base64EncodedString()
        let object: [String: Any] = ["tokens": ["account_id": account, "access_token": token, "id_token": "header.\(payload).signature"]]
        let file = home.appendingPathComponent("auth.json")
        try JSONSerialization.data(withJSONObject: object).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.modificationDate: at], ofItemAtPath: file.path)
    }

    private func token(at date: Date, total: Int, quota: Int? = nil) throws -> String {
        var payload: [String: Any] = ["type": "token_count", "info": ["total_token_usage": ["total_tokens": total]]]
        if let quota {
            payload["rate_limits"] = ["limit_id": "codex", "primary": ["used_percent": quota, "window_minutes": 10_080,
                "resets_at": now.addingTimeInterval(86_400).timeIntervalSince1970]]
        }
        return String(decoding: try JSONSerialization.data(withJSONObject: ["timestamp": ISO8601DateFormatter().string(from: date),
            "type": "event_msg", "payload": payload]), as: UTF8.self) + "\n"
    }

    @Test func defaultRootPrecedenceIsShared() {
        let home = URL(fileURLWithPath: "/synthetic/home")
        #expect(CodexDataSource.defaultRoot(bundlePath: "/synthetic/bundle", environment: ["CODEX_HOME": "/synthetic/env"], userHome: home).path == "/synthetic/bundle")
        #expect(CodexDataSource.defaultRoot(bundlePath: "", environment: ["CODEX_HOME": "/synthetic/env"], userHome: home).path == "/synthetic/env")
        #expect(CodexDataSource.defaultRoot(bundlePath: nil, environment: ["HOME": "/synthetic/user"], userHome: home).path == "/synthetic/user/.codex")
        #expect(CodexDataSource.defaultRoot(bundlePath: nil, environment: [:], userHome: home).path == "/synthetic/home/.codex")
    }

    @Test func sessionGrantNeverReadsParentCredentials() throws {
        let (root, defaults) = try fixture()
        let sessions = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try Self.auth(home: root, account: "A", at: now)
        let source = CodexDataSource(root: sessions)
        #expect(source.home == nil)
        #expect(source.permissionPaths(monitorBase: root) == nil)
        #expect(CodexDataContext.resolve(source: source, defaults: defaults, now: now).quotaScope == nil)
        #expect(CodexCredentials.read(home: source.home) == nil)
    }

    @Test func accountAndDirectoryPartitionsIgnoreTokenRefreshButSeparateWorkspaceUsers() throws {
        let (root, defaults) = try fixture()
        try Self.auth(home: root, account: "workspace", user: "person-A", at: now.addingTimeInterval(-100))
        let source = CodexDataSource(root: root)
        let a = CodexDataContext.resolve(source: source, defaults: defaults, now: now)
        try Self.auth(home: root, account: "workspace", user: "person-A", token: "refreshed", at: now)
        #expect(CodexDataContext.resolve(source: source, defaults: defaults, now: now) == a)
        try Self.auth(home: root, account: "workspace", user: "person-B", at: now)
        let b = CodexDataContext.resolve(source: source, defaults: defaults, now: now)
        #expect(b.id != a.id)
        #expect(b.since == now)
        try Self.auth(home: root, account: "workspace", user: "person-A", at: now.addingTimeInterval(10))
        let returned = CodexDataContext.resolve(source: source, defaults: defaults, now: now.addingTimeInterval(10))
        #expect(returned.id != a.id)
        #expect(returned.since == now.addingTimeInterval(10))
        let other = root.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try Self.auth(home: other, account: "workspace", user: "person-A", at: now)
        #expect(CodexDataContext.resolve(source: CodexDataSource(root: other), defaults: defaults, now: now).id != a.id)
    }

    @Test func logoutAndAPIKeyModeRejectOldCredentials() throws {
        let (root, defaults) = try fixture()
        try Self.auth(home: root, account: "A", at: now)
        let source = CodexDataSource(root: root)
        let loggedIn = CodexDataContext.resolve(source: source, defaults: defaults, now: now)
        try Data("{}".utf8).write(to: root.appendingPathComponent("auth.json"), options: .atomic)
        let loggedOut = CodexDataContext.resolve(source: source, defaults: defaults, now: now.addingTimeInterval(1))
        #expect(loggedOut.quotaScope == nil)
        #expect(loggedOut.id != loggedIn.id)
        let data = Data(#"{"auth_mode":"apikey","OPENAI_API_KEY":"synthetic","tokens":{"account_id":"A","access_token":"stale"}}"#.utf8)
        try data.write(to: root.appendingPathComponent("auth.json"), options: .atomic)
        #expect(CodexCredentials.read(home: root) == nil)
    }

    @Test func offlineLoginFileChangeNarrowsBoundaryEvenWhenReturningToSameAccount() throws {
        let (root, defaults) = try fixture()
        try Self.auth(home: root, account: "A", at: now.addingTimeInterval(-3_600))
        let source = CodexDataSource(root: root)
        let original = CodexDataContext.resolve(source: source, defaults: defaults, now: now, initialObservation: true)
        #expect(CodexDataContext.resolve(source: source, defaults: defaults, now: now, initialObservation: true) == original)
        try Self.auth(home: root, account: "A", token: "new-login", at: now)
        let resumed = CodexDataContext.resolve(source: source, defaults: defaults, now: now, initialObservation: true)
        #expect(resumed.accountIdentity == original.accountIdentity)
        #expect(resumed.id != original.id)
        #expect(resumed.since == now)
        try Self.auth(home: root, account: "A", token: "live-refresh", at: now.addingTimeInterval(1))
        #expect(CodexDataContext.resolve(source: source, defaults: defaults, now: now.addingTimeInterval(1)) == resumed)
    }

    @Test func cacheRejectsOtherScopesLegacyValuesAndPreLoginQuotaTimestamp() throws {
        let (_, defaults) = try fixture()
        let a = QuotaScope(id: "directory-A-account-A", since: now.addingTimeInterval(-60))
        let b = QuotaScope(id: "directory-B-account-A", since: a.since)
        var snapshot = UsageSnapshot.empty
        snapshot.mainMenuRate = RateWindow(usedPercent: 90, windowMinutes: 10_080, resetsAt: now.addingTimeInterval(3_600))
        snapshot.lastUpdated = now
        snapshot.mainRateSampledAt = now.addingTimeInterval(-120)
        QuotaRateCache.save(snapshot, scope: a, defaults: defaults, now: now)
        var restored = UsageSnapshot.empty
        QuotaRateCache.restore(into: &restored, scope: a, defaults: defaults, now: now)
        #expect(restored.mainMenuRate == nil)
        snapshot.mainRateSampledAt = now
        QuotaRateCache.save(snapshot, scope: a, defaults: defaults, now: now)
        QuotaRateCache.restore(into: &restored, scope: b, defaults: defaults, now: now)
        #expect(restored.mainMenuRate == nil)
        QuotaRateCache.restore(into: &restored, scope: a, defaults: defaults, now: now)
        #expect(restored.mainMenuRate?.usedPercent == 90)
        var unknown = UsageSnapshot.empty
        defaults.set(defaults.data(forKey: QuotaRateCache.key(for: a)), forKey: "codexMeter.quotaRateCache.v2")
        QuotaRateCache.restore(into: &unknown, defaults: defaults, now: now)
        #expect(unknown.mainMenuRate == nil)
    }

    @Test func predictionUsesRealSampleTimesAndCurrentResetCycleOnly() throws {
        let (_, defaults) = try fixture()
        let a = QuotaScope(id: "A", since: now.addingTimeInterval(-7_200))
        let b = QuotaScope(id: "B", since: a.since)
        let reset = now.addingTimeInterval(86_400)
        let old = RateWindow(usedPercent: 10, windowMinutes: 10_080, resetsAt: reset)
        let new = RateWindow(usedPercent: 20, windowMinutes: 10_080, resetsAt: reset)
        RateHistory.append(old, sampledAt: now.addingTimeInterval(-1_800), scope: a, defaults: defaults, now: now)
        RateHistory.append(new, sampledAt: now, scope: a, defaults: defaults, now: now)
        for _ in 0..<10 { RateHistory.append(new, sampledAt: now, scope: a, defaults: defaults, now: now.addingTimeInterval(100)) }
        #expect(RateHistory.samples(scope: a, defaults: defaults).count == 2)
        #expect(RateHistory.weightedVelocity(scope: a, resetsAt: reset, defaults: defaults, now: now)?.percentPerHour == 20)
        #expect(RateHistory.weightedVelocity(scope: b, resetsAt: reset, defaults: defaults, now: now) == nil)
        let next = RateWindow(usedPercent: 50, windowMinutes: 10_080, resetsAt: reset.addingTimeInterval(604_800))
        RateHistory.append(next, sampledAt: now.addingTimeInterval(600), scope: a, defaults: defaults, now: now.addingTimeInterval(600))
        #expect(RateHistory.weightedVelocity(scope: a, resetsAt: next.resetsAt, defaults: defaults, now: now.addingTimeInterval(600)) == nil)
    }

    @Test func readerFiltersAccountQuotasWithoutLosingDirectoryTokenTotalsOrReparsing() async throws {
        let (root, _) = try fixture()
        let file = root.appendingPathComponent("session.jsonl")
        try (token(at: now.addingTimeInterval(-1_200), total: 100, quota: 80)
             + token(at: now.addingTimeInterval(-60), total: 150)).write(to: file, atomically: true, encoding: .utf8)
        let reader = CodexUsageReader()
        let old = try await reader.load(now: now, codexHome: root)
        #expect(old.mainMenuRate?.usedPercent == 80)
        let current = try await reader.load(now: now, codexHome: root, quotaSince: now.addingTimeInterval(-600))
        #expect(current.allTime.total == 150)
        #expect(current.mainMenuRate == nil)
        #expect(current.primaryRate == nil)
        #expect(current.rateTimeline.isEmpty)
        #expect(await reader.parsedFileCount == 0)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(token(at: now, total: 200, quota: 5).utf8))
        try handle.close()
        let updated = try await reader.load(now: now, codexHome: root, quotaSince: now.addingTimeInterval(-600))
        #expect(updated.mainMenuRate?.usedPercent == 5)
        #expect(updated.mainRateSampledAt == now)
        #expect(updated.allTime.total == 200)
        let futureHandle = try FileHandle(forWritingTo: file)
        try futureHandle.seekToEnd()
        try futureHandle.write(contentsOf: Data(token(at: now.addingTimeInterval(60), total: 250, quota: 6).utf8))
        try futureHandle.close()
        _ = try await reader.load(now: now, codexHome: root, quotaSince: now.addingTimeInterval(-600))
        let later = try await reader.load(now: now.addingTimeInterval(60), codexHome: root, quotaSince: now.addingTimeInterval(-600))
        #expect(later.mainMenuRate?.usedPercent == 6)
        #expect(await reader.parsedFileCount == 0)
    }

    @MainActor @Test func manualRefreshDistinguishesQuotaSamplesFromChecksAndTokenChanges() async throws {
        let (root, defaults) = try fixture()
        let sessions = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try Self.auth(home: root, account: "A", at: now.addingTimeInterval(-100))
        let file = sessions.appendingPathComponent("quota.jsonl")
        let sampledAt = now.addingTimeInterval(-60)
        let original = try token(at: sampledAt, total: 100, quota: 9)
        try original.write(to: file, atomically: true, encoding: .utf8)
        let store = UsageStore(reader: CodexUsageReader(), folderAccess: CodexFolderAccess(defaults: defaults, selectedURL: root),
            defaults: defaults, effectsEnabled: false, clock: { now })
        await store.refresh(userInitiated: true)
        #expect(store.refreshFeedback?.outcome == .newSample)
        await store.refresh(force: true, userInitiated: true)
        #expect(store.refreshFeedback?.outcome == .noNewSample)
        #expect(store.snapshot.mainRateSampledAt == sampledAt)
        try (original + token(at: now, total: 150)).write(to: file, atomically: true, encoding: .utf8)
        await store.refresh(userInitiated: true)
        #expect(store.snapshot.allTime.total == 150)
        #expect(store.snapshot.mainRateSampledAt == sampledAt)
        #expect(store.refreshFeedback?.outcome == .noNewSample)
        #expect(store.refreshFeedback?.checkedAt == now)
        // A newer quota sample counts even if its percentage did not change.
        try (original + token(at: now, total: 200, quota: 9)).write(to: file, atomically: true, encoding: .utf8)
        await store.refresh(userInitiated: true)
        #expect(store.refreshFeedback?.outcome == .newSample)
        #expect(store.snapshot.mainRateSampledAt == now)
        let feedback = store.refreshFeedback
        await store.refresh()
        #expect(store.refreshFeedback == feedback)
        try Self.auth(home: root, account: "B", at: now)
        #expect(store.synchronizeContext())
        #expect(store.refreshFeedback == nil)
    }

    @MainActor @Test func manualRefreshReportsIncompleteReadsAndFailure() async throws {
        let (root, defaults) = try fixture()
        try (token(at: now, total: 100) + "invalid-json\n").write(
            to: root.appendingPathComponent("partial.jsonl"), atomically: true, encoding: .utf8)
        let store = UsageStore(reader: CodexUsageReader(), folderAccess: CodexFolderAccess(defaults: defaults, selectedURL: root),
            defaults: defaults, effectsEnabled: false, clock: { now })
        await store.refresh(userInitiated: true)
        #expect(store.snapshot.allTime.total == 100)
        #expect(store.errorMessage != nil)
        #expect(store.refreshFeedback?.outcome == .incomplete)
        #expect(store.refreshFeedback?.detail == store.errorMessage)
        let failed = UsageStore(reader: CodexUsageReader(),
            folderAccess: CodexFolderAccess(defaults: defaults, selectedURL: root.appendingPathComponent("missing/.codex")),
            defaults: defaults, effectsEnabled: false, clock: { now })
        await failed.refresh(userInitiated: true)
        #expect(failed.errorMessage != nil)
        #expect(failed.refreshFeedback?.outcome == .failed)
        #expect(failed.refreshFeedback?.detail == failed.errorMessage)
    }

    @Test func cachedExpiredAndFutureSamplesNeverReportANewQuota() {
        var loaded = UsageSnapshot.empty
        loaded.mainMenuRate = RateWindow(usedPercent: 9, windowMinutes: 10_080, resetsAt: now.addingTimeInterval(3_600))
        loaded.mainRateSampledAt = now.addingTimeInterval(-60)
        loaded.mainRateIsCached = true
        #expect(UsageRefreshFeedback.completed(previous: .empty, loaded: loaded, checkedAt: now, hasWarning: false).outcome == .noNewSample)
        loaded.mainRateIsCached = false
        loaded.mainRateSampledAt = now.addingTimeInterval(60)
        #expect(UsageRefreshFeedback.completed(previous: .empty, loaded: loaded, checkedAt: now, hasWarning: false).outcome == .noNewSample)
        loaded.mainRateSampledAt = now.addingTimeInterval(-60)
        loaded.mainMenuRate = RateWindow(usedPercent: 9, windowMinutes: 10_080, resetsAt: now)
        #expect(UsageRefreshFeedback.completed(previous: .empty, loaded: loaded, checkedAt: now, hasWarning: false).outcome == .noNewSample)
    }

    @MainActor @Test func directorySwitchClearsSnapshotAndFailureNeverRestoresOtherDirectory() async throws {
        let (root, defaults) = try fixture()
        try token(at: now, total: 100).write(to: root.appendingPathComponent("session.jsonl"), atomically: true, encoding: .utf8)
        let access = CodexFolderAccess(defaults: defaults, selectedURL: root)
        let store = UsageStore(reader: CodexUsageReader(), folderAccess: access, defaults: defaults, effectsEnabled: false, clock: { now })
        await store.refresh()
        #expect(store.snapshot.allTime.total == 100)
        let missing = root.appendingPathComponent("missing/.codex")
        // Synthetic missing path bookmark creation can fail; use a second access object for that failure test.
        let other = root.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try access.select(other)
        #expect(store.synchronizeContext())
        #expect(store.snapshot.allTime.total == 0)
        await store.refresh()
        #expect(store.snapshot.allTime.total == 0)
        let failed = UsageStore(reader: CodexUsageReader(), folderAccess: CodexFolderAccess(defaults: defaults, selectedURL: missing),
            defaults: defaults, effectsEnabled: false, clock: { now })
        await failed.refresh()
        #expect(failed.snapshot.allTime.total == 0)
        #expect(failed.errorMessage != nil)
    }

    @MainActor @Test func authChangeBypassesRefreshThrottleAndOldQuotaIsNotReused() async throws {
        let (root, defaults) = try fixture()
        let sessions = root.appendingPathComponent("sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try Self.auth(home: root, account: "A", at: now.addingTimeInterval(-100))
        try token(at: now.addingTimeInterval(-60), total: 100, quota: 75).write(to: sessions.appendingPathComponent("a.jsonl"), atomically: true, encoding: .utf8)
        let store = UsageStore(reader: CodexUsageReader(), folderAccess: CodexFolderAccess(defaults: defaults, selectedURL: root),
            defaults: defaults, effectsEnabled: false, clock: { now })
        await store.refresh()
        #expect(store.snapshot.mainMenuRate?.usedPercent == 75)
        let original = store.context?.id
        try Self.auth(home: root, account: "B", at: now)
        await store.refreshIfNeeded()
        #expect(store.context?.id != original)
        #expect(store.snapshot.mainMenuRate == nil)
        #expect(store.measuredVelocity == nil)
        #expect(store.snapshot.allTime.total == 100)
    }

    @MainActor @Test func invalidBookmarkDoesNotSilentlyFallBackToDefaultHome() async throws {
        let (_, defaults) = try fixture()
        defaults.set(Data("invalid-bookmark".utf8), forKey: "codexHomeBookmarkV2")
        let store = UsageStore(reader: CodexUsageReader(), folderAccess: CodexFolderAccess(defaults: defaults), defaults: defaults, effectsEnabled: false)
        await store.refresh()
        #expect(store.context == nil)
        #expect(store.selectedCodexPath.isEmpty)
        #expect(store.errorMessage?.contains("重新选择") == true)
    }

    @Test func resetHistoryDiscardsResponseIfAccountChangesDuringRequest() async throws {
        let (root, defaults) = try fixture()
        try Self.auth(home: root, account: "A", at: now)
        let context = CodexDataContext.resolve(source: CodexDataSource(root: root), defaults: defaults, now: now)
        let now = now
        let client = ResetHistoryClient(transport: { request in
            #expect(request.value(forHTTPHeaderField: "ChatGPT-Account-Id") == "A")
            try Self.auth(home: root, account: "B", at: now)
            return (Data(#"{"events":[{"id":"old","kind":"used","occurred_at":"2026-09-06T05:16:00Z"}],"next_cursor":"second"}"#.utf8), 200)
        })
        do { _ = try await client.load(context: context); Issue.record("An obsolete account response was published") }
        catch ResetHistoryError.accountChanged { }
    }

    @Test func resetHistorySessionDirectoryNeverFallsBackOrMakesRequest() async throws {
        let (root, defaults) = try fixture()
        let context = CodexDataContext.resolve(source: CodexDataSource(root: root), defaults: defaults, now: now)
        let client = ResetHistoryClient(transport: { _ in Issue.record("Session-only source must not make a request"); return (Data(), 200) })
        do { _ = try await client.load(context: context); Issue.record("Expected missing-login error") }
        catch ResetHistoryError.loginRequired { }
    }

    @Test func resetHistoryAcceptsSameAccountTokenRefreshAcrossPagination() async throws {
        let (root, defaults) = try fixture()
        try Self.auth(home: root, account: "A", at: now)
        let context = CodexDataContext.resolve(source: CodexDataSource(root: root), defaults: defaults, now: now)
        let calls = SyntheticCallCount()
        let now = now
        let client = ResetHistoryClient(transport: { request in
            let page = await calls.next()
            #expect(request.value(forHTTPHeaderField: "ChatGPT-Account-Id") == "A")
            if page == 1 {
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic")
                try Self.auth(home: root, account: "A", token: "refreshed", at: now.addingTimeInterval(1))
                return (Data(#"{"events":[{"id":"one","kind":"used","occurred_at":"2026-09-06T05:16:00Z"}],"next_cursor":"second"}"#.utf8), 200)
            }
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer refreshed")
            #expect(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first?.value == "second")
            return (Data(#"{"events":[{"id":"one","kind":"used","occurred_at":"2026-09-06T05:16:00Z"},{"id":"two","kind":"granted","occurred_at":"2026-09-07T05:16:00Z"}],"next_cursor":null}"#.utf8), 200)
        })
        #expect(try await client.load(context: context).map(\.id) == ["two", "one"])
        #expect(await calls.value == 2)
    }

    @MainActor @Test func accountMonitorDetectsAtomicReplacementAndLeavesPreviousDirectory() async throws {
        let (a, _) = try fixture()
        let (b, _) = try fixture()
        try Self.auth(home: a, account: "A", at: now)
        try Self.auth(home: b, account: "B", at: now)
        let monitor = CodexAccountMonitor()
        let calls = MonitorCallCount()
        monitor.watch(home: a) { calls.value += 1 }
        try Self.auth(home: a, account: "new-A", at: now)
        for _ in 0..<100 {
            if calls.value > 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(calls.value > 0)
        monitor.watch(home: b) { calls.value += 1 }
        let before = calls.value
        try Self.auth(home: a, account: "old-root", at: now)
        try await Task.sleep(for: .milliseconds(100))
        #expect(calls.value == before)
        try Self.auth(home: b, account: "new-B", at: now)
        for _ in 0..<100 {
            if calls.value > before { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(calls.value > before)
        monitor.stop()
    }

    @MainActor @Test func permissionHistoriesAndHookPathsFollowSelectedRoot() throws {
        let (root, defaults) = try fixture()
        let a = root.appendingPathComponent("a/.codex")
        let b = root.appendingPathComponent("b/.codex")
        let first = try #require(CodexDataSource(root: a).permissionPaths(monitorBase: root))
        let second = try #require(CodexDataSource(root: b).permissionPaths(monitorBase: root))
        #expect(first.hooksConfig.path == a.appendingPathComponent("hooks.json").path)
        #expect(first.eventsFile != second.eventsFile)
        let store = PermissionStore(persistenceURL: first.eventsFile, defaults: defaults)
        let event = CodexPermissionEvent(eventId: "synthetic", receivedAt: .now, sessionId: "s", turnId: "t",
            project: .init(name: "Demo", cwd: "/demo"), permission: .init(mode: "default", toolName: "Bash"), codex: .init(model: "test"))
        store.ingest(event)
        let service = PermissionAttentionService(paths: first, store: store, defaults: defaults)
        service.configure(paths: second)
        #expect(store.events.isEmpty)
        #expect(service.hookStatus == .notInstalled)
        service.configure(paths: first)
        #expect(store.events.first?.eventId == "synthetic")
        service.configure(paths: nil)
        #expect(store.events.isEmpty)
        #expect(service.integrationMessage?.contains("会话目录") == true)
    }

    @Test func scopedHooksAreIdempotentAndPreserveUnrelatedSimilarCommands() throws {
        let (root, _) = try fixture()
        let home = root.appendingPathComponent("selected/.codex")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let paths = try #require(CodexDataSource(root: home).permissionPaths(monitorBase: root.appendingPathComponent("monitor $literal `text` 'quote'")))
        let unrelated = "/usr/bin/python3 /custom/.codex-monitor/hooks/codex_permission_hook.py --custom"
        let original: [String: Any] = ["hooks": ["PermissionRequest": [["matcher": "*", "hooks": [["type": "command", "command": unrelated]]]]]]
        try JSONSerialization.data(withJSONObject: original).write(to: paths.hooksConfig)
        let installer = PermissionHookInstaller(paths: paths)
        try installer.install()
        try installer.install()
        #expect(installer.status() == .installed)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: paths.hooksConfig)) as? [String: Any])
        let hooks = try #require(object["hooks"] as? [String: Any])
        let groups = try #require(hooks["PermissionRequest"] as? [[String: Any]])
        let commands = groups.flatMap { $0["hooks"] as? [[String: Any]] ?? [] }.compactMap { $0["command"] as? String }
        #expect(commands.count == 2)
        #expect(commands.contains(unrelated))
        #expect(commands.contains(PermissionHookInstaller.command(for: paths.hookScript)))
    }

    @Test func widgetContextChangePublishesEvenIfVisibleValuesMatch() throws {
        let (root, _) = try fixture()
        let file = root.appendingPathComponent("widget.json")
        let a = WidgetUsageData(todayTokens: 0, weekTokens: 0, monthTokens: 0, contextTokens: 0, contextLimit: 0,
            ratePercent: nil, rateWindowMinutes: nil, updatedAt: now, contextID: "A")
        var b = a
        b.contextID = "B"
        #expect(try WidgetUsageCache.saveIfChanged(a, to: file))
        #expect(try WidgetUsageCache.saveIfChanged(b, to: file))
        #expect(WidgetUsageCache.load(from: file)?.contextID == "B")
    }
}

private actor SyntheticCallCount {
    private(set) var value = 0
    func next() -> Int { value += 1; return value }
}

@MainActor private final class MonitorCallCount { var value = 0 }

private actor ReaderPause {
    private var entered = false
    private var ready: CheckedContinuation<Void, Never>?
    private var release: CheckedContinuation<Void, Never>?
    func pauseOnce() async {
        guard !entered else { return }
        entered = true
        await withCheckedContinuation { release = $0; ready?.resume(); ready = nil }
    }
    func waitUntilPaused() async {
        if entered { return }
        await withCheckedContinuation { ready = $0 }
    }
    func resume() { release?.resume(); release = nil }
}

struct ReaderContextConcurrencyTests {
    @Test func cancelledReadCannotCorruptAnotherDirectoryAcrossProgressYield() async throws {
        let root = TestFixtureDirectory.root.appendingPathComponent("reader-concurrency-" + UUID().uuidString)
        let a = root.appendingPathComponent("a")
        let b = root.appendingPathComponent("b")
        for directory in [a, b] { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        func line(_ total: Int) -> String { "{\"timestamp\":\"2026-10-03T00:00:00Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"total_tokens\":\(total)}}}}\n" }
        try line(100).write(to: a.appendingPathComponent("a.jsonl"), atomically: true, encoding: .utf8)
        try line(200).write(to: b.appendingPathComponent("b.jsonl"), atomically: true, encoding: .utf8)
        let reader = CodexUsageReader()
        let pause = ReaderPause()
        let first = Task { try await reader.load(codexHome: a) { _, _, _ in await pause.pauseOnce() } }
        await pause.waitUntilPaused()
        let second = Task { try await reader.load(codexHome: b) }
        first.cancel()
        await pause.resume()
        do { _ = try await first.value; Issue.record("Cancelled load was published") } catch is CancellationError { }
        #expect(try await second.value.allTime.total == 200)
        #expect(try await reader.load(codexHome: a).allTime.total == 100)
    }
}
