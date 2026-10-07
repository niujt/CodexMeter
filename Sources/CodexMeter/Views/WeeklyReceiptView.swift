import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Capture the snapshot when opening, so preview and export always agree.
struct WeeklyReceiptData {
    let snapshot: UsageSnapshot
    let issuedAt: Date
    var end: Date { snapshot.lastUpdated ?? issuedAt }
    var days: [DailyUsage] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: end)
        let totals = Dictionary(grouping: snapshot.dailyUsage, by: { calendar.startOfDay(for: $0.date) })
        return (-6...0).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset, to: today) else { return nil }
            return DailyUsage(date: date, tokens: totals[date]?.reduce(0) { $0 + $1.tokens } ?? 0)
        }
    }
}

struct WeeklyReceiptButton: View {
    let snapshot: UsageSnapshot
    @State private var receipt: WeeklyReceiptData?

    var body: some View {
        Button { receipt = WeeklyReceiptData(snapshot: snapshot, issuedAt: .now) } label: {
            Label("导出周用量小票", systemImage: "receipt")
        }
        .disabled(snapshot.lastUpdated == nil)
        .sheet(isPresented: Binding(get: { receipt != nil }, set: { if !$0 { receipt = nil } })) {
            if let receipt { WeeklyReceiptPreview(data: receipt) }
        }
    }
}

private struct WeeklyReceiptPreview: View {
    let data: WeeklyReceiptData
    @Environment(\.dismiss) private var dismiss
    @State private var errorMessage: String?
    @State private var saved = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("周用量小票").font(.headline)
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(20)
            ScrollView {
                WeeklyReceiptView(data: data)
                    .padding(24)
            }.background(.quaternary)
            HStack {
                Text(saved ? "小票已保存" : "PNG 图片 · 高清导出")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("保存 PNG…", action: save)
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }.padding(20)
        }
        .frame(width: 480, height: 760)
        .alert("导出失败", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("好") { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    @MainActor private func save() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "Codex-Health-周用量-\(data.end.formatted(.iso8601.year().month().day().dateSeparator(.dash))).png"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try WeeklyReceiptExporter.png(data: data).write(to: url, options: .atomic)
            saved = true
        } catch { errorMessage = error.localizedDescription }
    }
}

enum WeeklyReceiptExporter {
    @MainActor static func png(data: WeeklyReceiptData) throws -> Data {
        let renderer = ImageRenderer(content: WeeklyReceiptView(data: data))
        renderer.scale = 3
        guard let image = renderer.cgImage,
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return png
    }
}

struct WeeklyReceiptView: View {
    let data: WeeklyReceiptData
    private let ink = Color(red: 0.19, green: 0.20, blue: 0.18)
    private let accent = Color(red: 0.57, green: 0.30, blue: 0.25)

    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 8) {
                Image(systemName: "terminal").font(.system(size: 28, weight: .medium))
                Text("CODEX HEALTH").font(.system(size: 19, weight: .bold, design: .monospaced)).tracking(3)
                Text("WEEKLY USAGE RECEIPT").font(.system(size: 9, design: .monospaced)).tracking(2)
                Text("近 7 天用量小票").font(.system(size: 12))
            }
            rule
            VStack(spacing: 6) {
                Text("\(data.days.first!.date.formatted(.dateTime.year().month().day())) — \(data.end.formatted(.dateTime.month().day()))")
                Text("截至 \(data.end.formatted(date: .omitted, time: .shortened)) · \(TimeZone.current.abbreviation() ?? "本地时间")")
            }.font(.system(size: 10, design: .monospaced))
            rule
            VStack(spacing: 12) {
                row("日期 / DATE", "TOKENS", bold: true)
                ForEach(data.days, id: \.date) { day in
                    row(day.date.formatted(.dateTime.month(.twoDigits).day(.twoDigits).weekday(.abbreviated)), day.tokens.formatted())
                }
            }
            rule
            VStack(spacing: 10) {
                row("输入", data.snapshot.lastSevenDays.input.formatted())
                row("缓存输入（含于输入）", data.snapshot.lastSevenDays.cachedInput.formatted())
                row("输出", data.snapshot.lastSevenDays.output.formatted())
                row("推理输出（含于输出）", data.snapshot.lastSevenDays.reasoningOutput.formatted())
            }
            rule
            VStack(spacing: 5) {
                row("合计 / TOTAL", "TOKEN", bold: true)
                Text(data.snapshot.lastSevenDays.total.formatted())
                    .font(.system(size: 34, weight: .bold, design: .monospaced))
                    .minimumScaleFactor(0.5).lineLimit(1).frame(maxWidth: .infinity, alignment: .trailing)
            }
            Text("本机已记录")
                .font(.system(size: 20, weight: .bold, design: .monospaced)).tracking(3)
                .padding(.horizontal, 18).padding(.vertical, 9)
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(accent, lineWidth: 2))
                .foregroundStyle(accent).rotationEffect(.degrees(-5)).padding(.vertical, 8)
            VStack(spacing: 7) {
                Text("记录所选目录的 Token 用量").font(.system(size: 10))
                if data.snapshot.readWarning != nil {
                    Text("部分记录读取不完整").font(.system(size: 10, weight: .semibold))
                }
                Text("THANK YOU FOR BUILDING").font(.system(size: 9, design: .monospaced)).tracking(1)
                Text("生成于 \(data.issuedAt.formatted(date: .numeric, time: .shortened))")
                    .font(.system(size: 9, design: .monospaced))
            }.opacity(0.65)
        }
        .foregroundStyle(ink)
        .padding(.horizontal, 28).padding(.vertical, 36)
        .frame(width: 360)
        .background(Color.white)
        .clipShape(ReceiptPaper())
        .environment(\.colorScheme, .light)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var rule: some View {
        ReceiptRule().stroke(ink.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [3, 4])).frame(height: 1)
    }

    private func row(_ title: String, _ value: String, bold: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title)
            Spacer(minLength: 4)
            Text(value).monospacedDigit()
        }.font(.system(size: 11, weight: bold ? .bold : .regular, design: .monospaced))
    }
}

private struct ReceiptRule: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in path.move(to: .zero); path.addLine(to: CGPoint(x: rect.width, y: 0)) }
    }
}

private struct ReceiptPaper: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            let teeth = 36
            let step = rect.width / CGFloat(teeth)
            path.move(to: CGPoint(x: 0, y: 0))
            for tooth in 0..<teeth {
                let x = CGFloat(tooth) * step
                path.addLine(to: CGPoint(x: x + step / 2, y: 5))
                path.addLine(to: CGPoint(x: x + step, y: 0))
            }
            path.addLine(to: CGPoint(x: rect.width, y: rect.height))
            for tooth in (0..<teeth).reversed() {
                let x = CGFloat(tooth) * step
                path.addLine(to: CGPoint(x: x + step / 2, y: rect.height - 5))
                path.addLine(to: CGPoint(x: x, y: rect.height))
            }
            path.closeSubpath()
        }
    }
}
