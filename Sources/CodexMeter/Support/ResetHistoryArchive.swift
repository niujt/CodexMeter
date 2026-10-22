import Foundation

/// Durable account history, separate from expiring quota samples. Contains no login credentials.
struct ResetHistoryArchive {
    struct Snapshot: Codable {
        let version: Int
        let partition: String
        let events: [ResetHistoryEvent]
        let checkedAt: Date
    }

    let directory: URL

    static func defaultDirectory() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("CodexMeter/reset-history", isDirectory: true)
    }

    static func partition(for context: CodexDataContext) -> String? {
        guard context.source.home != nil, let account = context.accountIdentity else { return nil }
        // Login/token renewal changes the quota boundary, but must not erase this account's saved history.
        return CodexDataSource.digest(context.source.id + "\u{0}" + account)
    }

    func file(for partition: String) -> URL { directory.appendingPathComponent(partition + ".json") }

    func load(partition: String) throws -> Snapshot? {
        let path = file(for: partition)
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.intValue <= 32 * 1_024 * 1_024 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let value = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: path))
        guard value.version == 1, value.partition == partition,
              Set(value.events.map(\.id)).count == value.events.count,
              value.events.allSatisfy({ !$0.id.isEmpty }) else { throw CocoaError(.fileReadCorruptFile) }
        return value
    }

    func save(events: [ResetHistoryEvent], checkedAt: Date, partition: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let value = Snapshot(version: 1, partition: partition, events: events, checkedAt: checkedAt)
        let path = file(for: partition)
        try encoder.encode(value).write(to: path, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    }
}
