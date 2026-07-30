import Foundation

actor CodexUsageReader {
    private let fileManager: FileManager
    private let calendar: Calendar

    init(fileManager: FileManager = .default, calendar: Calendar = .current) {
        self.fileManager = fileManager
        self.calendar = calendar
    }

    func load(now: Date = .now, codexHome: URL? = nil) throws -> UsageSnapshot {
        let root = codexHome ?? resolvedCodexHome()
        // When the user selects .codex via the native folder picker, macOS
        // grants scope to that selected root. Enumerating from the root is
        // more reliable than starting a new traversal at a child directory.
        let files = jsonlFiles(in: [root])
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
        let startOfToday = calendar.startOfDay(for: now)
        let sevenDaysAgo = calendar.date(byAdding: .day, value: -6, to: startOfToday) ?? startOfToday
        let thirtyDaysAgo = calendar.date(byAdding: .day, value: -29, to: startOfToday) ?? startOfToday
        let monthInterval = calendar.dateInterval(of: .month, for: now)

        for file in files {
            // A Codex history can grow to several GB. The last token_count in
            // each rollout contains the cumulative usage for that session, so
            // reading a small tail is enough for the dashboard and avoids
            // blocking the menu-bar UI on a full archive scan.
            guard let event = try? latestTokenEvent(in: file) else { continue }
            let model = modelName(in: file)
            snapshot.sessionCount += 1
            snapshot.allTime = snapshot.allTime + event.total
            let projectPath = projectPath(in: file)
            if event.timestamp >= sevenDaysAgo {
                projects[projectPath, default: .empty].add(tokens: event.total.total, date: event.timestamp)
                let timing = responseTiming(in: file)
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
                snapshot.primaryRate = event.primaryRate
                snapshot.secondaryRate = event.secondaryRate
                snapshot.selectedRateLimitID = event.rateLimitID
                snapshot.currentContextUsed = event.currentContextUsed
                snapshot.contextWindow = event.contextWindow
                snapshot.lastUpdated = event.timestamp
            }

            if event.timestamp >= thirtyDaysAgo,
               let window = [event.primaryRate, event.secondaryRate]
                .compactMap({ $0 })
                .first(where: { $0.windowMinutes == 10_080 }) {
                let isSpark = !model.isEmpty && isSparkModel(model)
                snapshot.rateTimeline.append(
                    RateTimelineEvent(
                        date: event.timestamp,
                        usedPercent: window.usedPercent,
                        resetsAt: window.resetsAt,
                        limitID: event.rateLimitID
                    )
                )
                if isSpark {
                    if event.timestamp >= latestSparkRateTimestamp {
                        snapshot.sparkRate = window
                        latestSparkRateTimestamp = event.timestamp
                    }
                } else {
                    if event.timestamp >= latestMainMenuRateTimestamp {
                        snapshot.mainMenuRate = window
                        latestMainMenuRateTimestamp = event.timestamp
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

    private func latestTokenEvent(in file: URL) throws -> TokenEvent? {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        let tailSize = min(size, 512 * 1024)
        try handle.seek(toOffset: size - tailSize)
        let data = try handle.readToEnd() ?? Data()
        guard let text = String(data: data, encoding: .utf8) else { return nil }
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
    private func modelName(in file: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return "其他" }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return "其他" }
        try? handle.seek(toOffset: size > 512 * 1024 ? size - 512 * 1024 : 0)
        guard let data = try? handle.readToEnd(), let text = String(data: data, encoding: .utf8) else { return "其他" }

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

    /// Codex does not record server-side latency. This derives a useful,
    /// clearly-labelled end-to-end time from a user message to the following
    /// final assistant message, using only the bounded session tail.
    private func responseTiming(in file: URL) -> (seconds: Double, count: Int) {
        guard let text = tailText(in: file) else { return (0, 0) }
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

    private func tailText(in file: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let tailSize = min(size, 512 * 1024)
        try? handle.seek(toOffset: size - tailSize)
        guard let data = try? handle.readToEnd() else { return nil }
        return String(data: data, encoding: .utf8)
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
