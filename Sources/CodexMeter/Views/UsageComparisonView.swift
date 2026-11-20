import Observation
import SwiftUI

@MainActor
@Observable
final class UsageComparisonPresentation {
    struct Request: Identifiable {
        let report: UsageComparison
        let contextID: String?
        var id: Date { report.id }
    }

    static let shared = UsageComparisonPresentation()
    var request: Request?

    func show(_ report: UsageComparison, in store: UsageStore) {
        request = Request(report: report, contextID: store.context?.id)
    }
}

struct UsageComparisonView: View {
    let report: UsageComparison
    @State private var projectPath: String
    @Environment(\.dismiss) private var dismiss

    init(report: UsageComparison) {
        self.report = report
        _projectPath = State(initialValue: report.projects.first?.path ?? "")
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("本机用量变化").font(.title2.weight(.semibold))
                    Text("今天与昨天各自 00:00–\(report.cutoffLabel) · 本机 Token")
                        .font(.callout).foregroundStyle(DashboardPalette.secondaryInk)
                }
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(24)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    DashboardPanel {
                        HStack(spacing: 24) {
                            MetricRow("今天同期", UsageFormatters.tokens(report.totals.today.total))
                            MetricRow("昨天同期", UsageFormatters.tokens(report.totals.yesterday.total))
                            MetricRow("变化", changeText(report.totals.change))
                        }
                    }
                    if let project = report.projects.first(where: { $0.path == projectPath }) {
                        projectDetail(project)
                    }
                }
                .padding(24)
            }
            .background(DashboardPalette.canvas)
        }
        .frame(width: 730, height: 585)
    }

    private func projectDetail(_ project: UsageComparison.Project) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Picker("项目", selection: $projectPath) {
                    ForEach(report.projects) { item in
                        Text("\(item.name)  \(changeText(item.totals.change))")
                            .lineLimit(1).tag(item.path).help(item.path)
                    }
                }
                .frame(maxWidth: 340, alignment: .leading)
                Spacer()
                Text("该项目 \(changeText(project.totals.change)) Token").font(.callout.weight(.medium))
            }
            .help(project.path)
            DashboardPanel {
                HStack(spacing: 24) {
                    let today = project.totals.today
                    let yesterday = project.totals.yesterday
                    MetricRow("非缓存输入变化", changeText(today.uncachedInput - yesterday.uncachedInput))
                    MetricRow("缓存输入变化", changeText(today.cachedInputPortion - yesterday.cachedInputPortion))
                    MetricRow("输出变化", changeText(today.output - yesterday.output))
                }
            }
            HStack(alignment: .top, spacing: 16) {
                DashboardPanel {
                    changes("模型", rows: project.models.map { (label: $0.key, change: $0.value.change) })
                }
                DashboardPanel {
                    changes("小时", rows: project.hours.map {
                        let start = report.today.start.addingTimeInterval(Double($0.key) * 3_600)
                        let end = start.addingTimeInterval(3_600)
                        return ("\(start.formatted(.dateTime.hour().minute()))–\(end.formatted(.dateTime.hour().minute()))", $0.value.change)
                    })
                }
            }
        }
    }

    private func changes(_ title: String, rows: [(label: String, change: Int)]) -> some View {
        let ranked = rows.filter { $0.change != 0 }.sorted {
            abs($0.change) == abs($1.change) ? $0.label < $1.label : abs($0.change) > abs($1.change)
        }
        return VStack(alignment: .leading, spacing: 10) {
            Text("\(title)变化").font(.callout.weight(.semibold))
            if ranked.isEmpty {
                Text("同期用量一致").foregroundStyle(DashboardPalette.secondaryInk)
            }
            ForEach(Array(ranked.prefix(5)), id: \.label) { row in
                HStack {
                    Text(row.label).lineLimit(1).help(row.label)
                    Spacer()
                    Text(changeText(row.change)).monospacedDigit()
                }
            }
            if ranked.count > 5 {
                Text("按变化量显示前 5 项").font(.caption).foregroundStyle(DashboardPalette.secondaryInk)
            }
        }
        .font(.callout)
    }

    private func changeText(_ tokens: Int) -> String {
        if tokens == 0 { return "0" }
        return (tokens > 0 ? "+" : "−") + UsageFormatters.tokens(abs(tokens))
    }
}
