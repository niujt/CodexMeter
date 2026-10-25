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

    @Test func normalPublicationSkipsUnchangedContentAndManualRefreshReloadsOnce() throws {
        let file = try fixture().appendingPathComponent("codex-usage.json")
        let first = usage()
        var reloadCount = 0
        try WidgetUsageCache.publish(first, to: file) { reloadCount += 1 }
        #expect(reloadCount == 1)

        let checked = copy(first, updatedAt: now.addingTimeInterval(60))
        try WidgetUsageCache.publish(checked, to: file) { reloadCount += 1 }
        #expect(reloadCount == 1)
        try WidgetUsageCache.publish(checked, forceReload: true, to: file) { reloadCount += 1 }
        #expect(reloadCount == 2)
        #expect(WidgetUsageCache.load(from: file)?.sampledAt == first.sampledAt)

        try WidgetUsageCache.publish(usage(tokens: 4_000_000), to: file) { reloadCount += 1 }
        #expect(reloadCount == 3)
        #expect(WidgetUsageCache.load(from: file)?.todayTokens == 4_000_000)
    }

    @Test func completenessTransitionsPublishEvenWhenTotalsMatchWithoutRenewingQuota() throws {
        let file = try fixture().appendingPathComponent("codex-usage.json")
        var data = usage(tokens: 0)
        var reloadCount = 0
        try WidgetUsageCache.publish(data, to: file) { reloadCount += 1 }
        data.sourceIncomplete = true
        try WidgetUsageCache.publish(data, to: file) { reloadCount += 1 }
        let incomplete = try #require(WidgetUsageCache.load(from: file))
        #expect(incomplete.sourceIncomplete == true)
        #expect(incomplete.todayTokens == 0)
        #expect(incomplete.sampledAt == now)
        #expect(incomplete.recordedRatePercent(at: now.addingTimeInterval(1_800)) == 21)
        #expect(incomplete.quotaSample(at: now.addingTimeInterval(1_800)).isStale)
        #expect(reloadCount == 2)

        data.sourceIncomplete = false
        try WidgetUsageCache.publish(data, to: file) { reloadCount += 1 }
        #expect(WidgetUsageCache.load(from: file)?.sourceIncomplete == false)
        #expect(reloadCount == 3)
    }

    @Test func failedPublicationDoesNotReloadEvenWhenManuallyRequested() throws {
        let file = try fixture().appendingPathComponent("missing-parent/codex-usage.json")
        var reloadCount = 0
        do {
            try WidgetUsageCache.publish(usage(), forceReload: true, to: file) { reloadCount += 1 }
            Issue.record("Publishing to a missing parent directory should fail")
        } catch {
            #expect(reloadCount == 0)
        }
        #expect(WidgetUsageCache.load(from: file) == nil)
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

    @Test func remainingQuotaTintUsesExactFiftyAndTwentyPercentBoundaries() {
        let cases: [(used: Double, tint: QuotaRemainingTint)] = [
            (0, .green), (44, .green), (49.999, .green),
            (50, .yellow), (79.999, .yellow), (80, .yellow),
            (80.001, .red), (81, .red), (100, .red)
        ]
        for item in cases {
            let sample = QuotaSampleState(percent: item.used, sampledAt: now,
                                          resetsAt: now.addingTimeInterval(3_600), now: now)
            #expect(sample.remainingTint == item.tint)
            #expect(sample.recordedPercent == item.used)
            #expect(!sample.isStale)
        }
    }

    @Test func oldQuotaKeepsItsRecordedTintUntilTheCycleActuallyEnds() {
        let cases: [(used: Double, tint: QuotaRemainingTint)] = [(0, .green), (50, .yellow), (80, .yellow), (100, .red)]
        for item in cases {
            let reset = now.addingTimeInterval(3_600)
            let sample = QuotaSampleState(percent: item.used, sampledAt: now, resetsAt: reset,
                                          now: now.addingTimeInterval(QuotaSampleState.lifetime))
            #expect(sample.isStale)
            #expect(sample.currentPercent == nil)
            #expect(sample.recordedPercent == item.used)
            #expect(sample.remainingTint == item.tint)
            let expired = QuotaSampleState(percent: item.used, sampledAt: now, resetsAt: reset, now: reset)
            #expect(expired.recordedPercent == nil)
            #expect(expired.remainingTint == .unknown)
        }
    }

    @Test func missingInvalidExpiredAndFutureQuotaSamplesUseUnknownTint() {
        let futureReset = now.addingTimeInterval(3_600)
        let unknownSamples = [
            QuotaSampleState(percent: nil, sampledAt: now, resetsAt: futureReset, now: now),
            QuotaSampleState(percent: 44, sampledAt: nil, resetsAt: futureReset, now: now),
            QuotaSampleState(percent: 44, sampledAt: now, resetsAt: nil, now: now),
            QuotaSampleState(percent: 44, sampledAt: now.addingTimeInterval(1), resetsAt: futureReset, now: now),
            QuotaSampleState(percent: 44, sampledAt: now.addingTimeInterval(-60), resetsAt: now, now: now),
            QuotaSampleState(percent: 44, sampledAt: now.addingTimeInterval(-60), resetsAt: now.addingTimeInterval(-1), now: now)
        ] + [-1.0, 101.0, Double.nan, Double.infinity, -Double.infinity].map {
            QuotaSampleState(percent: $0, sampledAt: now, resetsAt: futureReset, now: now)
        }
        for sample in unknownSamples {
            #expect(sample.remainingTint == .unknown)
            #expect(sample.recordedPercent == nil)
        }
    }

    @Test func recoveryRequiresDifferentCodeFromTheSameInstallationUserAndSigningIdentity() {
        let path = "/synthetic/Codex Health.app/Contents/PlugIns/CodexMeterWidget.appex/Contents/MacOS/CodexMeterWidget"
        let installed = WidgetExtensionRecovery.CodeIdentity(identifier: "test.widget", teamID: "TESTTEAM", hash: Data([2]))
        let old = WidgetExtensionRecovery.CodeIdentity(identifier: "test.widget", teamID: "TESTTEAM", hash: Data([1]))
        func matches(pid: pid_t = 123, path candidate: String? = nil, originalPath: String? = nil, start: Date? = nil,
                     uid: uid_t = 501, code: WidgetExtensionRecovery.CodeIdentity? = nil) -> Bool {
            WidgetExtensionRecovery.ProcessIdentity(pid: pid, executablePath: candidate ?? path,
                startedAt: start ?? now.addingTimeInterval(-86_400), userID: uid, code: code ?? old,
                originalExecutablePath: originalPath)
                .requiresReplacement(at: path, installedCode: installed, userID: 501)
        }
        #expect(matches())
        // Package timestamps are preserved by installers; the code identity is authoritative.
        #expect(matches(start: now.addingTimeInterval(1)))
        #expect(!matches(code: installed))
        #expect(!matches(code: .init(identifier: "other.widget", teamID: "TESTTEAM", hash: Data([1]))))
        #expect(!matches(code: .init(identifier: "test.widget", teamID: "OTHERTEAM", hash: Data([1]))))
        #expect(!matches(path: "/other/CodexMeterWidget"))
        #expect(!matches(path: path + "-other"))
        #expect(!matches(uid: 502))
        #expect(!matches(pid: 0))
        #expect(!matches(pid: 1))
        #expect(!matches(pid: -1))
        #expect(matches(path: "/backup/CodexMeterWidget", originalPath: path))
        #expect(!matches(path: "/backup/CodexMeterWidget", originalPath: path, code: installed))
        #expect(!matches(path: "/backup/CodexMeterWidget", originalPath: path, uid: 502))
        #expect(!matches(path: "/backup/CodexMeterWidget", originalPath: path,
                         code: .init(identifier: "test.widget", teamID: "OTHERTEAM", hash: Data([1]))))
        #expect(!matches(path: "/backup/CodexMeterWidget", originalPath: "/other/CodexMeterWidget"))
    }

    @Test func originalExecPathIsReadBeforeArgumentsAndRejectsMalformedKernelData() {
        let path = "/synthetic/Widget"
        let data: [UInt8] = [2, 0, 0, 0] + Array(path.utf8) + [0, 0] + Array("/forged/argv-zero".utf8) + [0]
        #expect(WidgetExtensionRecovery.originalExecutablePath(from: data) == path)
        #expect(WidgetExtensionRecovery.originalExecutablePath(from: []) == nil)
        #expect(WidgetExtensionRecovery.originalExecutablePath(from: [1, 0, 0, 0, 0]) == nil)
        #expect(WidgetExtensionRecovery.originalExecutablePath(from: [1, 0, 0, 0] + Array(path.utf8)) == nil)
        #expect(WidgetExtensionRecovery.originalExecutablePath(from: [1, 0, 0, 0] + Array("relative".utf8) + [0]) == nil)
        #expect(WidgetExtensionRecovery.originalExecutablePath(from: [1, 0, 0, 0, 47, 255, 0]) == nil)
    }

    @Test func recoveryRetiresOnlyAnOutdatedSyntheticExtensionProcess() async throws {
        let location = try fixture().appendingPathComponent("SyntheticWidget")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/sleep"), to: location)
        // proc_pidpath uses /private/var; Foundation's URL resolver preserves
        // the /var alias for temporary directories. Match the kernel via realpath.
        let physicalPath = try #require(realpath(location.path, nil))
        defer { free(physicalPath) }
        let executable = URL(fileURLWithPath: String(cString: physicalPath))
        func launch(_ url: URL) throws -> Process {
            let process = Process()
            process.executableURL = url
            process.arguments = ["30"]
            try process.run()
            return process
        }
        let old = try launch(executable)
        defer { if old.isRunning { old.terminate() } }
        let unrelated = try launch(URL(fileURLWithPath: "/bin/sleep"))
        defer { if unrelated.isRunning { unrelated.terminate() } }
        let code = try #require(WidgetExtensionRecovery.installedCode(at: executable.path, processID: old.processIdentifier))
        let process = try #require(WidgetExtensionRecovery.identity(old.processIdentifier))
        #expect(process.executablePath == executable.path)
        #expect(process.code == code)
        // Exercise the fallback reader without deleting a fixture executable.
        let originalPath = try #require(WidgetExtensionRecovery.originalExecutablePath(old.processIdentifier))
        #expect(originalPath == location.path || originalPath == executable.path)
        #expect(WidgetExtensionRecovery.retireOutdatedProcesses(at: executable.path).isEmpty)
        #expect(old.isRunning)
        var futureHash = code.hash
        futureHash[0] ^= 1
        let futureCode = WidgetExtensionRecovery.CodeIdentity(identifier: code.identifier, teamID: code.teamID, hash: futureHash)
        let retired = WidgetExtensionRecovery.retireOutdatedProcesses(at: executable.path, installedCode: futureCode)
        try #require(retired == [old.processIdentifier])
        old.waitUntilExit()
        #expect(!old.isRunning)
        #expect(unrelated.isRunning)
        #expect(WidgetExtensionRecovery.retireOutdatedProcesses(at: executable.path, installedCode: futureCode).isEmpty)
    }

    @Test func recoveryFindsAMovedOldExecutableWithoutRetiringTheCurrentOrAnotherInstallation() throws {
        let directory = try fixture()
        let installed = directory.appendingPathComponent("SyntheticWidget")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/sleep"), to: installed)
        let physicalPath = try #require(realpath(installed.path, nil))
        defer { free(physicalPath) }
        let executable = URL(fileURLWithPath: String(cString: physicalPath))
        func launch(_ url: URL) throws -> Process {
            let process = Process()
            process.executableURL = url
            process.arguments = ["30"]
            try process.run()
            return process
        }
        let old = try launch(executable)
        defer { if old.isRunning { old.terminate() } }
        let backup = executable.deletingLastPathComponent().appendingPathComponent("BackupWidget")
        try FileManager.default.moveItem(at: executable, to: backup)
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/sleep"), to: executable)
        let anotherInstallation = try launch(backup)
        defer { if anotherInstallation.isRunning { anotherInstallation.terminate() } }

        let moved = try #require(WidgetExtensionRecovery.identity(old.processIdentifier))
        #expect(moved.executablePath == backup.path)
        #expect(moved.originalExecutablePath == executable.path)
        let other = try #require(WidgetExtensionRecovery.identity(anotherInstallation.processIdentifier))
        #expect(other.originalExecutablePath == backup.path)
        let installedCode = try #require(WidgetExtensionRecovery.installedCode(at: executable.path,
                                                                            processID: old.processIdentifier))
        // Identical code remains alive even when its bundle was moved.
        #expect(WidgetExtensionRecovery.retireOutdatedProcesses(at: executable.path).isEmpty)
        // Give the current executable a different real code identity, preserving
        // its signing identifier, so the full process-discovery path is tested.
        let signing = Process()
        signing.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        signing.arguments = ["--force", "--sign", "-", "--identifier", installedCode.identifier,
                             "--options", "runtime", executable.path]
        try signing.run()
        signing.waitUntilExit()
        #expect(signing.terminationStatus == 0)
        let current = try launch(executable)
        defer { if current.isRunning { current.terminate() } }
        let updatedCode = try #require(WidgetExtensionRecovery.installedCode(at: executable.path,
                                                                          processID: current.processIdentifier))
        #expect(updatedCode.hash != moved.code.hash)
        let retired = WidgetExtensionRecovery.retireOutdatedProcesses(at: executable.path)
        try #require(retired == [old.processIdentifier])
        old.waitUntilExit()
        #expect(current.isRunning)
        #expect(anotherInstallation.isRunning)
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
            rateResetsAt: value.rateResetsAt, sourceIncomplete: value.sourceIncomplete, contextID: value.contextID)
    }

    private func fixture() throws -> URL {
        let url = TestFixtureDirectory.root.appendingPathComponent("widget-refresh-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
