import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class ProjectPathStore {
    private static let pathsKey = "codexHealth.followedProjectPaths"
    private(set) var followedPaths: [String]

    init() {
        followedPaths = UserDefaults.standard.stringArray(forKey: Self.pathsKey) ?? []
    }

    func addFolder() {
        let panel = NSOpenPanel()
        panel.title = "添加关注项目目录"
        panel.message = "选择一个本地项目目录；Codex Health 只保存路径用于归类和显示，不读取项目文件。"
        panel.prompt = "添加项目"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false

        guard panel.runModal() == .OK, let url = panel.url else { return }
        let path = url.standardizedFileURL.path
        guard !followedPaths.contains(path) else { return }
        followedPaths.append(path)
        followedPaths.sort()
        persist()
    }

    func remove(_ path: String) {
        followedPaths.removeAll { $0 == path }
        persist()
    }

    private func persist() {
        UserDefaults.standard.set(followedPaths, forKey: Self.pathsKey)
    }
}
