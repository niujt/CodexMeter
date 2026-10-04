#!/usr/bin/env python3
"""Open an isolated screenshot preview using actual SwiftUI views and synthetic data.

Requires macOS and Xcode. The temporary preview app has a unique bundle ID.
Its copied usage store, reset client and rate history use in-memory fixtures;
it never starts the real app delegate, reads Codex records, or calls ChatGPT.
Temporary build files are retained for inspection, without deleting anything.
"""

import pathlib
import plistlib
import subprocess
import tempfile
import uuid


ROOT = pathlib.Path(__file__).resolve().parent.parent
WORK = pathlib.Path(tempfile.mkdtemp(prefix="codex-health-screenshots-"))
APP = WORK / "Codex Health Preview.app"
SOURCES = WORK / "Sources"
SOURCES.mkdir()
(APP / "Contents/MacOS").mkdir(parents=True)

usage_store = """import Foundation
import Observation
import WidgetKit

extension Notification.Name {
    static let codexHealthUsageDidRefresh = Notification.Name("codexHealthUsageDidRefresh")
}

@MainActor @Observable final class UsageStore {
    static let shared = UsageStore()
    var snapshot = ScreenshotFixture.snapshot
    var isRefreshing = false
    var errorMessage: String?
    var processedFiles = 0
    var totalFiles = 0
    var readFiles = 0
    var reusedFiles = 0
    var loadingMessage: String { "" }
    var selectedCodexPath: String { "/demo/codex" }
    func refresh(force: Bool = false) async {}
    func refreshIfNeeded() async {}
    func chooseCodexFolder() {}
    func requestCodexFolderIfNeeded() {}
}

"""

for path in sorted((ROOT / "Sources/CodexMeter").rglob("*.swift")):
    source = path.read_text()
    if path.name == "CodexMeterApp.swift":
        source = source.replace("@main\n", "")
        source = source.replace(
            "AnalyticsDashboardView(store: store)",
            'AnalyticsDashboardView(store: store, selectedSection: .constant("健康报告"))',
        )
    elif path.name == "UsageStore.swift":
        source = usage_store + source[source.index("struct CachedQuotaRate:"):]
    elif path.name == "AnalyticsDashboardView.swift":
        source = source.replace(
            '@State private var selectedSection: String? = "健康报告"',
            '@Binding var selectedSection: String?',
        )
    elif path.name == "RateHistory.swift":
        source = source[:source.index("enum RateHistory {")] + """enum RateHistory {
    static func append(_ percent: Double) {}
    static func samples() -> [RateSample] { [] }
    static func weightedVelocity(now: Date = .now) -> RateVelocity? {
        RateVelocity(percentPerHour: 0.35, windowsUsed: [1, 6, 24])
    }
}
"""
    elif path.name == "ResetHistoryClient.swift":
        source = source[:source.index("actor ResetHistoryClient {")] + """actor ResetHistoryClient {
    func load(codexPath: String) async throws -> [ResetHistoryEvent] {
        [ResetHistoryEvent(id: "demo-used", kind: "used", occurredAt: ScreenshotFixture.now.addingTimeInterval(-86400)),
         ResetHistoryEvent(id: "demo-granted", kind: "granted", occurredAt: ScreenshotFixture.now.addingTimeInterval(-3 * 86400))]
    }
}
"""
    (SOURCES / path.name).write_text(source)

widget = (ROOT / "Sources/CodexMeterWidget/CodexMeterWidget.swift").read_text().replace("@main\n", "")
widget = widget.replace(
    '@Environment(\\.widgetFamily) private var family',
    'var family: WidgetFamily = .systemMedium',
)
widget += """

struct DocumentationWidgetPreview: View {
    private var entry: UsageEntry {
        UsageEntry(date: ScreenshotFixture.now, usage: ScreenshotFixture.widgetUsage)
    }
    var body: some View {
        HStack(spacing: 20) {
            CodexMeterWidgetView(family: .systemSmall, entry: entry)
                .padding(16).frame(width: 190, height: 190)
                .background(.background, in: RoundedRectangle(cornerRadius: 16))
            CodexMeterWidgetView(family: .systemMedium, entry: entry)
                .padding(16).frame(width: 380, height: 190)
                .background(.background, in: RoundedRectangle(cornerRadius: 16))
        }
        .padding(20)
    }
}
"""
(SOURCES / "CodexMeterWidget.swift").write_text(widget)
(SOURCES / "ScreenshotApp.swift").write_text((ROOT / "script/ScreenshotApp.swift").read_text())

info = {
    "CFBundleExecutable": "ScreenshotPreview",
    "CFBundleIdentifier": "local.codexhealth.screenshots." + uuid.uuid4().hex,
    "CFBundleName": "Codex Health Preview",
    "CFBundlePackageType": "APPL",
    "LSMinimumSystemVersion": "15.0",
    "NSPrincipalClass": "NSApplication",
    "NSHighResolutionCapable": True,
}
with (APP / "Contents/Info.plist").open("wb") as handle:
    plistlib.dump(info, handle)

print(f"Preview workspace: {WORK}", flush=True)
subprocess.run([
    "xcrun", "swiftc", "-swift-version", "6", "-parse-as-library",
    *map(str, sorted(SOURCES.glob("*.swift"))),
    "-o", str(APP / "Contents/MacOS/ScreenshotPreview"),
], check=True)
subprocess.run(["/usr/bin/open", "-n", str(APP)], check=True)
print("Preview ready. Use the sidebar for analysis pages and the 演示预览 menu for appearance, menu and widget previews.")
print("Take screenshots of the window, then quit the preview app when finished.")
