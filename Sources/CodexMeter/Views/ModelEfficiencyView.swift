import SwiftUI

struct ModelEfficiencyView: View {
    let store: UsageStore
    private var total: Int { store.snapshot.topModels.reduce(0) { $0 + $1.tokens } }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            PageHeader(title: "模型与效率", subtitle: "有效轮次仅统计可配对的用户消息与最终回答；耗时为端到端时长。", store: store)
            if store.snapshot.topModels.isEmpty {
                ContentUnavailableView("暂无模型样本", systemImage: "cpu")
                    .frame(maxWidth: .infinity, minHeight: 420)
            } else {
                VStack(spacing: 12) {
                    ForEach(store.snapshot.topModels, id: \.name) { model in
                        DashboardCard {
                            VStack(alignment: .leading, spacing: 12) {
                                HStack {
                                    Image(systemName: "cpu.fill").foregroundStyle(DashboardPalette.ink)
                                    Text(model.name).font(.headline).lineLimit(1)
                                    Spacer()
                                    Text("\(Int(Double(model.tokens) / Double(max(1, total)) * 100))% 占比")
                                        .font(.callout.weight(.semibold)).foregroundStyle(DashboardPalette.ink)
                                }
                                ProgressView(value: Double(model.tokens), total: Double(max(1, total))).tint(DashboardPalette.progress)
                                HStack {
                                    ModelMetric(label: "Token", value: UsageFormatters.tokens(model.tokens))
                                    ModelMetric(label: "有效轮次", value: "\(model.requests) 次")
                                    ModelMetric(label: "平均轮次耗时", value: model.averageTurnSeconds.map { UsageFormatters.turnDuration(seconds: $0) } ?? "样本不足")
                                    ModelMetric(label: "缓存命中率", value: model.cacheHitRate.map(UsageFormatters.percentage) ?? "样本不足")
                                        .help("缓存命中率 = 缓存输入 / 全部输入。缓存输入仍消耗 Token，按缓存费率计费，不代表免费或等额减少订阅额度。")
                                }
                            }
                        }
                    }
                }
            }
        }
        .padding(28).frame(maxWidth: 1_100, alignment: .leading)
    }
}

private struct ModelMetric: View {
    let label: String; let value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption).foregroundStyle(DashboardPalette.secondaryInk)
            Text(value).font(.callout.weight(.semibold)).monospacedDigit()
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}
