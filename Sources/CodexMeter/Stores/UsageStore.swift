import Foundation
import Observation
import WidgetKit

@MainActor
@Observable
final class UsageStore {
    private(set) var snapshot = UsageSnapshot.empty
    private(set) var isRefreshing = false
    private(set) var errorMessage: String?
    private let reader = CodexUsageReader()
    @ObservationIgnored private let folderAccess = CodexFolderAccess()

    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            snapshot = try await reader.load(codexHome: folderAccess.selectedURL)
            if let rate = snapshot.sevenDayRate { RateHistory.append(rate.usedPercent); UsageNotifier.evaluate(rate) }
            WidgetUsageCache.save(
                WidgetUsageData(
                    todayTokens: snapshot.today.total,
                    weekTokens: snapshot.lastSevenDays.total,
                    monthTokens: snapshot.thisMonth.total,
                    contextTokens: snapshot.currentContextUsed,
                    contextLimit: snapshot.contextWindow,
                    ratePercent: snapshot.sevenDayRate?.usedPercent,
                    rateWindowMinutes: snapshot.sevenDayRate?.windowMinutes,
                    updatedAt: .now
                )
            )
            WidgetCenter.shared.reloadAllTimelines()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func chooseCodexFolder() {
        do {
            guard try folderAccess.chooseFolder() != nil else { return }
            Task { await refresh() }
        } catch {
            errorMessage = "无法保存目录授权：\(error.localizedDescription)"
        }
    }

    func requestCodexFolderIfNeeded() {
        guard folderAccess.selectedURL == nil else { return }
        chooseCodexFolder()
    }
}
