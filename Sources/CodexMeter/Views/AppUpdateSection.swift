import SwiftUI

@MainActor
struct AppUpdateSection: View {
    @ObservedObject private var updater = AppUpdateChecker.shared

    var body: some View {
        VStack(spacing: 10) {
            FlatDivider()
            Button("检查更新…", systemImage: "arrow.triangle.2.circlepath") {
                updater.checkForUpdates()
            }
            .disabled(!updater.canCheckForUpdates)
            if let error = updater.errorMessage {
                Text(error).foregroundStyle(DashboardPalette.secondaryInk)
            } else {
                Text("发现新版后可直接下载，并安装与重启应用。")
                    .foregroundStyle(DashboardPalette.secondaryInk)
                Text("更新包与更新信息均经过签名验证；可在更新窗口取消。")
                    .foregroundStyle(DashboardPalette.secondaryInk)
            }
        }
        .font(.caption)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 420)
    }
}
