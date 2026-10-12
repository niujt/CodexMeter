import AppKit
import Foundation

@MainActor
final class CodexFolderAccess {
    private static let bookmarkKey = "codexHomeBookmarkV2"
    private var activeURL: URL?
    private var isSecurityScoped = false
    private let defaults: UserDefaults
    private(set) var restoreError: String?

    init(defaults: UserDefaults = .standard, selectedURL: URL? = nil) {
        self.defaults = defaults
        if let selectedURL {
            activeURL = selectedURL
        } else if let data = defaults.data(forKey: Self.bookmarkKey) {
            do {
                var stale = false
                activeURL = try URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
                if stale, let activeURL {
                    let refreshed = try activeURL.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
                    defaults.set(refreshed, forKey: Self.bookmarkKey)
                }
            } catch {
                restoreError = "已选目录授权无法恢复，请重新选择目录。"
            }
        }
        isSecurityScoped = activeURL?.startAccessingSecurityScopedResource() ?? false
    }

    deinit {
        if isSecurityScoped { activeURL?.stopAccessingSecurityScopedResource() }
    }

    var selectedURL: URL? { activeURL }

    func chooseFolder() throws -> URL? {
        let panel = NSOpenPanel()
        panel.title = "选择 Codex 数据目录"
        panel.message = "选择 Codex 主目录（包含 sessions），或仅选择会话目录。会话目录只用于本地 Token 统计。"
        panel.prompt = "授权读取"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.showsHiddenFiles = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser

        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        try select(url)
        return url
    }

    func select(_ url: URL) throws {
        // A normal bookmark avoids reviving the old security-scoped bookmark
        // whose access grant belonged to a previous build of this app.
        let bookmark = try url.bookmarkData(
            options: [], includingResourceValuesForKeys: nil, relativeTo: nil
        )
        defaults.set(bookmark, forKey: Self.bookmarkKey)
        if isSecurityScoped { activeURL?.stopAccessingSecurityScopedResource() }
        activeURL = url
        isSecurityScoped = url.startAccessingSecurityScopedResource()
        restoreError = nil
    }
}
