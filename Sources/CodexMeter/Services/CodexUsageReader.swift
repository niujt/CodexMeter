import Foundation
import CryptoKit

actor CodexUsageReader {
    private struct FileFingerprint: Equatable, Codable {
        let path: String
        let modifiedAt: Date
        let size: Int
    }

    private let fileManager: FileManager
    private let calendar: Calendar
    private struct CachedFile: Codable {
        let fingerprint: FileFingerprint
        let summary: SessionSummary
    }
    private var fileCache: [String: CachedFile] = [:]
    private var cacheRoot: String?
    private var cacheNeedsPersistence = false
    private(set) var cacheWarning: String?
    private let cacheDirectory: URL?
    private struct DiskCache: Codable {
        let version: Int
        let root: String
        let calendarID: String
        let timeZoneID: String
        let files: [String: CachedFile]
    }
    private(set) var parsedFileCount = 0
    private(set) var reusedFileCount = 0
    private(set) var enumeratedEntryCount = 0
    private let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private let wholeSecondFormatter = ISO8601DateFormatter()

    init(fileManager: FileManager = .default, calendar: Calendar = .current, cacheDirectory: URL? = nil) {
        self.fileManager = fileManager
        self.calendar = calendar
        self.cacheDirectory = cacheDirectory
    }

    static func defaultCacheDirectory() -> URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("CodexHealth/usage-summaries-v1", isDirectory: true)
    }

    private func cacheURL(for root: String) -> URL? {
        let key = SHA256.hash(data: Data(root.utf8)).map { String(format: "%02x", $0) }.joined()
        return cacheDirectory?.appendingPathComponent(key + ".plist")
    }

    private func restoreCache(for root: String) -> [String: CachedFile] {
        guard let url = cacheURL(for: root),
              let data = try? Data(contentsOf: url),
              let cache = try? PropertyListDecoder().decode(DiskCache.self, from: data),
              cache.version == 1, cache.root == root,
              cache.calendarID == String(describing: calendar.identifier),
              cache.timeZoneID == calendar.timeZone.identifier else { return [:] }
        return cache.files
    }

    private func persistCache(for root: String) {
        guard let url = cacheURL(for: root) else { return }
        // Cache failures must never prevent fresh usage from being displayed.
        do {
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            let payload = DiskCache(version: 1, root: root,
                                    calendarID: String(describing: calendar.identifier),
                                    timeZoneID: calendar.timeZone.identifier, files: fileCache)
            try encoder.encode(payload).write(to: url, options: .atomic)
            cacheNeedsPersistence = false
            cacheWarning = nil
        } catch {
            cacheNeedsPersistence = true
            cacheWarning = "统计缓存保存失败，下次启动可能需要重新读取：\(error.localizedDescription)"
        }
    }

    func load(now: Date = .now, codexHome: URL? = nil, force: Bool = false,
              onProgress: (@Sendable (UsageSnapshot, Int, Int) async -> Void)? = nil) async throws -> UsageSnapshot {
        try await loadWithActivity(now: now, codexHome: codexHome, force: force, onActivity: nil, onProgress: onProgress)
    }

    func loadWithActivity(now: Date = .now, codexHome: URL? = nil, force: Bool = false,
                          onActivity: (@Sendable (Int, Int) async -> Void)?,
                          onProgress: (@Sendable (UsageSnapshot, Int, Int) async -> Void)? = nil) async throws -> UsageSnapshot {
        let root = codexHome ?? resolvedCodexHome()
        // When the user selects .codex via the native folder picker, macOS
        // grants scope to that selected root. Enumerating from the root is
        // more reliable than starting a new traversal at a child directory.
        let files = try jsonlFiles(in: root)
        if cacheRoot != root.path {
            fileCache = restoreCache(for: root.path)
            cacheRoot = root.path
            cacheNeedsPersistence = false
            cacheWarning = nil
        }
        let paths = Set(files.map(\.path))
        var cacheChanged = fileCache.keys.contains { !paths.contains($0) }
        fileCache = fileCache.filter { paths.contains($0.key) }
        parsedFileCount = 0
        reusedFileCount = 0
        let startOfToday = calendar.startOfDay(for: now)

        var snapshot = UsageSnapshot.empty
        snapshot.dataPath = root.path
        snapshot.dataDirectoryExists = fileManager.fileExists(atPath: root.path)
        snapshot.fileCount = files.count
        var latestRateEvent: (event: TokenEvent, isPreferred: Bool)?
        var latestPreferredMainMenuRate: (window: RateWindow, timestamp: Date, limitID: String?)?
        var latestFallbackMainMenuRate: (window: RateWindow, timestamp: Date, limitID: String?)?
        var hasCanonicalQuotaObservation = false
        var latestSparkRateTimestamp = Date.distantPast
        var projects: [String: ProjectAccumulator] = [:]
        var todayProjects: [String: ProjectAccumulator] = [:]
        var monthProjects: [String: ProjectAccumulator] = [:]
        var models: [String: ModelAccumulator] = [:]
        var daily: [Date: Int] = [:]
        let sevenDaysAgo = calendar.date(byAdding: .day, value: -6, to: startOfToday) ?? startOfToday
        let thirtyDaysAgo = calendar.date(byAdding: .day, value: -29, to: startOfToday) ?? startOfToday
        let monthInterval = calendar.dateInterval(of: .month, for: now)

        var failedFiles = 0
        var malformedLines = 0
        var latestContextTimestamp = Date.distantPast
        func finalizedSnapshot() -> UsageSnapshot {
            var snapshot = snapshot
            // Once the canonical bucket has been observed, an alternate bucket is
            // never a valid substitute for it. Right after a reset the canonical
            // bucket may not have produced a fresh event yet; showing no value is
            // safer than reporting another model's 0% usage as the main quota.
            let selectedMainMenuRate = latestPreferredMainMenuRate
                ?? (hasCanonicalQuotaObservation ? nil : latestFallbackMainMenuRate)
            snapshot.mainMenuRate = selectedMainMenuRate?.window
            snapshot.selectedRateLimitID = selectedMainMenuRate?.limitID

            // A session can emit many quota samples during the same seven-day
            // period.  They are observations, not resets.  Keep the newest sample
            // for each reset day so the history is a timeline of quota periods
            // rather than a list of near-identical refreshes.
            let relevantTimeline = snapshot.rateTimeline.filter {
                snapshot.selectedRateLimitID == nil || $0.limitID == snapshot.selectedRateLimitID
            }
            var latestSampleByCycle: [String: RateTimelineEvent] = [:]
            for event in relevantTimeline {
                let resetDay = calendar.startOfDay(for: event.resetsAt).timeIntervalSince1970
                let limitID = event.limitID ?? "unknown"
                let cycleKey = "\(limitID)-\(Int(resetDay))"
                if let existing = latestSampleByCycle[cycleKey], existing.date >= event.date { continue }
                latestSampleByCycle[cycleKey] = event
            }
            snapshot.rateTimeline = latestSampleByCycle.values.sorted { $0.date > $1.date }
            snapshot.allProjects = ranked(projects)
            snapshot.topProjects = Array(snapshot.allProjects.prefix(4))
            snapshot.todayProjects = ranked(todayProjects)
            snapshot.monthProjects = ranked(monthProjects)
            let rankedModels = models.map {
                ModelUsage(
                    name: $0.key,
                    tokens: $0.value.tokens,
                    requests: $0.value.requests,
                    averageTurnSeconds: $0.value.timedTurns > 0
                        ? $0.value.turnSeconds / Double($0.value.timedTurns)
                        : nil,
                    cacheHitRate: $0.value.cacheHitRate
                )
            }
                .sorted { $0.tokens > $1.tokens }
            snapshot.panelModels = Array(rankedModels.prefix(4))
            snapshot.topModels = rankedModels
                .filter { !isSparkModel($0.name) }
                .prefix(4)
                .map { $0 }
            snapshot.dailyUsage = daily.map { DailyUsage(date: $0.key, tokens: $0.value) }.sorted { $0.date < $1.date }
            return snapshot
        }

        var lastPublished = Date.distantPast
        for (index, file) in files.enumerated() {
            try Task.checkCancellation()
            if let onProgress, index <= 1 || Date.now.timeIntervalSince(lastPublished) >= 0.3 {
                await onActivity?(parsedFileCount, reusedFileCount)
                await onProgress(finalizedSnapshot(), index, files.count)
                lastPublished = .now
            }
            let summary: SessionSummary
            do {
                let fingerprint = try fileFingerprint(for: file)
                if !force, let cached = fileCache[file.path], cached.fingerprint == fingerprint {
                    summary = cached.summary
                    reusedFileCount += 1
                } else {
                    parsedFileCount += 1
                    await onActivity?(parsedFileCount, reusedFileCount)
                    let parsed = try parseSession(file, speedWindowStart: now.addingTimeInterval(-RecentReplySpeed.windowSeconds))
                    cacheChanged = true
                    // Do not cache a moving target; retry it on the next refresh.
                    if try fileFingerprint(for: file) == fingerprint {
                        fileCache[file.path] = CachedFile(fingerprint: fingerprint, summary: parsed)
                    } else {
                        fileCache[file.path] = nil
                    }
                    summary = parsed
                }
            } catch {
                failedFiles += 1
                guard let cached = fileCache[file.path] else { continue }
                summary = cached.summary
                reusedFileCount += 1
            }
            malformedLines += summary.malformedLines
            guard let event = summary.latestEvent else { continue }
            snapshot.sessionCount += 1
            snapshot.allTime = snapshot.allTime + summary.total
            snapshot.replySpeedSamples += summary.replySpeedSamples.filter {
                $0.completedAt > now.addingTimeInterval(-RecentReplySpeed.windowSeconds) && $0.completedAt <= now
            }
            let projectPath = summary.project
            var weekTokens = 0, todayTokens = 0, monthTokens = 0
            var weekDate: Date?, todayDate: Date?, monthDate: Date?
            for (key, bucket) in summary.buckets where key.hour <= now {
                let usage = bucket.usage
                if key.hour >= sevenDaysAgo {
                    weekTokens += usage.total
                    weekDate = max(weekDate ?? .distantPast, bucket.lastActive)
                    daily[calendar.startOfDay(for: key.hour), default: 0] += usage.total
                    models[key.model, default: .empty].add(bucket)
                    snapshot.lastSevenDays = snapshot.lastSevenDays + usage
                }
                if key.hour >= startOfToday {
                    todayTokens += usage.total
                    todayDate = max(todayDate ?? .distantPast, bucket.lastActive)
                    snapshot.today = snapshot.today + usage
                }
                if key.hour >= thirtyDaysAgo {
                    monthTokens += usage.total
                    monthDate = max(monthDate ?? .distantPast, bucket.lastActive)
                    if usage.total > 0 {
                        snapshot.recentRecords.append(UsageRecord(date: key.hour, project: projectPath, model: key.model, tokens: usage.total))
                    }
                }
                if let monthInterval, monthInterval.contains(key.hour) {
                    snapshot.thisMonth = snapshot.thisMonth + usage
                }
            }
            if let weekDate { projects[projectPath, default: .empty].add(tokens: weekTokens, date: weekDate) }
            if let todayDate { todayProjects[projectPath, default: .empty].add(tokens: todayTokens, date: todayDate) }
            if let monthDate { monthProjects[projectPath, default: .empty].add(tokens: monthTokens, date: monthDate) }
            if event.timestamp > latestContextTimestamp {
                latestContextTimestamp = event.timestamp
                snapshot.currentContextUsed = event.currentContextUsed
                snapshot.contextWindow = event.contextWindow
                snapshot.lastUpdated = event.timestamp
            }

            // The official Codex status panel follows the newest event from the
            // canonical Codex quota. Other model buckets (for example
            // codex_bengalfox) can emit a newer event with a different reset
            // time; letting those events win makes the main percentage jump
            // back to 100% immediately after a weekly reset.
            let rateEvent = summary.preferredRateEvent ?? event
            let eventIsPreferred = isCanonicalQuota(rateEvent.rateLimitID)
            if summary.hasCanonicalQuota { hasCanonicalQuotaObservation = true }
            if shouldReplaceRateEvent(current: latestRateEvent, candidate: rateEvent, candidateIsPreferred: eventIsPreferred) {
                latestRateEvent = (rateEvent, eventIsPreferred)
                // A token_count event can still contain the previous cycle's
                // window for a short period after its reset time. Do not let
                // that expired sample become the app's current quota.
                snapshot.primaryRate = activeRate(rateEvent.primaryRate, at: now)
                snapshot.secondaryRate = activeRate(rateEvent.secondaryRate, at: now)
                snapshot.selectedRateLimitID = event.rateLimitID
            }

            for sample in summary.quotaSamples.values where sample.event.timestamp >= thirtyDaysAgo {
                guard let window = [sample.event.primaryRate, sample.event.secondaryRate]
                    .compactMap({ $0 })
                    .first(where: { $0.windowMinutes == 10_080 }) else { continue }
                if isSparkModel(sample.model) {
                    guard window.resetsAt > now else { continue }
                    if sample.event.timestamp >= latestSparkRateTimestamp {
                        snapshot.sparkRate = window
                        latestSparkRateTimestamp = sample.event.timestamp
                    }
                } else {
                    snapshot.rateTimeline.append(
                        RateTimelineEvent(
                            date: sample.event.timestamp,
                            usedPercent: window.usedPercent,
                            resetsAt: window.resetsAt,
                            limitID: sample.event.rateLimitID
                        )
                    )
                    guard window.resetsAt > now else { continue }
                    let candidate = (window: window, timestamp: sample.event.timestamp, limitID: sample.event.rateLimitID)
                    if isCanonicalQuota(sample.event.rateLimitID) {
                        if latestPreferredMainMenuRate == nil || sample.event.timestamp > latestPreferredMainMenuRate!.timestamp {
                            latestPreferredMainMenuRate = candidate
                        }
                    } else if latestFallbackMainMenuRate == nil || sample.event.timestamp > latestFallbackMainMenuRate!.timestamp {
                        latestFallbackMainMenuRate = candidate
                    }
                }
            }
        }

        if !files.isEmpty, failedFiles == files.count {
            throw UsageReadError.unavailable("所有会话文件均读取失败，已保留上次成功结果。")
        }
        if failedFiles > 0 || malformedLines > 0 {
            snapshot.readWarning = "部分数据不完整：\(failedFiles) 个文件读取失败，\(malformedLines) 条记录无法解析；读取失败的文件优先沿用缓存。"
        }

        await onActivity?(parsedFileCount, reusedFileCount)
        await onProgress?(finalizedSnapshot(), files.count, files.count)
        if cacheChanged || cacheNeedsPersistence { persistCache(for: root.path) }
        return finalizedSnapshot()
    }

    private func ranked(_ values: [String: ProjectAccumulator]) -> [ProjectUsage] {
        values.map { ProjectUsage(path: $0.key, tokens: $0.value.tokens, sessions: $0.value.sessions, lastActive: $0.value.lastActive) }
            .sorted { $0.tokens == $1.tokens ? ($0.lastActive ?? .distantPast) > ($1.lastActive ?? .distantPast) : $0.tokens > $1.tokens }
    }

    private func resolvedCodexHome() -> URL {
        if let bundledPath = Bundle.main.object(forInfoDictionaryKey: "CodexHome") as? String,
           !bundledPath.isEmpty {
            return URL(fileURLWithPath: bundledPath, isDirectory: true)
        }
        if let configured = ProcessInfo.processInfo.environment["CODEX_HOME"],
           !configured.isEmpty {
            return URL(fileURLWithPath: configured, isDirectory: true)
        }
        let home = ProcessInfo.processInfo.environment["HOME"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? fileManager.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".codex", isDirectory: true)
    }

    private func jsonlFiles(in directory: URL) throws -> [URL] {
        enumeratedEntryCount = 0
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey])
        guard values.isDirectory == true else {
            throw UsageReadError.unavailable("所选路径不是目录。")
        }
        var traversalError: Error?
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles],
            errorHandler: { _, error in traversalError = error; return false }
        ) else { throw UsageReadError.unavailable("无法访问数据目录，请重新授权。") }
        let sessionDirectories = Set(["sessions", "archived_sessions"])
        let isCodexRoot = directory.lastPathComponent == ".codex" || sessionDirectories.contains {
            fileManager.fileExists(atPath: directory.appendingPathComponent($0).path)
        }
        let rootPrefix = directory.standardizedFileURL.path + "/"
        var files: [URL] = []
        for case let url as URL in enumerator {
            enumeratedEntryCount += 1
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            if isCodexRoot {
                let relative = String(url.standardizedFileURL.path.dropFirst(rootPrefix.count))
                let firstComponent = relative.split(separator: "/").first.map(String.init) ?? ""
                if !sessionDirectories.contains(firstComponent) {
                    if values.isDirectory == true { enumerator.skipDescendants() }
                    continue
                }
            }
            if url.pathExtension == "jsonl", values.isRegularFile == true { files.append(url) }
        }
        if let traversalError { throw traversalError }
        return files.sorted {
            let left = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let right = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return left == right ? $0.path < $1.path : left > right
        }
    }

    private func fileFingerprint(for file: URL) throws -> FileFingerprint {
        let attributes = try fileManager.attributesOfItem(atPath: file.path)
        guard let modifiedAt = attributes[.modificationDate] as? Date,
              let size = attributes[.size] as? NSNumber else {
            throw UsageReadError.unavailable("无法读取会话文件属性。")
        }
        return FileFingerprint(path: file.path, modifiedAt: modifiedAt, size: size.intValue)
    }

    // Stream changed files once, retaining aggregates, turn timing and quota metadata.
    // Unchanged files reuse their summaries, including when the calendar day changes.
    private func parseSession(_ file: URL, speedWindowStart: Date) throws -> SessionSummary {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var summary = SessionSummary(replySpeedStart: speedWindowStart)
        var buffer = Data()
        var droppingOversizedLine = false
        while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            buffer.append(chunk)
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = Data(buffer[..<newline])
                if !droppingOversizedLine { consume(line, into: &summary, isFinalFragment: false) }
                droppingOversizedLine = false
                buffer.removeSubrange(...newline)
            }
            if buffer.count > 16 * 1024 * 1024 {
                if !droppingOversizedLine { summary.malformedLines += 1 }
                droppingOversizedLine = true
                buffer.removeAll(keepingCapacity: true)
            }
        }
        if !buffer.isEmpty, !droppingOversizedLine {
            // Accept complete JSON without a trailing newline; ignore a writer's partial line.
            consume(buffer, into: &summary, isFinalFragment: true)
        }
        // Final-answer records can precede their last token_count. Wait until
        // task_complete, the next turn, or EOF to include that trailing usage.
        finishReplySpeed(into: &summary)
        if summary.latestEvent == nil, summary.malformedLines > 0 {
            throw UsageReadError.unavailable("会话记录无法解析。")
        }
        return summary
    }

    private func consume(_ line: Data, into summary: inout SessionSummary, isFinalFragment: Bool) {
        guard !line.allSatisfy({ $0 == 0x20 || $0 == 0x0D || $0 == 0x09 }) else { return }
        guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else {
            if !isFinalFragment { summary.malformedLines += 1 }
            return
        }
        guard let payload = json["payload"] as? [String: Any] else { return }
        let type = json["type"] as? String
        let payloadType = payload["type"] as? String
        if type == "session_meta", let cwd = payload["cwd"] as? String { summary.project = cwd }
        if type == "turn_context", let model = payload["model"] as? String, !model.isEmpty { summary.model = model }
        if type == "event_msg", payloadType == "thread_settings_applied",
           let settings = payload["thread_settings"] as? [String: Any],
           let model = settings["model"] as? String, !model.isEmpty { summary.model = model }
        guard let rawDate = json["timestamp"] as? String,
              let date = timestampFormatter.date(from: rawDate) ?? wholeSecondFormatter.date(from: rawDate) else {
            if type == "event_msg", payloadType == "token_count" { summary.malformedLines += 1 }
            return
        }
        let hour = calendar.dateInterval(of: .hour, for: date)?.start ?? date
        if type == "event_msg", payloadType == "token_count" {
            guard let event = TokenEvent(json: json, timestamp: date) else {
                summary.malformedLines += 1
                return
            }
            let previous = summary.previousUsage
            // A lower cumulative total begins a new counter segment (e.g. reset).
            let delta = previous.map { event.total.total < $0.total ? event.total : event.total - $0 } ?? event.total
            if let pending = summary.pendingReply, date >= pending.startedAt {
                let reset = event.total.total < (previous?.total ?? 0)
                let reliableBaseline = previous != nil && summary.previousHasOutputUsage
                let countersConsistent = reset || event.total.output >= (previous?.output ?? 0)
                if event.hasOutputUsage, countersConsistent, reliableBaseline || event.isFirstUsage {
                    summary.pendingReply?.outputTokens += delta.output
                } else {
                    // A cumulative count without a baseline can include output
                    // from before this turn. Never turn it into a speed sample.
                    summary.pendingReply?.hasReliableUsage = false
                }
            }
            summary.previousUsage = event.total
            summary.previousHasOutputUsage = event.hasOutputUsage
            if summary.latestEvent == nil || date >= summary.latestEvent!.timestamp { summary.latestEvent = event }
            summary.total = summary.total + delta
            let key = UsageBucketKey(hour: hour, model: summary.model)
            summary.buckets[key, default: UsageBucket()].usage = summary.buckets[key, default: UsageBucket()].usage + delta
            summary.buckets[key, default: UsageBucket()].lastActive = date
            if event.hasCacheUsage, summary.previousHasCacheUsage || previous == nil || event.total.total < (previous?.total ?? 0) {
                summary.buckets[key, default: UsageBucket()].cacheInput += delta.input
                summary.buckets[key, default: UsageBucket()].cachedInput += delta.cachedInput
            }
            summary.previousHasCacheUsage = event.hasCacheUsage
            let preferred = isCanonicalQuota(event.rateLimitID)
            if preferred { summary.hasCanonicalQuota = true }
            if shouldReplaceRateEvent(current: summary.preferredRateEvent.map { ($0, isCanonicalQuota($0.rateLimitID)) }, candidate: event, candidateIsPreferred: preferred) {
                summary.preferredRateEvent = event
            }
            if let window = [event.primaryRate, event.secondaryRate].compactMap({ $0 }).first(where: { $0.windowMinutes == 10_080 }) {
                let quotaKey = QuotaSampleKey(model: summary.model, limitID: event.rateLimitID, resetsAt: window.resetsAt)
                if summary.quotaSamples[quotaKey].map({ $0.event.timestamp <= date }) ?? true {
                    summary.quotaSamples[quotaKey] = QuotaSample(event: event, model: summary.model)
                }
            }
        }
        if type == "response_item", payloadType == "message" {
            if payload["role"] as? String == "user" {
                summary.pendingTurn = PendingTurn(date: date, model: summary.model)
                if summary.pendingReply?.startedByTaskEvent != true || summary.pendingReply?.completedAt != nil {
                    startReply(at: date, taskEvent: false, summary: &summary)
                }
            } else if payload["role"] as? String == "assistant", payload["phase"] as? String == "final_answer" {
                completeTurn(at: date, summary: &summary)
                if summary.pendingReply?.completedAt == nil { summary.pendingReply?.completedAt = date }
            }
        } else if type == "event_msg", payloadType == "task_started" {
            startReply(at: date, taskEvent: true, summary: &summary)
        } else if type == "event_msg", payloadType == "task_complete" {
            // Older records may omit message phase; an explicit completion is a safe fallback.
            completeTurn(at: date, summary: &summary)
            if summary.pendingReply?.completedAt == nil { summary.pendingReply?.completedAt = date }
            finishReplySpeed(into: &summary)
        } else if type == "event_msg", payloadType == "task_aborted" || payloadType == "turn_aborted" {
            summary.pendingReply = nil
        }
    }

    private func startReply(at date: Date, taskEvent: Bool, summary: inout SessionSummary) {
        finishReplySpeed(into: &summary)
        summary.pendingReply = PendingReply(startedAt: date, startedByTaskEvent: taskEvent)
    }

    private func finishReplySpeed(into summary: inout SessionSummary) {
        guard let pending = summary.pendingReply else { return }
        summary.pendingReply = nil
        guard let end = pending.completedAt, end > summary.replySpeedStart,
              pending.hasReliableUsage, pending.outputTokens > 0 else { return }
        let seconds = end.timeIntervalSince(pending.startedAt)
        guard seconds > 0, seconds <= 3_600 else { return }
        summary.replySpeedSamples.append(ReplySpeedSample(completedAt: end, outputTokens: pending.outputTokens, turnSeconds: seconds))
    }

    private func completeTurn(at date: Date, summary: inout SessionSummary) {
        guard let pending = summary.pendingTurn else { return }
        summary.pendingTurn = nil
        let duration = date.timeIntervalSince(pending.date)
        guard duration >= 0, duration <= 3_600 else { return }
        let key = UsageBucketKey(hour: calendar.dateInterval(of: .hour, for: date)?.start ?? date, model: pending.model)
        summary.buckets[key, default: UsageBucket()].turnSeconds += duration
        summary.buckets[key, default: UsageBucket()].timedTurns += 1
        summary.buckets[key, default: UsageBucket()].lastActive = date
    }

    private func activeRate(_ rate: RateWindow?, at now: Date) -> RateWindow? {
        guard let rate, rate.resetsAt > now else { return nil }
        return rate
    }

    private func shouldReplaceRateEvent(
        current: (event: TokenEvent, isPreferred: Bool)?,
        candidate: TokenEvent,
        candidateIsPreferred: Bool
    ) -> Bool {
        guard let current else { return true }
        if current.isPreferred != candidateIsPreferred {
            return candidateIsPreferred
        }
        return candidate.timestamp > current.event.timestamp
    }
}

private struct TokenEvent: Codable {
    let timestamp: Date
    let total: TokenUsage
    let currentContextUsed: Int
    let contextWindow: Int
    let primaryRate: RateWindow?
    let secondaryRate: RateWindow?
    let rateLimitID: String?
    let hasCacheUsage: Bool
    let hasOutputUsage: Bool
    let isFirstUsage: Bool

    init?(json: [String: Any], timestamp: Date) {
        guard json["type"] as? String == "event_msg",
              let payload = json["payload"] as? [String: Any],
              payload["type"] as? String == "token_count",
              let info = payload["info"] as? [String: Any],
              let usage = info["total_token_usage"] as? [String: Any] else { return nil }

        self.timestamp = timestamp
        self.total = TokenUsage(
            input: usage.int("input_tokens"),
            cachedInput: usage.int("cached_input_tokens"),
            output: usage.int("output_tokens"),
            reasoningOutput: usage.int("reasoning_output_tokens"),
            total: usage.int("total_tokens")
        )
        self.hasCacheUsage = usage["input_tokens"] is NSNumber && usage["cached_input_tokens"] is NSNumber
        self.hasOutputUsage = usage["output_tokens"] is NSNumber && usage.int("output_tokens") >= 0
        let lastUsage = info["last_token_usage"] as? [String: Any]
        self.isFirstUsage = lastUsage?["output_tokens"] is NSNumber
            && lastUsage?["total_tokens"] is NSNumber
            && lastUsage?.int("output_tokens") == self.total.output
            && lastUsage?.int("total_tokens") == self.total.total
        self.currentContextUsed = lastUsage?.int("total_tokens") ?? 0
        self.contextWindow = info.int("model_context_window")

        let limits = payload["rate_limits"] as? [String: Any]
        self.rateLimitID = limits?["limit_id"] as? String
        self.primaryRate = RateWindow(json: limits?["primary"] as? [String: Any])
        self.secondaryRate = RateWindow(json: limits?["secondary"] as? [String: Any])
    }

}

private struct ProjectAccumulator {
    var tokens = 0
    var sessions = 0
    var lastActive: Date?

    static let empty = Self()

    mutating func add(tokens: Int, date: Date) {
        self.tokens += tokens
        sessions += 1
        if lastActive == nil || date > lastActive! { lastActive = date }
    }
}

private struct ModelAccumulator {
    var tokens = 0
    var requests = 0
    var turnSeconds = 0.0
    var timedTurns = 0
    var inputTokens = 0
    var cachedInputTokens = 0

    static let empty = Self()

    mutating func add(_ bucket: UsageBucket) {
        tokens += bucket.usage.total
        requests += bucket.timedTurns
        turnSeconds += bucket.turnSeconds
        timedTurns += bucket.timedTurns
        inputTokens += bucket.cacheInput
        cachedInputTokens += bucket.cachedInput
    }

    var cacheHitRate: Double? {
        guard inputTokens > 0 else { return nil }
        return Double(cachedInputTokens) / Double(inputTokens)
    }
}

private struct UsageBucketKey: Hashable, Codable {
    let hour: Date
    let model: String
}

private struct UsageBucket: Codable {
    var usage = TokenUsage()
    var cacheInput = 0
    var cachedInput = 0
    var turnSeconds = 0.0
    var timedTurns = 0
    var lastActive = Date.distantPast
}

private struct QuotaSampleKey: Hashable, Codable {
    let model: String
    let limitID: String?
    let resetsAt: Date
}

private struct QuotaSample: Codable {
    let event: TokenEvent
    let model: String
}

private struct PendingTurn: Codable {
    let date: Date
    let model: String
}

private struct SessionSummary: Codable {
    var project = ""
    var model = "其他"
    var previousUsage: TokenUsage?
    var previousHasCacheUsage = false
    var previousHasOutputUsage = false
    var latestEvent: TokenEvent?
    var preferredRateEvent: TokenEvent?
    var total = TokenUsage()
    var buckets: [UsageBucketKey: UsageBucket] = [:]
    var quotaSamples: [QuotaSampleKey: QuotaSample] = [:]
    var pendingTurn: PendingTurn?
    var pendingReply: PendingReply?
    var replySpeedSamples: [ReplySpeedSample] = []
    var replySpeedStart: Date
    var hasCanonicalQuota = false
    var malformedLines = 0
}

private struct PendingReply: Codable {
    let startedAt: Date
    let startedByTaskEvent: Bool
    var completedAt: Date?
    var outputTokens = 0
    var hasReliableUsage = true
}

enum UsageReadError: LocalizedError {
    case unavailable(String)
    var errorDescription: String? {
        switch self { case .unavailable(let message): message }
    }
}

private extension Dictionary where Key == String, Value == Any {
    func int(_ key: String) -> Int {
        (self[key] as? NSNumber)?.intValue ?? 0
    }
}

private func isSparkModel(_ name: String) -> Bool {
    name.localizedCaseInsensitiveContains("spark")
}

private func isCanonicalQuota(_ limitID: String?) -> Bool {
    limitID?.localizedCaseInsensitiveCompare("codex") == .orderedSame
}

private extension RateWindow {
    init?(json: [String: Any]?) {
        guard let json,
              let percent = (json["used_percent"] as? NSNumber)?.doubleValue,
              let minutes = (json["window_minutes"] as? NSNumber)?.intValue,
              let reset = (json["resets_at"] as? NSNumber)?.doubleValue else { return nil }
        self.init(usedPercent: percent, windowMinutes: minutes, resetsAt: Date(timeIntervalSince1970: reset))
    }
}
