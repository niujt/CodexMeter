import Foundation
import CryptoKit

actor CodexUsageReader {
    private static let cacheVersion = 6
    private struct FileFingerprint: Equatable, Codable {
        let path: String
        let modifiedAt: Date
        let size: Int
        let identity: String
        let createdAt: Date
    }

    private let fileManager: FileManager
    private let calendar: Calendar
    private struct CachedFile: Codable {
        let fingerprint: FileFingerprint
        // Resume before EOF projection so trailing usage and aborts stay in their turn.
        let summary: SessionSummary
        let fragmentSummary: SessionSummary?
        let checkpoint: AppendCheckpoint
    }
    private struct AppendCheckpoint: Codable {
        let offset: Int
        let droppingOversizedLine: Bool
        let prefixDigest: Data
        let tailDigest: Data
    }
    private struct DirectoryEntry {
        let url: URL
        let isDirectory: Bool
        let isRegularFile: Bool
    }
    private struct CachedDirectory {
        let modifiedAt: Date
        let identity: String
        let entries: [DirectoryEntry]
    }
    private var directoryCache: [String: CachedDirectory] = [:]
    private var scannedFingerprints: [String: FileFingerprint] = [:]
    private var aggregateSnapshot: UsageSnapshot?
    private var aggregateFingerprints: [String: FileFingerprint] = [:]
    private var sortedFiles: [URL] = []
    private var sortFingerprints: [String: FileFingerprint] = [:]
    private var aggregateQuotaSince: Date?
    private var loadInProgress = false
    private var loadWaiters: [CheckedContinuation<Void, Never>] = []
    private var aggregateDate: Date?
    private var nextFutureCompletion: Date?

    private var fileCache: [String: CachedFile] = [:]
    private var cacheRoot: String?
    private var cacheNeedsPersistence = false
    private var dirtyCachePaths = Set<String>()
    private var cacheManifestChanged = false
    private(set) var cacheWarning: String?
    private let cacheDirectory: URL?
    private struct DiskCache: Codable {
        let version: Int
        let root: String
        let calendarID: String
        let timeZoneID: String
        let paths: [String]
    }
    private struct DiskFileCache: Codable {
        let version: Int
        let root: String
        let calendarID: String
        let timeZoneID: String
        let file: CachedFile
    }
    private(set) var parsedFileCount = 0
    private(set) var reusedFileCount = 0
    private(set) var enumeratedEntryCount = 0
    private(set) var listedDirectoryCount = 0
    private(set) var incrementalFileCount = 0
    private(set) var readByteCount = 0
    private(set) var aggregatedBucketCount = 0
    private(set) var reusedAggregateCount = 0
    private(set) var persistedSummaryCount = 0
    private(set) var finalizedSnapshotCount = 0
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

    private func fileCacheURL(root: String, path: String) -> URL? {
        guard let index = cacheURL(for: root) else { return nil }
        let key = SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
        return index.deletingPathExtension().appendingPathExtension("summaries")
            .appendingPathComponent(key + ".plist")
    }

    private func restoreCache(for root: String) -> [String: CachedFile] {
        guard let url = cacheURL(for: root),
              let data = try? Data(contentsOf: url),
              let cache = try? PropertyListDecoder().decode(DiskCache.self, from: data),
              cache.version == Self.cacheVersion, cache.root == root,
              cache.calendarID == String(describing: calendar.identifier),
              cache.timeZoneID == calendar.timeZone.identifier else {
            cacheManifestChanged = true
            return [:]
        }
        var restored: [String: CachedFile] = [:]
        for path in cache.paths {
            guard let fileURL = fileCacheURL(root: root, path: path),
                  let data = try? Data(contentsOf: fileURL),
                  let entry = try? PropertyListDecoder().decode(DiskFileCache.self, from: data),
                  entry.version == Self.cacheVersion, entry.root == root,
                  entry.calendarID == cache.calendarID, entry.timeZoneID == cache.timeZoneID,
                  entry.file.fingerprint.path == path else { continue }
            restored[path] = entry.file
        }
        if restored.count != cache.paths.count { cacheManifestChanged = true }
        return restored
    }

    private func persistCache(for root: String) {
        guard let url = cacheURL(for: root) else { return }
        // Each changed session writes one summary; unchanged summaries stay untouched.
        do {
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            for path in dirtyCachePaths.sorted() {
                guard let cached = fileCache[path], let fileURL = fileCacheURL(root: root, path: path) else {
                    dirtyCachePaths.remove(path)
                    continue
                }
                try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                let payload = DiskFileCache(version: Self.cacheVersion, root: root,
                    calendarID: String(describing: calendar.identifier), timeZoneID: calendar.timeZone.identifier, file: cached)
                try encoder.encode(payload).write(to: fileURL, options: .atomic)
                persistedSummaryCount += 1
                dirtyCachePaths.remove(path)
            }
            if cacheManifestChanged {
                let payload = DiskCache(version: Self.cacheVersion, root: root,
                    calendarID: String(describing: calendar.identifier), timeZoneID: calendar.timeZone.identifier,
                    paths: fileCache.keys.sorted())
                try encoder.encode(payload).write(to: url, options: .atomic)
                cacheManifestChanged = false
            }
            cacheNeedsPersistence = false
            cacheWarning = nil
        } catch {
            cacheNeedsPersistence = true
            cacheWarning = "统计缓存保存失败，下次启动可能需要重新读取：\(error.localizedDescription)"
        }
    }

    func load(now: Date = .now, codexHome: URL? = nil, force: Bool = false, quotaSince: Date = .distantPast,
              onProgress: (@Sendable (UsageSnapshot, Int, Int) async -> Void)? = nil) async throws -> UsageSnapshot {
        try await loadWithActivity(now: now, codexHome: codexHome, force: force, quotaSince: quotaSince, onActivity: nil, onProgress: onProgress)
    }

    func loadWithActivity(now: Date = .now, codexHome: URL? = nil, force: Bool = false, quotaSince: Date = .distantPast,
                          onFileProgress: (@Sendable (Int, Int) async -> Void)? = nil,
                          onActivity: (@Sendable (Int, Int) async -> Void)?,
                          onProgress: (@Sendable (UsageSnapshot, Int, Int) async -> Void)? = nil) async throws -> UsageSnapshot {
        // Progress callbacks yield the actor. Serialize loads so a cancelled old
        // directory cannot mutate the new directory's parser cache after yielding.
        if loadInProgress {
            await withCheckedContinuation { loadWaiters.append($0) }
        } else {
            loadInProgress = true
        }
        defer {
            if loadWaiters.isEmpty { loadInProgress = false }
            else { loadWaiters.removeFirst().resume() }
        }
        try Task.checkCancellation()
        let root = (codexHome ?? CodexDataSource.defaultRoot()).standardizedFileURL.resolvingSymlinksInPath()
        if cacheRoot != root.path {
            dirtyCachePaths = []
            cacheManifestChanged = false
            fileCache = restoreCache(for: root.path)
            cacheRoot = root.path
            cacheNeedsPersistence = false
            cacheWarning = nil
            directoryCache = [:]
            sortedFiles = []
            sortFingerprints = [:]
            aggregateSnapshot = nil
            aggregateDate = nil
        }
        if force { directoryCache = [:] }
        let files = try jsonlFiles(in: root)
        let paths = Set(files.map(\.path))
        var cacheChanged = fileCache.keys.contains { !paths.contains($0) }
        fileCache = fileCache.filter { paths.contains($0.key) }
        if cacheChanged { cacheManifestChanged = true }
        parsedFileCount = 0
        reusedFileCount = 0
        incrementalFileCount = 0
        readByteCount = 0
        aggregatedBucketCount = 0
        reusedAggregateCount = 0
        persistedSummaryCount = 0
        finalizedSnapshotCount = 0
        if !force, aggregateQuotaSince == quotaSince, scannedFingerprints.count == files.count,
           scannedFingerprints == aggregateFingerprints,
           let previous = aggregateSnapshot, let date = aggregateDate,
           nextFutureCompletion == nil || now < nextFutureCompletion!,
           now >= date, calendar.dateInterval(of: .hour, for: now)?.start == calendar.dateInterval(of: .hour, for: date)?.start,
           ![previous.primaryRate, previous.secondaryRate, previous.mainMenuRate, previous.sparkRate]
            .compactMap({ $0 }).contains(where: { $0.resetsAt > date && $0.resetsAt <= now }) {
            var reused = previous
            reused.replySpeedSamples = reused.replySpeedSamples.filter {
                $0.completedAt > now.addingTimeInterval(-RecentReplySpeed.windowSeconds) && $0.completedAt <= now
            }
            reusedFileCount = files.count
            reusedAggregateCount = files.count
            if cacheChanged || cacheNeedsPersistence { persistCache(for: root.path) }
            await onActivity?(0, reusedFileCount)
            await onFileProgress?(files.count, files.count)
            await onProgress?(reused, files.count, files.count)
            try Task.checkCancellation()
            return reused
        }
        // Any incomplete refresh must not leave a reusable aggregate behind.
        aggregateSnapshot = nil
        let startOfToday = calendar.startOfDay(for: now)

        var snapshot = UsageSnapshot.empty
        snapshot.dataPath = root.path
        snapshot.dataDirectoryExists = fileManager.fileExists(atPath: root.path)
        snapshot.fileCount = files.count
        var latestRateEvent: (event: QuotaEvent, isPreferred: Bool)?
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
        var cycleTokens: [QuotaCycleKey: Int] = [:]
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
            snapshot.mainRateSampledAt = selectedMainMenuRate?.timestamp
            snapshot.selectedRateLimitID = selectedMainMenuRate?.limitID

            // Preserve exact reset boundaries, including multiple resets on one day.
            let relevantTimeline = snapshot.rateTimeline.filter {
                snapshot.selectedRateLimitID == nil || $0.limitID == snapshot.selectedRateLimitID
            }
            var latestSampleByCycle: [QuotaCycleKey: RateTimelineEvent] = [:]
            for event in relevantTimeline {
                let key = QuotaCycleKey(limitID: event.limitID, resetsAt: event.resetsAt)
                if let existing = latestSampleByCycle[key], existing.date >= event.date { continue }
                var event = event
                event.tokens = cycleTokens[key, default: 0]
                latestSampleByCycle[key] = event
            }
            snapshot.rateTimeline = latestSampleByCycle.values.sorted {
                if $0.date != $1.date { return $0.date > $1.date }
                if $0.resetsAt != $1.resetsAt { return $0.resetsAt > $1.resetsAt }
                return ($0.limitID ?? "") < ($1.limitID ?? "")
            }
            snapshot.recentRecords.sort {
                if $0.date != $1.date { return $0.date > $1.date }
                if $0.project != $1.project { return $0.project < $1.project }
                return $0.model < $1.model
            }
            snapshot.allProjects = ranked(projects)
            snapshot.topProjects = Array(snapshot.allProjects.prefix(4))
            snapshot.todayProjects = ranked(todayProjects)
            snapshot.monthProjects = ranked(monthProjects)
            var rankedModels: [ModelUsage] = models.map {
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
            rankedModels.sort { left, right in
                if left.tokens != right.tokens { return left.tokens > right.tokens }
                return left.name < right.name
            }
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
            if (onProgress != nil || onFileProgress != nil || onActivity != nil),
               index <= 1 || Date.now.timeIntervalSince(lastPublished) >= 0.3 {
                await onActivity?(parsedFileCount, reusedFileCount)
                await onFileProgress?(index, files.count)
                if let onProgress {
                    finalizedSnapshotCount += 1
                    await onProgress(finalizedSnapshot(), index, files.count)
                }
                try Task.checkCancellation()
                lastPublished = .now
            }
            let summary: SessionSummary
            do {
                let fingerprint = try scannedFingerprints[file.path] ?? fileFingerprint(for: file)
                if !force, let cached = fileCache[file.path], cached.fingerprint == fingerprint {
                    summary = displayedSummary(cached)
                    reusedFileCount += 1
                } else {
                    parsedFileCount += 1
                    try Task.checkCancellation()
                    let parsed = try parseSession(file, fingerprint: fingerprint,
                                                  cached: force ? nil : fileCache[file.path],
                                                  speedWindowStart: now.addingTimeInterval(-RecentReplySpeed.windowSeconds))
                    cacheChanged = true
                    // Do not cache a moving target; retry it on the next refresh.
                    if try fileFingerprint(for: file) == fingerprint {
                        if fileCache[file.path] == nil { cacheManifestChanged = true }
                        fileCache[file.path] = parsed
                        dirtyCachePaths.insert(file.path)
                    } else {
                        if fileCache[file.path] != nil { cacheManifestChanged = true }
                        fileCache[file.path] = nil
                    }
                    summary = displayedSummary(parsed)
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failedFiles += 1
                guard let cached = fileCache[file.path] else { continue }
                summary = displayedSummary(cached)
                reusedFileCount += 1
            }
            malformedLines += summary.malformedLines
            guard summary.latestEvent != nil || summary.latestQuotaEvent != nil else { continue }
            snapshot.sessionCount += 1
            snapshot.allTime = snapshot.allTime + summary.total
            snapshot.replySpeedSamples += summary.replySpeedSamples.filter {
                $0.completedAt > now.addingTimeInterval(-RecentReplySpeed.windowSeconds) && $0.completedAt <= now
            }
            let projectPath = summary.project
            var weekTokens = 0, todayTokens = 0, monthTokens = 0
            var weekDate: Date?, todayDate: Date?, monthDate: Date?
            for (key, bucket) in summary.buckets where key.hour <= now {
                aggregatedBucketCount += 1
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
            if let event = summary.latestEvent, event.timestamp > latestContextTimestamp {
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
            let eligibleEvents = (summary.quotaSamples.values.map(\.event) + [summary.latestQuotaEvent].compactMap { $0 } + [summary.preferredRateEvent].compactMap { $0 })
                .filter { $0.timestamp >= quotaSince && $0.timestamp <= now }
            for rateEvent in eligibleEvents {
                let eventIsPreferred = isCanonicalQuota(rateEvent.rateLimitID)
                if eventIsPreferred { hasCanonicalQuotaObservation = true }
                if shouldReplaceRateEvent(current: latestRateEvent, candidate: rateEvent, candidateIsPreferred: eventIsPreferred) {
                    latestRateEvent = (rateEvent, eventIsPreferred)
                    snapshot.primaryRate = activeRate(rateEvent.primaryRate, at: now)
                    snapshot.primaryRateSampledAt = snapshot.primaryRate == nil ? nil : rateEvent.timestamp
                    snapshot.secondaryRate = activeRate(rateEvent.secondaryRate, at: now)
                    snapshot.selectedRateLimitID = rateEvent.rateLimitID
                }
            }

            for (key, usage) in summary.quotaUsage where key.date >= quotaSince && key.date <= now && !isSparkModel(key.model) {
                cycleTokens[key.cycle, default: 0] += usage.total
            }

            for sample in summary.quotaSamples.values where sample.event.timestamp >= max(thirtyDaysAgo, quotaSince) && sample.event.timestamp <= now {
                guard let window = [sample.event.primaryRate, sample.event.secondaryRate]
                    .compactMap({ $0 })
                    .first(where: { $0.windowMinutes == 10_080 }) else { continue }
                if isSparkModel(sample.model) {
                    guard window.resetsAt > now else { continue }
                    if sample.event.timestamp >= latestSparkRateTimestamp {
                        snapshot.sparkRate = window
                        snapshot.sparkRateSampledAt = sample.event.timestamp
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

        finalizedSnapshotCount += 1
        let result = finalizedSnapshot()
        await onActivity?(parsedFileCount, reusedFileCount)
        await onFileProgress?(files.count, files.count)
        await onProgress?(result, files.count, files.count)
        try Task.checkCancellation()
        if cacheChanged || cacheNeedsPersistence { persistCache(for: root.path) }
        if failedFiles == 0, scannedFingerprints.count == files.count,
           files.allSatisfy({ fileCache[$0.path]?.fingerprint == scannedFingerprints[$0.path] }) {
            aggregateSnapshot = result
            aggregateFingerprints = scannedFingerprints
            aggregateDate = now
            aggregateQuotaSince = quotaSince
            nextFutureCompletion = fileCache.values.flatMap {
                let summary = displayedSummary($0)
                return summary.replySpeedSamples.map(\.completedAt) + summary.quotaSamples.values.map { $0.event.timestamp } + summary.quotaUsage.keys.map(\.date)
            }.filter { $0 > now }.min()
        }
        return result
    }

    private func ranked(_ values: [String: ProjectAccumulator]) -> [ProjectUsage] {
        values.map { ProjectUsage(path: $0.key, tokens: $0.value.tokens, sessions: $0.value.sessions, lastActive: $0.value.lastActive) }
            .sorted {
                if $0.tokens != $1.tokens { return $0.tokens > $1.tokens }
                if $0.lastActive != $1.lastActive { return ($0.lastActive ?? .distantPast) > ($1.lastActive ?? .distantPast) }
                return $0.path < $1.path
            }
    }

    private func jsonlFiles(in directory: URL) throws -> [URL] {
        enumeratedEntryCount = 0
        listedDirectoryCount = 0
        scannedFingerprints = [:]
        let sessionDirectories = Set(["sessions", "archived_sessions"])
        let isCodexRoot = CodexDataSource(root: directory, fileManager: fileManager).home != nil
        var files: [URL] = []
        var visited = Set<String>()
        func visit(_ folder: URL, isRoot: Bool) throws {
            try Task.checkCancellation()
            let attributes = try fileManager.attributesOfItem(atPath: folder.path)
            guard attributes[.type] as? FileAttributeType == .typeDirectory,
                  let modifiedAt = attributes[.modificationDate] as? Date else {
                throw UsageReadError.unavailable("所选路径不是目录。")
            }
            let identity = "\(attributes[.systemNumber] ?? 0)-\(attributes[.systemFileNumber] ?? 0)"
            visited.insert(folder.path)
            let entries: [DirectoryEntry]
            if let cached = directoryCache[folder.path], cached.modifiedAt == modifiedAt, cached.identity == identity {
                entries = cached.entries
            } else {
                listedDirectoryCount += 1
                entries = try fileManager.contentsOfDirectory(at: folder,
                    includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey],
                    options: [.skipsHiddenFiles]).compactMap { url in
                        if isRoot && isCodexRoot && !sessionDirectories.contains(url.lastPathComponent) { return nil }
                        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey])
                        // Never traverse links out of the selected data tree.
                        guard values.isSymbolicLink != true else { return nil }
                        return DirectoryEntry(url: url, isDirectory: values.isDirectory == true,
                                              isRegularFile: values.isRegularFile == true)
                    }
                directoryCache[folder.path] = CachedDirectory(modifiedAt: modifiedAt, identity: identity, entries: entries)
            }
            for entry in entries {
                enumeratedEntryCount += 1
                if entry.isDirectory {
                    try visit(entry.url, isRoot: false)
                } else if entry.isRegularFile && entry.url.pathExtension == "jsonl" {
                    files.append(entry.url)
                    scannedFingerprints[entry.url.path] = try? fileFingerprint(for: entry.url)
                }
            }
        }
        try visit(directory, isRoot: true)
        directoryCache = directoryCache.filter { visited.contains($0.key) }
        // Metadata is fetched once per file, never from inside the sort comparator.
        if scannedFingerprints.count == files.count, scannedFingerprints == sortFingerprints,
           sortedFiles.count == files.count { return sortedFiles }
        sortedFiles = files.sorted {
            let left = scannedFingerprints[$0.path]?.modifiedAt ?? .distantPast
            let right = scannedFingerprints[$1.path]?.modifiedAt ?? .distantPast
            return left == right ? $0.path < $1.path : left > right
        }
        sortFingerprints = scannedFingerprints
        return sortedFiles
    }

    private func fileFingerprint(for file: URL) throws -> FileFingerprint {
        let attributes = try fileManager.attributesOfItem(atPath: file.path)
        guard let modifiedAt = attributes[.modificationDate] as? Date,
              let createdAt = attributes[.creationDate] as? Date,
              let size = attributes[.size] as? NSNumber,
              let inode = attributes[.systemFileNumber] as? NSNumber else {
            throw UsageReadError.unavailable("无法读取会话文件属性。")
        }
        return FileFingerprint(path: file.path, modifiedAt: modifiedAt, size: size.intValue,
                               identity: "\(attributes[.systemNumber] ?? 0)-\(inode)", createdAt: createdAt)
    }

    private func displayedSummary(_ cached: CachedFile) -> SessionSummary {
        var result = cached.fragmentSummary ?? cached.summary
        finishModelTurn(into: &result)
        finishReplySpeed(into: &result)
        return result
    }

    private func digest(_ handle: FileHandle, offset: Int, count: Int) throws -> Data {
        try handle.seek(toOffset: UInt64(offset))
        let bytes = try handle.read(upToCount: count) ?? Data()
        readByteCount += bytes.count
        guard bytes.count == count else { throw UsageReadError.unavailable("会话文件在读取期间发生变化。") }
        return Data(SHA256.hash(data: bytes))
    }

    private func parseSession(_ file: URL, fingerprint: FileFingerprint, cached: CachedFile?,
                              speedWindowStart: Date) throws -> CachedFile {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let guardSize = 4 * 1024
        var summary = SessionSummary(replySpeedStart: speedWindowStart)
        var offset = 0
        var droppingOversizedLine = false
        if let cached, fingerprint.size > cached.fingerprint.size,
           fingerprint.identity == cached.fingerprint.identity,
           fingerprint.createdAt == cached.fingerprint.createdAt,
           fingerprint.modifiedAt >= cached.fingerprint.modifiedAt,
           cached.checkpoint.offset <= cached.fingerprint.size {
            let length = min(guardSize, cached.fingerprint.size)
            let prefix = try digest(handle, offset: 0, count: length)
            let tail = try digest(handle, offset: cached.fingerprint.size - length, count: length)
            if prefix == cached.checkpoint.prefixDigest && tail == cached.checkpoint.tailDigest {
                summary = cached.summary
                offset = cached.checkpoint.offset
                droppingOversizedLine = cached.checkpoint.droppingOversizedLine
                incrementalFileCount += 1
            }
        }
        summary.replySpeedStart = speedWindowStart
        summary.replySpeedSamples = summary.replySpeedSamples.filter { $0.completedAt > speedWindowStart }
        try handle.seek(toOffset: UInt64(offset))
        var buffer = Data()
        var scannedBytes = 0
        var position = offset
        var completedOffset = offset
        // Stop at the captured size so an active writer cannot prolong this refresh.
        while position < fingerprint.size {
            try Task.checkCancellation()
            let chunk = try handle.read(upToCount: min(64 * 1024, fingerprint.size - position)) ?? Data()
            guard !chunk.isEmpty else { throw UsageReadError.unavailable("会话文件在读取期间被截断。") }
            readByteCount += chunk.count
            position += chunk.count
            buffer.append(chunk)
            var consumed = 0
            // A long partial line must not be rescanned from its start on every chunk.
            let scanStart = buffer.index(buffer.startIndex, offsetBy: scannedBytes)
            for newline in buffer[scanStart...].indices where buffer[newline] == 0x0A {
                let end = buffer.distance(from: buffer.startIndex, to: newline)
                if !droppingOversizedLine {
                    let start = buffer.index(buffer.startIndex, offsetBy: consumed)
                    consume(Data(buffer[start..<newline]), into: &summary, isFinalFragment: false)
                }
                droppingOversizedLine = false
                consumed = end + 1
            }
            if consumed > 0 {
                buffer.removeFirst(consumed)
                completedOffset = position - buffer.count
            }
            scannedBytes = buffer.count
            if buffer.count > 16 * 1024 * 1024 {
                if !droppingOversizedLine { summary.malformedLines += 1 }
                droppingOversizedLine = true
                buffer.removeAll(keepingCapacity: true)
                scannedBytes = 0
                completedOffset = position
            }
        }
        var fragmentSummary: SessionSummary?
        if !buffer.isEmpty, !droppingOversizedLine {
            var projected = summary
            consume(buffer, into: &projected, isFinalFragment: true)
            fragmentSummary = projected
        }
        if (fragmentSummary ?? summary).latestEvent == nil, summary.malformedLines > 0 {
            throw UsageReadError.unavailable("会话记录无法解析。")
        }
        let length = min(guardSize, fingerprint.size)
        let checkpoint = AppendCheckpoint(offset: completedOffset, droppingOversizedLine: droppingOversizedLine,
            prefixDigest: try digest(handle, offset: 0, count: length),
            tailDigest: try digest(handle, offset: fingerprint.size - length, count: length))
        return CachedFile(fingerprint: fingerprint, summary: summary, fragmentSummary: fragmentSummary, checkpoint: checkpoint)
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
            if let event = QuotaEvent(json: json, timestamp: date) {
                if let window = [event.primaryRate, event.secondaryRate].compactMap({ $0 }).first(where: { $0.windowMinutes == 10_080 }) {
                    summary.currentQuotaCycles[summary.model] = QuotaCycleKey(limitID: event.rateLimitID, resetsAt: window.resetsAt)
                }
                let preferred = isCanonicalQuota(event.rateLimitID)
                if preferred { summary.hasCanonicalQuota = true }
                if shouldReplaceRateEvent(current: summary.preferredRateEvent.map { ($0, isCanonicalQuota($0.rateLimitID)) }, candidate: event, candidateIsPreferred: preferred) {
                    summary.preferredRateEvent = event
                }
                if let window = [event.primaryRate, event.secondaryRate].compactMap({ $0 }).first(where: { $0.windowMinutes == 10_080 }) {
                    let quotaKey = QuotaSampleKey(model: summary.model, limitID: event.rateLimitID, resetsAt: window.resetsAt, date: date)
                    if summary.quotaSamples[quotaKey].map({ $0.event.timestamp <= date }) ?? true {
                        summary.quotaSamples[quotaKey] = QuotaSample(event: event, model: summary.model)
                    }
                }
                if summary.latestQuotaEvent == nil || date >= summary.latestQuotaEvent!.timestamp { summary.latestQuotaEvent = event }
            }
            guard let event = TokenEvent(json: json, timestamp: date) else {
                if let info = payload["info"], !(info is NSNull) { summary.malformedLines += 1 }
                return
            }
            let previous = summary.previousUsage
            // A lower cumulative total begins a new counter segment (e.g. reset).
            let delta = previous.map { event.total.total < $0.total ? event.total : event.total - $0 } ?? event.total
            if let cycle = summary.currentQuotaCycles[summary.model], date < cycle.resetsAt {
                let key = QuotaUsageKey(date: date, model: summary.model, cycle: cycle)
                summary.quotaUsage[key, default: TokenUsage()] = summary.quotaUsage[key, default: TokenUsage()] + delta
            }
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
        }
        if type == "response_item", payloadType == "message" {
            if payload["role"] as? String == "user" {
                finishModelTurn(into: &summary)
                summary.pendingTurn = PendingTurn(date: date, model: summary.model)
                if summary.pendingReply?.startedByTaskEvent != true || summary.pendingReply?.completedAt != nil {
                    startReply(at: date, taskEvent: false, summary: &summary)
                }
            } else if payload["role"] as? String == "assistant", payload["phase"] as? String == "final_answer" {
                markModelTurnCompleted(at: date, summary: &summary)
                if summary.pendingReply?.completedAt == nil { summary.pendingReply?.completedAt = date }
            }
        } else if type == "event_msg", payloadType == "task_started" {
            if summary.pendingTurn?.completedAt != nil { finishModelTurn(into: &summary) }
            startReply(at: date, taskEvent: true, summary: &summary)
        } else if type == "event_msg", payloadType == "task_complete" {
            // Older records may omit message phase; an explicit completion is a safe fallback.
            markModelTurnCompleted(at: date, summary: &summary)
            finishModelTurn(into: &summary)
            if summary.pendingReply?.completedAt == nil { summary.pendingReply?.completedAt = date }
            finishReplySpeed(into: &summary)
        } else if type == "event_msg", payloadType == "task_aborted" || payloadType == "turn_aborted" {
            summary.pendingTurn = nil
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
        guard let seconds = validTurnDuration(from: pending.startedAt, to: end) else { return }
        summary.replySpeedSamples.append(ReplySpeedSample(completedAt: end, outputTokens: pending.outputTokens, turnSeconds: seconds))
    }

    private func markModelTurnCompleted(at date: Date, summary: inout SessionSummary) {
        // Keep final-only records reversible until a task completion or next turn.
        // EOF rendering uses a copy; an appended abort can still discard this turn.
        if summary.pendingTurn?.completedAt == nil { summary.pendingTurn?.completedAt = date }
    }

    private func finishModelTurn(into summary: inout SessionSummary) {
        guard let pending = summary.pendingTurn else { return }
        summary.pendingTurn = nil
        guard let end = pending.completedAt,
              let duration = validTurnDuration(from: pending.date, to: end) else { return }
        let key = UsageBucketKey(hour: calendar.dateInterval(of: .hour, for: end)?.start ?? end, model: pending.model)
        summary.buckets[key, default: UsageBucket()].turnSeconds += duration
        summary.buckets[key, default: UsageBucket()].timedTurns += 1
        summary.buckets[key, default: UsageBucket()].lastActive = end
    }

    private func validTurnDuration(from start: Date, to end: Date) -> TimeInterval? {
        let duration = end.timeIntervalSince(start)
        return duration.isFinite && duration > 0 && duration <= 3_600 ? duration : nil
    }

    private func activeRate(_ rate: RateWindow?, at now: Date) -> RateWindow? {
        guard let rate, rate.resetsAt > now else { return nil }
        return rate
    }

    private func shouldReplaceRateEvent(
        current: (event: QuotaEvent, isPreferred: Bool)?,
        candidate: QuotaEvent,
        candidateIsPreferred: Bool
    ) -> Bool {
        guard let current else { return true }
        if current.isPreferred != candidateIsPreferred {
            return candidateIsPreferred
        }
        return candidate.timestamp > current.event.timestamp
    }
}

private struct QuotaEvent: Codable {
    let timestamp: Date
    let primaryRate: RateWindow?
    let secondaryRate: RateWindow?
    let rateLimitID: String?

    init?(json: [String: Any], timestamp: Date) {
        guard json["type"] as? String == "event_msg",
              let payload = json["payload"] as? [String: Any],
              payload["type"] as? String == "token_count",
              let limits = payload["rate_limits"] as? [String: Any] else { return nil }
        primaryRate = RateWindow(json: limits["primary"] as? [String: Any])
        secondaryRate = RateWindow(json: limits["secondary"] as? [String: Any])
        guard primaryRate != nil || secondaryRate != nil else { return nil }
        self.timestamp = timestamp
        rateLimitID = limits["limit_id"] as? String
    }
}

private struct TokenEvent: Codable {
    let timestamp: Date
    let total: TokenUsage
    let currentContextUsed: Int
    let contextWindow: Int
    let hasCacheUsage: Bool
    let hasOutputUsage: Bool
    let isFirstUsage: Bool

    init?(json: [String: Any], timestamp: Date) {
        guard json["type"] as? String == "event_msg",
              let payload = json["payload"] as? [String: Any],
              payload["type"] as? String == "token_count",
              let info = payload["info"] as? [String: Any],
              let usage = info["total_token_usage"] as? [String: Any],
              let total = usage["total_tokens"] as? NSNumber, total.doubleValue.isFinite,
              total.doubleValue >= 0 else { return nil }

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

private struct QuotaCycleKey: Hashable, Codable {
    let limitID: String?
    let resetsAt: Date
}

private struct QuotaUsageKey: Hashable, Codable {
    let date: Date
    let model: String
    let cycle: QuotaCycleKey
}

private struct QuotaSampleKey: Hashable, Codable {
    let model: String
    let limitID: String?
    let resetsAt: Date
    let date: Date
}

private struct QuotaSample: Codable {
    let event: QuotaEvent
    let model: String
}

private struct PendingTurn: Codable {
    let date: Date
    let model: String
    var completedAt: Date?
}

private struct SessionSummary: Codable {
    var project = ""
    var model = "其他"
    var previousUsage: TokenUsage?
    var previousHasCacheUsage = false
    var previousHasOutputUsage = false
    var latestEvent: TokenEvent?
    var latestQuotaEvent: QuotaEvent?
    var preferredRateEvent: QuotaEvent?
    var total = TokenUsage()
    var buckets: [UsageBucketKey: UsageBucket] = [:]
    var quotaSamples: [QuotaSampleKey: QuotaSample] = [:]
    var currentQuotaCycles: [String: QuotaCycleKey] = [:]
    var quotaUsage: [QuotaUsageKey: TokenUsage] = [:]
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
