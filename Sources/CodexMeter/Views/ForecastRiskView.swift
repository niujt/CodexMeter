import SwiftUI

struct ForecastRiskView: View {
    let store: UsageStore
    private var rate: RateWindow? { store.snapshot.currentSevenDayRate() }
    private var remaining: Int { max(0, 100 - Int((rate?.usedPercent ?? 0).rounded())) }
    private var resetHours: Double? { rate.map { max(0, $0.resetsAt.timeIntervalSinceNow / 3_600) } }
    private var hourlyRate: Double? {
        QuotaHealth.velocity(rate: rate, measured: store.measuredVelocity?.percentPerHour)
    }
    private var remainingHours: Double? {
        guard let hourlyRate, hourlyRate > 0 else { return nil }
        return Double(remaining) / hourlyRate
    }
    private var willExhaust: Bool { (remainingHours ?? .infinity) < (resetHours ?? 0) }
    private var health: QuotaHealth { .evaluate(rate: rate, percentPerHour: hourlyRate) }
    private var color: Color { health.color }

    var body: some View {
        TimelineView(.explicit([Date.now] + store.snapshot.quotaDisplayDeadlines)) { _ in content }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 20) {
            PageHeader(title: "预测与风险", subtitle: "预测按 1 / 6 / 24 小时额度变化加权；没有足够样本时使用本周期平均速度。", store: store)
            if let rate {
                HStack(spacing: 16) {
                    DashboardCard {
                        VStack(alignment: .leading, spacing: 12) {
                            QuotaSampleView(title: "7 天额度", window: rate, sampledAt: store.snapshot.mainRateSampledAt, numberSize: 36)
                            Text("约 \(UsageFormatters.countdown(to: rate.resetsAt)) 后重置").font(.caption).foregroundStyle(DashboardPalette.secondaryInk)
                        }
                    }.frame(maxWidth: .infinity)
                    DashboardCard {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("续航预测").font(.headline)
                            Text(remainingHours.map { UsageFormatters.duration(hours: $0) } ?? "样本不足")
                                .font(.system(size: 32, weight: .medium)).foregroundStyle(color)
                            Text(remainingHours == nil ? "继续使用一段时间后会形成预测" : (willExhaust ? "可能在重置前耗尽" : "预计可支撑到重置"))
                                .foregroundStyle(DashboardPalette.ink)
                            Text("当前平均消耗 \(hourlyRate.map { String(format: "%.2f%% / 小时", $0) } ?? "—")").font(.caption).foregroundStyle(DashboardPalette.secondaryInk)
                        }
                    }.frame(maxWidth: .infinity)
                }
                DashboardCard {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("风险说明").font(.headline)
                        RiskLine(icon: health.icon, color: health.color, title: health.title, detail: health.detail)
                        RiskLine(icon: "clock.arrow.circlepath", color: DashboardPalette.ink, title: "下次重置", detail: rate.resetsAt.formatted(.dateTime.year().month().day().hour().minute()))
                        RiskLine(icon: "chart.line.uptrend.xyaxis", color: DashboardPalette.secondaryInk, title: "估算依据", detail: store.measuredVelocity.map { "已使用近 \($0.description) 小时的额度变化样本。" } ?? "暂无连续变化样本，已使用本周期平均速度。")
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    QuotaSampleView(title: "7 天额度", window: store.snapshot.sevenDayRate, sampledAt: store.snapshot.mainRateSampledAt)
                    Text("等待新额度采样后恢复预测").foregroundStyle(DashboardPalette.secondaryInk)
                }
                    .frame(maxWidth: .infinity, minHeight: 420)
            }
        }
        .padding(28).frame(maxWidth: 1_100, alignment: .leading)
    }
}

private struct RiskLine: View {
    let icon: String; let color: Color; let title: String; let detail: String
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).foregroundStyle(color).frame(width: 20)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.callout.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(DashboardPalette.secondaryInk)
            }
        }
    }
}
