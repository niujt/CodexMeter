import Foundation

struct PermissionPaths: Sendable {
    let codexHome: URL
    let monitorHome: URL

    static let `default` = PermissionPaths(
        codexHome: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex", isDirectory: true),
        monitorHome: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex-monitor", isDirectory: true)
    )

    var hooksConfig: URL { codexHome.appendingPathComponent("hooks.json") }
    var hookDirectory: URL { monitorHome.appendingPathComponent("hooks", isDirectory: true) }
    var hookScript: URL { hookDirectory.appendingPathComponent("codex_permission_hook.py") }
    var spoolDirectory: URL { monitorHome.appendingPathComponent("spool", isDirectory: true) }
    var eventsFile: URL { monitorHome.appendingPathComponent("events.json") }
}

enum PermissionHookStatus: Equatable, Sendable {
    case notInstalled
    case installed
    case scriptMissing
    case invalidConfig
    case pythonUnavailable

    var title: String {
        switch self {
        case .notInstalled: "未安装"
        case .installed: "已安装"
        case .scriptMissing: "Hook 文件缺失"
        case .invalidConfig: "配置异常"
        case .pythonUnavailable: "缺少 /usr/bin/python3"
        }
    }

    var isHealthy: Bool { self == .installed }
}

enum PermissionHookInstallerError: LocalizedError {
    case invalidConfig
    case invalidHooksShape
    case pythonUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidConfig: "~/.codex/hooks.json 不是有效 JSON，未做任何覆盖。"
        case .invalidHooksShape: "~/.codex/hooks.json 的 hooks 结构无法安全合并。"
        case .pythonUnavailable: "未找到 /usr/bin/python3，无法安装权限提醒 Hook。"
        }
    }
}

struct PermissionHookInstaller {
    static let commandMarker = ".codex-monitor/hooks/codex_permission_hook.py"

    let paths: PermissionPaths
    let fileManager: FileManager

    init(paths: PermissionPaths = .default, fileManager: FileManager = .default) {
        self.paths = paths
        self.fileManager = fileManager
    }

    func status() -> PermissionHookStatus {
        guard fileManager.fileExists(atPath: "/usr/bin/python3") else { return .pythonUnavailable }
        guard fileManager.fileExists(atPath: paths.hooksConfig.path) else { return .notInstalled }
        guard let root = try? readRoot(), containsOwnedHandler(root) else {
            return (try? readRoot()) == nil ? .invalidConfig : .notInstalled
        }
        guard hasSingleCurrentHandler(root) else { return .invalidConfig }
        guard fileManager.fileExists(atPath: paths.hookScript.path) else { return .scriptMissing }
        return .installed
    }

    func install() throws {
        guard fileManager.fileExists(atPath: "/usr/bin/python3") else {
            throw PermissionHookInstallerError.pythonUnavailable
        }
        try createPrivateDirectory(paths.monitorHome)
        try createPrivateDirectory(paths.hookDirectory)
        try createPrivateDirectory(paths.spoolDirectory)
        try writeHookScript()

        var root = try readRoot()
        if hasSingleCurrentHandler(root) { return }
        root = try removingOwnedHandlers(from: root)
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        var groups = hooks["PermissionRequest"] as? [[String: Any]] ?? []
        groups.append([
            "matcher": "*",
            "hooks": [[
                "type": "command",
                "command": hookCommand,
                "async": true,
                "timeout": 3
            ]]
        ])
        hooks["PermissionRequest"] = groups
        root["hooks"] = hooks
        try writeRoot(root, backingUpExisting: true)
    }

    func uninstall() throws {
        if fileManager.fileExists(atPath: paths.hooksConfig.path) {
            let root = try readRoot()
            let cleaned = try removingOwnedHandlers(from: root)
            if !NSDictionary(dictionary: root).isEqual(to: cleaned) {
                try writeRoot(cleaned, backingUpExisting: true)
            }
        }
        if fileManager.fileExists(atPath: paths.hookScript.path) {
            try fileManager.removeItem(at: paths.hookScript)
        }
    }

    private var hookCommand: String {
        let escaped = paths.hookScript.path.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "/usr/bin/python3 \"\(escaped)\""
    }

    private func readRoot() throws -> [String: Any] {
        guard fileManager.fileExists(atPath: paths.hooksConfig.path) else { return [:] }
        let data = try Data(contentsOf: paths.hooksConfig)
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PermissionHookInstallerError.invalidConfig
        }
        if let hooks = root["hooks"], !(hooks is [String: Any]) {
            throw PermissionHookInstallerError.invalidHooksShape
        }
        if let permission = (root["hooks"] as? [String: Any])?["PermissionRequest"],
           !(permission is [[String: Any]]) {
            throw PermissionHookInstallerError.invalidHooksShape
        }
        return root
    }

    private func containsOwnedHandler(_ root: [String: Any]) -> Bool {
        let groups = (root["hooks"] as? [String: Any])?["PermissionRequest"] as? [[String: Any]] ?? []
        return groups.contains { group in
            let handlers = group["hooks"] as? [[String: Any]] ?? []
            return handlers.contains { handler in
                (handler["command"] as? String)?.contains(Self.commandMarker) == true
            }
        }
    }

    private func hasSingleCurrentHandler(_ root: [String: Any]) -> Bool {
        let groups = (root["hooks"] as? [String: Any])?["PermissionRequest"] as? [[String: Any]] ?? []
        let owned = groups.flatMap { $0["hooks"] as? [[String: Any]] ?? [] }.filter { handler in
            (handler["command"] as? String)?.contains(Self.commandMarker) == true
        }
        guard owned.count == 1, let handler = owned.first else { return false }
        return handler["type"] as? String == "command"
            && handler["command"] as? String == hookCommand
            && handler["async"] as? Bool == true
            && (handler["timeout"] as? NSNumber)?.intValue == 3
    }

    private func removingOwnedHandlers(from root: [String: Any]) throws -> [String: Any] {
        var root = root
        guard var hooks = root["hooks"] as? [String: Any] else { return root }
        guard let originalGroups = hooks["PermissionRequest"] as? [[String: Any]] else { return root }

        var cleanedGroups: [[String: Any]] = []
        for var group in originalGroups {
            guard let handlers = group["hooks"] as? [[String: Any]] else {
                cleanedGroups.append(group)
                continue
            }
            let remaining = handlers.filter { handler in
                !((handler["command"] as? String)?.contains(Self.commandMarker) == true)
            }
            if !remaining.isEmpty {
                group["hooks"] = remaining
                cleanedGroups.append(group)
            }
        }

        if cleanedGroups.isEmpty {
            hooks.removeValue(forKey: "PermissionRequest")
        } else {
            hooks["PermissionRequest"] = cleanedGroups
        }
        if hooks.isEmpty {
            root.removeValue(forKey: "hooks")
        } else {
            root["hooks"] = hooks
        }
        return root
    }

    private func writeRoot(_ root: [String: Any], backingUpExisting: Bool) throws {
        try fileManager.createDirectory(at: paths.codexHome, withIntermediateDirectories: true)
        let existingAttributes = try? fileManager.attributesOfItem(atPath: paths.hooksConfig.path)
        if backingUpExisting, fileManager.fileExists(atPath: paths.hooksConfig.path) {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
            let backup = paths.codexHome.appendingPathComponent(
                "hooks.json.codex-monitor-backup-\(formatter.string(from: .now))"
            )
            try fileManager.copyItem(at: paths.hooksConfig, to: backup)
        }
        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: paths.hooksConfig, options: .atomic)
        let permissions = existingAttributes?[.posixPermissions] ?? 0o600
        try? fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: paths.hooksConfig.path)
    }

    private func writeHookScript() throws {
        let data = Data(Self.hookSource.utf8)
        if (try? Data(contentsOf: paths.hookScript)) != data {
            try data.write(to: paths.hookScript, options: .atomic)
        }
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: paths.hookScript.path)
    }

    private func createPrivateDirectory(_ url: URL) throws {
        try fileManager.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    static let hookSource = #"""
#!/usr/bin/python3
import hashlib
import json
import os
import re
import sys
import uuid
from datetime import datetime, timezone
from pathlib import Path

SENSITIVE = re.compile(
    r"(?i)(authorization\s*:\s*(?:bearer\s+)?|(?:password|passwd|token|secret|api[_-]?key|apikey|access[_-]?key|cookie|session)\s*[=:]\s*)[^\s&\"']+"
)
QUERY_SECRET = re.compile(
    r"(?i)([?&](?:password|passwd|token|secret|api[_-]?key|apikey|access[_-]?key|cookie|session)=)[^&\s]+"
)
BEARER = re.compile(r"(?i)(bearer\s+)[A-Za-z0-9._~+/=-]+")


def text(value, fallback="", limit=1024):
    if not isinstance(value, str):
        return fallback
    value = value.strip()
    return (value or fallback)[:limit]


def redact(value, limit=240):
    value = text(value, limit=4096)
    if not value:
        return None
    value = re.sub(r"[\r\n\t]+", " ", value)
    value = SENSITIVE.sub(r"\1***", value)
    value = QUERY_SECRET.sub(r"\1***", value)
    value = BEARER.sub(r"\1***", value)
    return value[:limit]


def canonical(value):
    try:
        return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
    except Exception:
        return "null"


def main():
    payload = json.load(sys.stdin)
    if not isinstance(payload, dict) or payload.get("hook_event_name") != "PermissionRequest":
        return

    tool_input = payload.get("tool_input")
    input_object = tool_input if isinstance(tool_input, dict) else {}
    session_id = text(payload.get("session_id"), "unknown-session", 160)
    turn_id = text(payload.get("turn_id"), "unknown-turn", 160)
    tool_name = text(payload.get("tool_name"), "unknown", 120)
    cwd = text(payload.get("cwd"), "", 1024)
    project_name = Path(cwd).name if cwd else "未知项目"
    event_id = hashlib.sha256(
        (session_id + "|" + turn_id + "|" + tool_name + "|" + canonical(tool_input)).encode("utf-8")
    ).hexdigest()

    event = {
        "schemaVersion": 1,
        "eventType": "codex.permission.request",
        "eventId": event_id,
        "receivedAt": datetime.now(timezone.utc).isoformat(timespec="milliseconds"),
        "sessionId": session_id,
        "turnId": turn_id,
        "project": {"name": text(project_name, "未知项目", 80), "cwd": cwd},
        "permission": {
            "mode": text(payload.get("permission_mode"), "default", 80),
            "toolName": tool_name,
            "description": redact(input_object.get("description"), 160),
            "preview": redact(input_object.get("command"), 240),
        },
        "codex": {"model": text(payload.get("model"), "unknown", 120)},
        "requiresUserInput": payload.get("requires_user_input") if isinstance(payload.get("requires_user_input"), bool) else None,
        "approvalsReviewer": text(payload.get("approvals_reviewer"), "", 80) or None,
        "approvalRoute": text(payload.get("approval_route"), "", 80) or None,
        "reviewer": text(payload.get("reviewer"), "", 80) or None,
        "agentId": text(payload.get("agent_id"), "", 160) or None,
        "agentType": text(payload.get("agent_type"), "", 80) or None,
    }

    spool = Path(__file__).resolve().parent.parent / "spool"
    spool.mkdir(mode=0o700, parents=True, exist_ok=True)
    name = "evt-" + uuid.uuid4().hex
    temp_path = spool / (name + ".tmp")
    final_path = spool / (name + ".json")
    descriptor = os.open(str(temp_path), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "w", encoding="utf-8") as output:
        json.dump(event, output, ensure_ascii=False, separators=(",", ":"))
        output.flush()
        os.fsync(output.fileno())
    os.replace(temp_path, final_path)


try:
    main()
except Exception:
    pass
sys.exit(0)
"""#
}
