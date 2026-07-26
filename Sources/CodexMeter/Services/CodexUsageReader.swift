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
        var projects: [String: Int] = [:]
        var todayProjects: [String: Int] = [:]
        var monthProjects: [String: Int] = [:]
        var models: [String: (tokens: Int, requests: Int)] = [:]
        var daily: [Date: Int] = [:]
        let startOfToday = calendar.startOfDay(for: now)
        let sevenDaysAgo = calendar.date(byAdding: .day, value: -6, to: startOfToday) ?? startOfToday
        let monthInterval = calendar.dateInterval(of: .month, for: now)

        for file in files {
            // A Codex history can grow to several GB. The last token_count in
            // each rollout contains the cumulative usage for that session, so
            // reading a small tail is enough for the dashboard and avoids
            // blocking the menu-bar UI on a full archive scan.
            guard let event = try? latestTokenEvent(in: file) else { continue }
            snapshot.sessionCount += 1
            snapshot.allTime = snapshot.allTime + event.total
            if event.timestamp >= sevenDaysAgo {
                projects[projectName(in: file), default: 0] += event.total.total
                let model = modelName(in: file)
                models[model, default: (0, 0)].tokens += event.total.total
                models[model, default: (0, 0)].requests += 1
                daily[calendar.startOfDay(for: event.timestamp), default: 0] += event.total.total
                snapshot.recentRecords.append(UsageRecord(date: event.timestamp, project: projectName(in: file), model: model, tokens: event.total.total))
            }
            let project = projectName(in: file)
            if event.timestamp >= startOfToday { todayProjects[project, default: 0] += event.total.total }
            if event.timestamp >= (calendar.date(byAdding: .day, value: -29, to: startOfToday) ?? startOfToday) { monthProjects[project, default: 0] += event.total.total }

            if event.timestamp >= startOfToday {
                snapshot.today = snapshot.today + event.total
            }
            if event.timestamp >= sevenDaysAgo {
                snapshot.lastSevenDays = snapshot.lastSevenDays + event.total
            }
            if let monthInterval, monthInterval.contains(event.timestamp) {
                snapshot.thisMonth = snapshot.thisMonth + event.total
            }

            if event.timestamp > latestRateTimestamp {
                latestRateTimestamp = event.timestamp
                snapshot.primaryRate = event.primaryRate
                snapshot.secondaryRate = event.secondaryRate
                snapshot.currentContextUsed = event.currentContextUsed
                snapshot.contextWindow = event.contextWindow
                snapshot.lastUpdated = event.timestamp
            }
        }
        snapshot.topProjects = projects.map { ProjectUsage(name: $0.key, tokens: $0.value) }
            .sorted { $0.tokens > $1.tokens }
            .prefix(4).map { $0 }
        snapshot.todayProjects = ranked(todayProjects)
        snapshot.monthProjects = ranked(monthProjects)
        snapshot.topModels = models.map { ModelUsage(name: $0.key, tokens: $0.value.tokens, requests: $0.value.requests) }
            .sorted { $0.tokens > $1.tokens }.prefix(4).map { $0 }
        snapshot.dailyUsage = daily.map { DailyUsage(date: $0.key, tokens: $0.value) }.sorted { $0.date < $1.date }
        return snapshot
    }

    private func ranked(_ values: [String: Int]) -> [ProjectUsage] {
        values.map { ProjectUsage(name: $0.key, tokens: $0.value) }.sorted { $0.tokens > $1.tokens }.prefix(4).map { $0 }
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

    private func projectName(in file: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return "其他" }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: 32 * 1024)) ?? nil
        guard let data, let text = String(data: data, encoding: .utf8),
              let keyRange = text.range(of: "\"cwd\":\""),
              let end = text[keyRange.upperBound...].firstIndex(of: "\"") else { return "其他" }
        let cwd = String(text[keyRange.upperBound..<end])
        return URL(fileURLWithPath: cwd).lastPathComponent
    }
    private func modelName(in file: URL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return "其他" }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return "其他" }
        try? handle.seek(toOffset: size > 512 * 1024 ? size - 512 * 1024 : 0)
        guard let data = try? handle.readToEnd(), let text = String(data: data, encoding: .utf8),
              let range = text.range(of: "\"model\":\"", options: .backwards),
              let end = text[range.upperBound...].firstIndex(of: "\"") else { return "其他" }
        return String(text[range.upperBound..<end])
    }
}

private struct TokenEvent {
    let timestamp: Date
    let total: TokenUsage
    let currentContextUsed: Int
    let contextWindow: Int
    let primaryRate: RateWindow?
    let secondaryRate: RateWindow?

    init?(json: [String: Any]) {
        guard json["type"] as? String == "event_msg",
              let payload = json["payload"] as? [String: Any],
              payload["type"] as? String == "token_count",
              let timestampText = json["timestamp"] as? String,
              let timestamp = Self.parseDate(timestampText),
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
        self.primaryRate = RateWindow(json: limits?["primary"] as? [String: Any])
        self.secondaryRate = RateWindow(json: limits?["secondary"] as? [String: Any])
    }

    private static func parseDate(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text)
    }
}

private extension Dictionary where Key == String, Value == Any {
    func int(_ key: String) -> Int {
        (self[key] as? NSNumber)?.intValue ?? 0
    }
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
