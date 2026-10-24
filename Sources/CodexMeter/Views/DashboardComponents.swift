import SwiftUI

struct PageHeader: View {
    let title: String; let subtitle: String; let store: UsageStore
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.title2.weight(.semibold))
                Text(subtitle).font(.subheadline).foregroundStyle(DashboardPalette.secondaryInk)
                if let error = store.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(DashboardPalette.secondaryInk)
                }
            }
            Spacer()
        }
    }
}

/// A stable status row: checking local files never implies a new quota observation.
struct UsageRefreshStatusView: View {
    let store: UsageStore
    var compact = false
    var secondaryInk: Color = DashboardPalette.secondaryInk

    private var feedback: UsageRefreshFeedback? {
        guard let feedback = store.refreshFeedback,
              (store.lastSuccessfulRefresh ?? .distantPast) <= feedback.checkedAt else { return nil }
        return feedback
    }

    private var message: String {
        if store.isRefreshing { return "正在刷新本机用量…" }
        if store.errorMessage != nil {
            return feedback?.outcome == .failed ? "刷新失败，请查看提示" : "读取不完整，请查看提示"
        }
        if let feedback { return feedback.message }
        return store.lastSuccessfulRefresh == nil ? "等待本机记录" : "本机统计已更新"
    }

    private var symbol: String {
        if store.errorMessage != nil { return "exclamationmark.triangle" }
        switch feedback?.outcome {
        case .incomplete, .failed: return "exclamationmark.triangle"
        case .noNewSample: return "clock"
        case .newSample: return "checkmark.circle"
        case nil: return "clock.arrow.circlepath"
        }
    }

    private var detail: String {
        if store.isRefreshing { return store.loadingMessage }
        var lines = [message]
        if let checkedAt = feedback?.checkedAt ?? store.lastSuccessfulRefresh {
            lines.append("本机检查于 \(checkedAt.formatted(date: .abbreviated, time: .standard))")
        }
        if let error = store.errorMessage ?? feedback?.detail { lines.append(error) }
        lines.append("检查时间仅表示本机读取完成；额度仍以原始采样时间为准。")
        return lines.joined(separator: "\n")
    }

    var body: some View {
        HStack(spacing: 6) {
            if store.isRefreshing {
                ProgressView().progressViewStyle(.circular).controlSize(.mini)
                    .frame(width: 14, height: 14)
            } else {
                Image(systemName: symbol).frame(width: 14)
            }
            Text(message).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 0)
            if !compact, !store.isRefreshing,
               let checkedAt = feedback?.checkedAt ?? store.lastSuccessfulRefresh {
                Text(checkedAt.formatted(.dateTime.hour().minute()))
                    .monospacedDigit()
            }
        }
        .font(compact ? .caption2 : .caption)
        .foregroundStyle(secondaryInk)
        .frame(height: compact ? 18 : 24)
        .help(detail)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(detail)
    }
}

struct QuotaHealthBadge: View {
    let health: QuotaHealth

    var body: some View {
        Label(health.title, systemImage: health.icon)
            .font(.caption.weight(health == .critical || health == .watch ? .semibold : .regular))
            .foregroundStyle(health.color)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(DashboardPalette.surface, in: Capsule())
            .overlay {
                Capsule().strokeBorder(health == .critical ? DashboardPalette.ink : DashboardPalette.divider,
                                       style: StrokeStyle(lineWidth: health == .critical ? 1.5 : 1,
                                                          dash: health == .waiting || health == .insufficient ? [3, 3] : []))
            }
            .help(health.detail)
            .accessibilityLabel("\(health.title)。\(health.detail)")
    }
}

struct TokenUsageBreakdownView: View {
    let usage: TokenUsage
    var title = "今日 Token 构成"
    var selectedRange: Binding<String>? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(title).font(.callout.weight(.semibold))
                if let selectedRange {
                    Picker("Token 统计范围", selection: selectedRange) {
                        Text("今天").tag("today")
                        Text("近 7 天").tag("week")
                        Text("本月").tag("month")
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 200)
                }
                Spacer()
                Text("合计 \(UsageFormatters.tokens(usage.total))")
                    .font(.caption).monospacedDigit().foregroundStyle(DashboardPalette.secondaryInk)
            }
            HStack(alignment: .top, spacing: 24) {
                MetricRow("非缓存输入", UsageFormatters.tokens(usage.uncachedInput))
                MetricRow("缓存输入", UsageFormatters.tokens(usage.cachedInputPortion))
                MetricRow("输出", UsageFormatters.tokens(usage.output))
            }
            Text("缓存输入已计入输入和合计，不重复相加；缓存仍消耗 Token。订阅额度以账户采样为准。")
                .font(.caption).foregroundStyle(DashboardPalette.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)
                .help("非缓存输入 = 输入 − 缓存输入。缓存通常使用较低费率，并非免费；推理 Token 已包含在输出中。")
        }
    }
}

struct DashboardSidebar: View {
    @Binding var selection: String?
    private let items: [(String, String)] = [
        ("健康报告", "house"),
        ("使用趋势", "chart.xyaxis.line"),
        ("模型与效率", "cpu"),
        ("项目与用量", "folder"),
        ("预测与风险", "scope"),
        ("历史记录", "clock")
    ]

    var body: some View {
        List {
            Section("用量") {
                ForEach(Array(items.enumerated()), id: \.element.0) { index, item in
                    Button { selection = item.0 } label: {
                        Label(item.0, systemImage: item.1)
                            .font(.callout.weight(selection == item.0 ? .semibold : .regular))
                            .foregroundStyle(DashboardPalette.ink)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10).padding(.vertical, 9)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(DashboardNavigationButtonStyle(selected: selection == item.0))
                    .listItemTint(.monochrome)
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
                    .help("\(item.0) · ⌘\(index + 1)")
                    .accessibilityAddTraits(selection == item.0 ? .isSelected : [])
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            Label("本机统计", systemImage: "lock.shield")
                .font(.caption).foregroundStyle(DashboardPalette.secondaryInk)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
        }
    }
}

private struct DashboardNavigationButtonStyle: ButtonStyle {
    let selected: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                RoundedRectangle(cornerRadius: 8)
                    .fill(selected ? DashboardPalette.ink.opacity(0.09)
                          : hovered || configuration.isPressed ? DashboardPalette.hover : .clear)
            }
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1)
            .onHover { hovered = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: hovered)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Quiet, opaque data surfaces; system glass remains on the window controls.
struct DashboardPanel<Content: View>: View {
    let content: Content
    @Environment(\.colorSchemeContrast) private var contrast

    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
            .background(DashboardPalette.surface, in: RoundedRectangle(cornerRadius: 18))
            .overlay {
                if contrast == .increased {
                    RoundedRectangle(cornerRadius: 18)
                        .strokeBorder(DashboardPalette.secondaryInk, lineWidth: 1)
                }
            }
    }
}

/// Glass is reserved for peripheral controls and floating surfaces.
struct PeripheralGlass: ViewModifier {
    var cornerRadius: CGFloat = 12
    var interactive = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ViewBuilder func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if reduceTransparency {
            content.background(Color(nsColor: .windowBackgroundColor), in: shape)
        } else if #available(macOS 26.0, *) {
            content.glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        } else {
            content.background(.regularMaterial, in: shape)
        }
    }
}

/// A flat section shared by the analysis pages; spacing and a rule provide hierarchy.
struct DashboardCard<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 18)
            .overlay(alignment: .bottom) { FlatDivider() }
    }
}

struct SummaryMetric: View {
    let title: String
    let value: String
    let detail: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption).foregroundStyle(DashboardPalette.secondaryInk)
            Text(value).font(.system(size: 26, weight: .medium)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(0.75)
            Text(detail).font(.caption).foregroundStyle(DashboardPalette.secondaryInk)
        }
    }
}

struct MetricRow: View {
    let title: String
    let value: String
    init(_ title: String, _ value: String) { self.title = title; self.value = value }
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(DashboardPalette.secondaryInk)
            Text(value).font(.callout.weight(.medium)).monospacedDigit().lineLimit(1)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension QuotaHealth {
    var color: Color {
        switch self {
        case .waiting, .insufficient: DashboardPalette.secondaryInk
        case .critical: DashboardPalette.ink
        case .watch: DashboardPalette.secondaryInk
        case .healthy: DashboardPalette.ink
        }
    }
    var icon: String {
        switch self {
        case .waiting, .insufficient: "hourglass"
        case .critical: "exclamationmark.triangle.fill"
        case .watch: "exclamationmark.shield"
        case .healthy: "checkmark.shield.fill"
        }
    }
}

/// Draws determinate progress in gray with the native value semantics intact.
struct FlatProgressStyle: ProgressViewStyle {
    func makeBody(configuration: Configuration) -> some View {
        if let fraction = configuration.fractionCompleted {
            VStack(alignment: .leading, spacing: 6) {
                configuration.label
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Rectangle().fill(DashboardPalette.divider)
                        Rectangle().fill(DashboardPalette.progress)
                            .frame(width: proxy.size.width * min(1, max(0, fraction)))
                    }
                }
                .frame(height: 3)
                configuration.currentValueLabel
            }
        } else {
            VStack(spacing: 6) {
                configuration.label
                ProgressView().progressViewStyle(.circular)
                configuration.currentValueLabel
            }
        }
    }
}


struct FlatDivider: View {
    var body: some View {
        Rectangle().fill(DashboardPalette.divider).frame(height: 1)
    }
}
