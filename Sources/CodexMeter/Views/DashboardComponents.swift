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
