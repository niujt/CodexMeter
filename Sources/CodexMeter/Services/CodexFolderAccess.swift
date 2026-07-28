import AppKit
import Foundation

@MainActor
final class CodexFolderAccess {
    private static let bookmarkKey = "codexHomeBookmarkV2"
    private var activeURL: URL?
    private var isSecurityScoped = false

    init() {
        activeURL = Self.restoreBookmark()
        isSecurityScoped = activeURL?.startAccessingSecurityScopedResource() ?? false
    }

    deinit {
        if isSecurityScoped { activeURL?.stopAccessingSecurityScopedResource() }
    }

    var selectedURL: URL? { activeURL }

    func chooseFolder() throws -> URL? {
        let panel = NSOpenPanel()
        panel.title = "选择 Codex 数据目录"
        panel.message = "请选择 ~/.codex 文件夹，以授权 Codex Health 读取本机记录。"
        panel.prompt = "授权读取"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.showsHiddenFiles = true
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser

        guard panel.runModal() == .OK, let url = panel.url else { return nil }

        if isSecurityScoped { activeURL?.stopAccessingSecurityScopedResource() }
        activeURL = url
        isSecurityScoped = url.startAccessingSecurityScopedResource()

        // A normal bookmark avoids reviving the old security-scoped bookmark
        // whose access grant belonged to a previous build of this app.
        if let bookmark = try? url.bookmarkData(
            options: [], includingResourceValuesForKeys: nil, relativeTo: nil
        ) {
            UserDefaults.standard.set(bookmark, forKey: Self.bookmarkKey)
        }
        return url
    }

    private static func restoreBookmark() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return nil }
        var stale = false
        return try? URL(
            resolvingBookmarkData: data,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        )
    }
}
