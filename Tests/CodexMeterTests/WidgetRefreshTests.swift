import Darwin
import Foundation
import Testing
@testable import CodexMeter

struct WidgetRefreshTests {
    private let now = Date(timeIntervalSince1970: 1_791_000_000)

    @Test func switchingWindowsDoesNotPostponeRefreshAndWakeCatchesUp() {
        #expect(RefreshPolicy.nextRefreshDate(lastAttempt: now, interval: 900, now: now.addingTimeInterval(600))
            == now.addingTimeInterval(900))
        #expect(RefreshPolicy.nextRefreshDate(lastAttempt: now, interval: 300, now: now.addingTimeInterval(600))
            == now.addingTimeInterval(600))
        #expect(RefreshPolicy.nextRefreshDate(lastAttempt: now, interval: 900, now: now.addingTimeInterval(3_600))
            == now.addingTimeInterval(3_600))
        #expect(RefreshPolicy.nextRefreshDate(lastAttempt: nil, interval: 900, now: now) == now)
        #expect(RefreshPolicy.nextRefreshDate(lastAttempt: now.addingTimeInterval(300), interval: 900, now: now) == now)
    }

    @Test func heartbeatUpdatesCacheWithoutInventingANewQuotaSample() throws {
        let file = try fixture().appendingPathComponent("codex-usage.json")
        let first = usage()
        #expect(try WidgetUsageCache.saveIfChanged(first, to: file))
        var checked = copy(first, updatedAt: now.addingTimeInterval(899))
        #expect(try !WidgetUsageCache.saveIfChanged(checked, to: file))
        checked = copy(first, updatedAt: now.addingTimeInterval(900))
        #expect(try WidgetUsageCache.saveIfChanged(checked, to: file))
        let loaded = try #require(WidgetUsageCache.load(from: file))
        #expect(loaded.updatedAt == checked.updatedAt)
        #expect(loaded.sampledAt == first.sampledAt)
        #expect(!loaded.isStale(at: checked.updatedAt.addingTimeInterval(900)))
        #expect(loaded.quotaSample(at: checked.updatedAt).isStale)
    }

    @Test func clockCorrectionAndChangedUsageAreNotSuppressedByHeartbeat() throws {
        let file = try fixture().appendingPathComponent("codex-usage.json")
        let first = usage()
        #expect(try WidgetUsageCache.saveIfChanged(first, to: file))
        let earlier = copy(first, updatedAt: now.addingTimeInterval(-300))
        #expect(try WidgetUsageCache.saveIfChanged(earlier, to: file))
        #expect(WidgetUsageCache.load(from: file)?.updatedAt == earlier.updatedAt)
        let changed = usage(tokens: 4_000_000)
        #expect(try WidgetUsageCache.saveIfChanged(changed, to: file))
        #expect(WidgetUsageCache.load(from: file)?.todayTokens == 4_000_000)
    }

    @Test func missingAndCorruptCachesStillProduceARetryTimeline() throws {
        let file = try fixture().appendingPathComponent("codex-usage.json")
        #expect(WidgetUsageCache.load(from: file) == nil)
        try Data("incomplete cache".utf8).write(to: file)
        #expect(WidgetUsageCache.load(from: file) == nil)
        let schedule = WidgetTimelineSchedule(usage: WidgetUsageCache.load(from: file), now: now)
        #expect(schedule.dates == [now, now.addingTimeInterval(300)])
        #expect(schedule.reloadAt == now.addingTimeInterval(300))
        #expect(try WidgetUsageCache.saveIfChanged(usage(), to: file))
        #expect(WidgetUsageCache.load(from: file) == usage())
    }

    @Test func timelineKeepsExpiryAndStalenessTransitionsWithinItsReloadWindow() {
        let data = usage()
        let schedule = WidgetTimelineSchedule(usage: data, now: now)
        #expect(schedule.dates == [now, now.addingTimeInterval(900), now.addingTimeInterval(1_800)])
        #expect(schedule.reloadAt == now.addingTimeInterval(1_800))
        let later = now.addingTimeInterval(1_000)
        let stale = WidgetTimelineSchedule(usage: data, now: later)
        #expect(stale.dates.contains(now.addingTimeInterval(1_801)))
        #expect(data.isStale(at: now.addingTimeInterval(1_801)))
        #expect(stale.dates == stale.dates.sorted())
        #expect(Set(stale.dates).count == stale.dates.count)
        #expect(stale.dates.allSatisfy { $0 >= later && $0 <= stale.reloadAt })
        let expired = WidgetTimelineSchedule(usage: data, now: now.addingTimeInterval(90_000))
        #expect(expired.dates.count == 2)
        #expect(data.recordedRatePercent(at: expired.dates[0]) == nil)
    }

    @Test func recoveryRejectsCurrentOtherInstallationsOtherUsersAndInvalidPIDs() {
        let path = "/synthetic/Codex Health.app/Contents/PlugIns/CodexMeterWidget.appex/Contents/MacOS/CodexMeterWidget"
        func matches(pid: pid_t = 123, path candidate: String? = nil, start: Date? = nil, uid: uid_t = 501) -> Bool {
            WidgetExtensionRecovery.ProcessIdentity(pid: pid, executablePath: candidate ?? path,
                startedAt: start ?? now.addingTimeInterval(-86_400), userID: uid)
                .predatesInstalledBinary(at: path, modifiedAt: now, userID: 501)
        }
        #expect(matches())
        #expect(!matches(start: now))
        #expect(!matches(start: now.addingTimeInterval(1)))
        #expect(!matches(path: "/other/CodexMeterWidget"))
        #expect(!matches(path: path + "-other"))
        #expect(!matches(uid: 502))
        #expect(!matches(pid: 0))
        #expect(!matches(pid: 1))
        #expect(!matches(pid: -1))
    }

    @Test func recoveryRetiresOnlyAnOutdatedSyntheticExtensionProcess() async throws {
        let executable = try fixture().appendingPathComponent("SyntheticWidget")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/sleep"), to: executable)
        func launch(_ url: URL) throws -> Process {
            let process = Process()
            process.executableURL = url
            process.arguments = ["30"]
            try process.run()
            return process
        }
        let old = try launch(executable)
        defer { if old.isRunning { old.terminate() } }
        try await Task.sleep(for: .milliseconds(20))
        let updateDate = Date.now
        try await Task.sleep(for: .milliseconds(20))
        let current = try launch(executable)
        defer { if current.isRunning { current.terminate() } }
        let unrelated = try launch(URL(fileURLWithPath: "/bin/sleep"))
        defer { if unrelated.isRunning { unrelated.terminate() } }
        let retired = WidgetExtensionRecovery.retireOutdatedProcesses(at: executable.path, modifiedAt: updateDate)
        #expect(retired == [old.processIdentifier])
        old.waitUntilExit()
        #expect(!old.isRunning)
        #expect(current.isRunning)
        #expect(unrelated.isRunning)
        #expect(WidgetExtensionRecovery.retireOutdatedProcesses(at: executable.path, modifiedAt: updateDate).isEmpty)
    }

    private func usage(tokens: Int = 3_731_923) -> WidgetUsageData {
        WidgetUsageData(todayTokens: tokens, weekTokens: 1_376_638_466, monthTokens: 1_792_003_171,
            contextTokens: 141_007, contextLimit: 475_000, ratePercent: 21, rateWindowMinutes: 10_080,
            updatedAt: now, sampledAt: now, rateResetsAt: now.addingTimeInterval(86_400), contextID: "synthetic")
    }

    private func copy(_ value: WidgetUsageData, updatedAt: Date) -> WidgetUsageData {
        WidgetUsageData(todayTokens: value.todayTokens, weekTokens: value.weekTokens, monthTokens: value.monthTokens,
            contextTokens: value.contextTokens, contextLimit: value.contextLimit, ratePercent: value.ratePercent,
            rateWindowMinutes: value.rateWindowMinutes, updatedAt: updatedAt, sampledAt: value.sampledAt,
            rateResetsAt: value.rateResetsAt, contextID: value.contextID)
    }

    private func fixture() throws -> URL {
        let url = TestFixtureDirectory.root.appendingPathComponent("widget-refresh-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
