import SwiftUI

struct PageHeader: View {
    let title: String; let subtitle: String; let store: UsageStore
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.title2.weight(.semibold))
                Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                if let error = store.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
    }
}

enum DashboardPalette {
    static let ink = Color.primary
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
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10).padding(.vertical, 9)
                            .background(.primary.opacity(selection == item.0 ? 0.08 : 0),
                                        in: RoundedRectangle(cornerRadius: 6))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
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
                .font(.caption).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
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
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(size: 28, weight: .medium)).monospacedDigit()
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct MetricRow: View {
    let title: String
    let value: String
    init(_ title: String, _ value: String) { self.title = title; self.value = value }
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout.weight(.medium)).monospacedDigit().lineLimit(1)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension QuotaHealth {
    var color: Color {
        switch self {
        case .waiting, .insufficient: .secondary
        case .critical: .primary
        case .watch: .secondary
        case .healthy: DashboardPalette.ink
        }
    }
    var icon: String {
        switch self {
        case .waiting, .insufficient: "hourglass"
        case .critical, .watch: "exclamationmark.shield.fill"
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
                        Rectangle().fill(.primary.opacity(0.1))
                        Rectangle().fill(.primary.opacity(0.75))
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
        Rectangle().fill(.primary.opacity(0.12)).frame(height: 1)
    }
}
