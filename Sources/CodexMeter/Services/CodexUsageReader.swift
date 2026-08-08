import Foundation

actor CodexUsageReader {
    private struct FileFingerprint: Equatable {
        let path: String
        let modifiedAt: Date
        let size: Int
    }

    private let fileManager: FileManager
    private let calendar: Calendar
    private var cachedSnapshot: UsageSnapshot?
    private var cachedFiles: [FileFingerprint] = []
    private var cachedDayStart: Date?

    init(fileManager: FileManager = .default, calendar: Calendar = .current) {
        self.fileManager = fileManager
        self.calendar = calendar
    }

    func load(now: Date = .now, codexHome: URL? = nil, force: Bool = false) throws -> UsageSnapshot {
        let root = codexHome ?? resolvedCodexHome()
        // When the user selects .codex via the native folder picker, macOS
        // grants scope to that selected root. Enumerating from the root is
        // more reliable than starting a new traversal at a child directory.
        let files = jsonlFiles(in: [root])
        let startOfToday = calendar.startOfDay(for: now)
        let fingerprints = fileFingerprints(for: files)
        if !force, let cachedSnapshot,
           cachedDayStart == startOfToday,
           cachedFiles == fingerprints,
           cachedSnapshot.primaryRate.map({ $0.resetsAt > now }) ?? true,
           cachedSnapshot.secondaryRate.map({ $0.resetsAt > now }) ?? true,
           cachedSnapshot.mainMenuRate.map({ $0.resetsAt > now }) ?? true,
           cachedSnapshot.sparkRate.map({ $0.resetsAt > now }) ?? true {
            return cachedSnapshot
        }

        var snapshot = UsageSnapshot.empty
        snapshot.dataPath = root.path
        snapshot.dataDirectoryExists = fileManager.fileExists(atPath: root.path)
        snapshot.fileCount = files.count
        var latestRateTimestamp = Date.distantPast
        var latestMainMenuRateTimestamp = Date.distantPast
        var latestSparkRateTimestamp = Date.distantPast
        var projects: [String: ProjectAccumulator] = [:]
        var todayProjects: [String: ProjectAccumulator] = [:]
        var monthProjects: [String: ProjectAccumulator] = [:]
        var models: [String: (tokens: Int, requests: Int, turnSeconds: Double, timedTurns: Int)] = [:]
        var daily: [Date: Int] = [:]
        let sevenDaysAgo = calendar.date(byAdding: .day, value: -6, to: startOfToday) ?? startOfToday
        let thirtyDaysAgo = calendar.date(byAdding: .day, value: -29, to: startOfToday) ?? startOfToday
        let recentQuotaCutoff = calendar.date(byAdding: .day, value: -2, to: now) ?? now
        let monthInterval = calendar.dateInterval(of: .month, for: now)

        for file in files {
            // A Codex history can grow to several GB. The last token_count in
            // each rollout contains the cumulative usage for that session, so
            // reading a small tail is enough for the dashboard and avoids
            // blocking the menu-bar UI on a full archive scan.
            guard let standardText = tailText(in: file),
                  let event = latestTokenEvent(in: standardText) else { continue }
            let model = modelName(in: standardText)
            snapshot.sessionCount += 1
            snapshot.allTime = snapshot.allTime + event.total
            let projectPath = projectPath(in: file)
            if event.timestamp >= sevenDaysAgo {
                projects[projectPath, default: .empty].add(tokens: event.total.total, date: event.timestamp)
                let timing = responseTiming(in: standardText)
                models[model, default: (0, 0, 0, 0)].tokens += event.total.total
                models[model, default: (0, 0, 0, 0)].requests += max(1, timing.count)
                models[model, default: (0, 0, 0, 0)].turnSeconds += timing.seconds
                models[model, default: (0, 0, 0, 0)].timedTurns += timing.count
                daily[calendar.startOfDay(for: event.timestamp), default: 0] += event.total.total
            }
            if event.timestamp >= startOfToday {
                todayProjects[projectPath, default: .empty].add(tokens: event.total.total, date: event.timestamp)
            }
            if event.timestamp >= thirtyDaysAgo {
                monthProjects[projectPath, default: .empty].add(tokens: event.total.total, date: event.timestamp)
                snapshot.recentRecords.append(
                    UsageRecord(date: event.timestamp, project: projectPath, model: model, tokens: event.total.total)
                )
            }

            if event.timestamp >= startOfToday {
                snapshot.today = snapshot.today + event.total
            }
            if event.timestamp >= sevenDaysAgo {
                snapshot.lastSevenDays = snapshot.lastSevenDays + event.total
            }
            if let monthInterval, monthInterval.contains(event.timestamp) {
                snapshot.thisMonth = snapshot.thisMonth + event.total
            }

            // The official Codex status panel follows the newest quota event.
            // A quota can receive a new limit ID after it resets, so preferring
            // an older hard-coded ID leaves the app stuck on a stale percentage.
            if event.timestamp > latestRateTimestamp {
                latestRateTimestamp = event.timestamp
                // A token_count event can still contain the previous cycle's
                // window for a short period after its reset time. Do not let
                // that expired sample become the app's current quota.
                snapshot.primaryRate = activeRate(event.primaryRate, at: now)
                snapshot.secondaryRate = activeRate(event.secondaryRate, at: now)
                snapshot.selectedRateLimitID = event.rateLimitID
                snapshot.currentContextUsed = event.currentContextUsed
                snapshot.contextWindow = event.contextWindow
                snapshot.lastUpdated = event.timestamp
            }

            // One rollout can switch between Codex and Codex-Spark. Inspect
            // quota samples with the model active at that point instead of
            // assigning the file's final model to every quota event.
            let quotaText: String
            if standardText.localizedCaseInsensitiveContains("codex-spark") {
                quotaText = standardText
            } else if event.timestamp >= recentQuotaCutoff {
                quotaText = tailText(in: file, maxBytes: 1024 * 1024) ?? standardText
            } else {
                quotaText = standardText
            }
            for sample in quotaSamples(in: quotaText) where sample.event.timestamp >= thirtyDaysAgo {
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
                    if sample.event.timestamp >= latestMainMenuRateTimestamp {
                        snapshot.mainMenuRate = window
                        snapshot.selectedRateLimitID = sample.event.rateLimitID
                        latestMainMenuRateTimestamp = sample.event.timestamp
                    }
                }
            }
        }

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
                    : nil
            )
        }
            .sorted { $0.tokens > $1.tokens }
        snapshot.panelModels = Array(rankedModels.prefix(4))
        snapshot.topModels = rankedModels
            .filter { !isSparkModel($0.name) }
            .prefix(4)
            .map { $0 }
        snapshot.dailyUsage = daily.map { DailyUsage(date: $0.key, tokens: $0.value) }.sorted { $0.date < $1.date }
        cachedSnapshot = snapshot
        cachedFiles = fingerprints
        cachedDayStart = startOfToday
        return snapshot
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

    private func jsonlFiles(in directories: [URL]) -> [URL] {
        directories.flatMap { directory -> [URL] in
            guard let enumerator = fileManager.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { return [] }
            return enumerator.compactMap { item in
                guard let url = item as? URL, url.pathExtension == "jsonl" else { return nil }
                return url
            }
        }
    }

    private func fileFingerprints(for files: [URL]) -> [FileFingerprint] {
        files.compactMap { file in
            guard let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                  let modifiedAt = values.contentModificationDate,
                  let size = values.fileSize else { return nil }
            return FileFingerprint(path: file.path, modifiedAt: modifiedAt, size: size)
        }
        .sorted { $0.path < $1.path }
    }

    private func latestTokenEvent(in text: String) -> TokenEvent? {
        for line in text.split(separator: "\n").reversed() {
            guard line.contains("\"token_count\""),
                  let lineData = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let event = TokenEvent(json: object) else { continue }
            return event
        }
        return nil
    }

    private func projectPath(in file: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return "" }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: 32 * 1024)) ?? nil
        guard let data, let text = String(data: data, encoding: .utf8),
              let keyRange = text.range(of: "\"cwd\":\""),
              let end = text[keyRange.upperBound...].firstIndex(of: "\"") else { return "" }
        let cwd = String(text[keyRange.upperBound..<end])
        return cwd.replacingOccurrences(of: "\\/", with: "/")
    }
    private func modelName(in text: String) -> String {
        var seenTokenCount = false
        for line in text.split(separator: "\n").reversed() {
            guard let lineData = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  object["type"] as? String == "event_msg",
                  let payload = object["payload"] as? [String: Any],
                  let payloadType = payload["type"] as? String else { continue }

            if payloadType == "token_count" {
                seenTokenCount = true
                continue
            }
            guard seenTokenCount else { continue }

            if payloadType == "thread_settings_applied",
               let settings = payload["thread_settings"] as? [String: Any],
               let model = settings["model"] as? String,
               !model.isEmpty {
                return model
            }
        }

        guard let fallbackRange = text.range(of: "\"model\":\"", options: .backwards),
              let end = text[fallbackRange.upperBound...].firstIndex(of: "\"") else { return "其他" }
        return String(text[fallbackRange.upperBound..<end])
    }

    private func quotaSamples(in text: String) -> [(event: TokenEvent, model: String)] {
        var activeModel = "其他"
        var samples: [(TokenEvent, String)] = []
        for line in text.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }

            if object["type"] as? String == "turn_context",
               let payload = object["payload"] as? [String: Any],
               let model = payload["model"] as? String,
               !model.isEmpty {
                activeModel = model
                continue
            }
            if object["type"] as? String == "event_msg",
               let payload = object["payload"] as? [String: Any],
               payload["type"] as? String == "thread_settings_applied",
               let settings = payload["thread_settings"] as? [String: Any],
               let model = settings["model"] as? String,
               !model.isEmpty {
                activeModel = model
                continue
            }
            if let event = TokenEvent(json: object) {
                samples.append((event, activeModel))
            }
        }
        return samples
    }

    /// Codex does not record server-side latency. This derives a useful,
    /// clearly-labelled end-to-end time from a user message to the following
    /// final assistant message, using only the bounded session tail.
    private func responseTiming(in text: String) -> (seconds: Double, count: Int) {
        var latestUser: Date?
        var seconds = 0.0
        var count = 0
        for line in text.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["type"] as? String == "response_item",
                  let timestampText = object["timestamp"] as? String,
                  let timestamp = parseTimestamp(timestampText),
                  let payload = object["payload"] as? [String: Any],
                  payload["type"] as? String == "message",
                  let role = payload["role"] as? String else { continue }
            if role == "user" {
                latestUser = timestamp
            } else if role == "assistant", let userAt = latestUser {
                let duration = timestamp.timeIntervalSince(userAt)
                if duration >= 0, duration <= 3_600 {
                    seconds += duration
                    count += 1
                }
                latestUser = nil
            }
        }
        return (seconds, count)
    }

    private func tailText(in file: URL, maxBytes: UInt64 = 512 * 1024) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let tailSize = min(size, maxBytes)
        try? handle.seek(toOffset: size - tailSize)
        guard var data = try? handle.readToEnd() else { return nil }
        // A bounded tail can start in the middle of a UTF-8 scalar or JSONL
        // record. Drop that partial first line so one non-ASCII byte does not
        // invalidate the whole scan.
        if tailSize < size, let newline = data.firstIndex(of: 0x0A) {
            data = data[data.index(after: newline)...]
        }
        return String(decoding: data, as: UTF8.self)
    }

    private func activeRate(_ rate: RateWindow?, at now: Date) -> RateWindow? {
        guard let rate, rate.resetsAt > now else { return nil }
        return rate
    }
}

private struct TokenEvent {
    let timestamp: Date
    let total: TokenUsage
    let currentContextUsed: Int
    let contextWindow: Int
    let primaryRate: RateWindow?
    let secondaryRate: RateWindow?
    let rateLimitID: String?

    init?(json: [String: Any]) {
        guard json["type"] as? String == "event_msg",
              let payload = json["payload"] as? [String: Any],
              payload["type"] as? String == "token_count",
              let timestampText = json["timestamp"] as? String,
              let timestamp = parseTimestamp(timestampText),
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
        let lastUsage = info["last_token_usage"] as? [String: Any]
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

private func parseTimestamp(_ text: String) -> Date? {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: text)
}

private extension Dictionary where Key == String, Value == Any {
    func int(_ key: String) -> Int {
        (self[key] as? NSNumber)?.intValue ?? 0
    }
}

private func isSparkModel(_ name: String) -> Bool {
    name.localizedCaseInsensitiveContains("spark")
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
