import SwiftUI

enum AppIconStyle: String, CaseIterable, Identifiable {
    case flat, glass
    static let preferenceKey = "codexMeter.appIconStyle"
    var id: String { rawValue }
    var title: String { self == .flat ? "N 品牌（默认）" : "玻璃 · 黑白" }

    func assetName(for colorScheme: ColorScheme) -> String {
        switch (self, colorScheme) {
        case (.flat, .light): "FlatAppIconLight"
        case (.flat, .dark): "FlatAppIcon"
        case (.glass, .light): "GlassAppIcon"
        case (.glass, .dark): "GlassAppIconDark"
        @unknown default: self == .glass ? "GlassAppIcon" : "FlatAppIconLight"
        }
    }

    @MainActor private static var appliedAssetName: String?

    static func selected(defaults: UserDefaults = .standard) -> AppIconStyle {
        AppIconStyle(rawValue: defaults.string(forKey: preferenceKey) ?? "") ?? .flat
    }

    @MainActor static func applyDockIcon(defaults: UserDefaults = .standard) {
        let style = selected(defaults: defaults)
        if defaults.string(forKey: preferenceKey) == "original" {
            defaults.set(AppIconStyle.flat.rawValue, forKey: preferenceKey)
        }
        let appearance = AppAppearance(rawValue: defaults.string(forKey: AppAppearance.preferenceKey) ?? "") ?? .system
        let assetName = style.assetName(for: appearance.resolvedColorScheme(for: NSApp.effectiveAppearance))
        guard assetName != appliedAssetName else { return }
        guard let image = NSImage(named: assetName) else { return }
        NSApp.applicationIconImage = image
        appliedAssetName = assetName
    }
}

@MainActor
private struct SettingsLogo: View {
    let assetName: String
    let size: CGFloat
    @Environment(\.displayScale) private var displayScale

    private static let thumbnails = NSCache<NSString, CGImage>()

    var body: some View {
        let scale = max(2, displayScale)
        let pixels = Int((size * scale).rounded(.up))
        let image = Self.thumbnail(named: assetName, pixels: pixels)
            .map { Image(decorative: $0, scale: scale) } ?? Image(assetName)
        image.resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: size, height: size)
    }

    private static func thumbnail(named name: String, pixels: Int) -> CGImage? {
        let key = "\(name):\(pixels)" as NSString
        if let image = thumbnails.object(forKey: key) { return image }
        guard let source = NSImage(named: name)?.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }

        // Prefilter the square asset before SwiftUI lays it out in points.
        context.interpolationQuality = .high
        context.draw(source, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
        guard let image = context.makeImage() else { return nil }
        thumbnails.setObject(image, forKey: key)
        return image
    }
}

@MainActor
struct SettingsView: View {
    static let selectedTabKey = "codexMeter.settings.selectedTab"
    let store: UsageStore
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("codexMeter.lowRateThreshold") private var lowRateThreshold = 20
    @AppStorage("codexMeter.deduplicateAlerts") private var deduplicateAlerts = true
    @AppStorage(RefreshPolicy.intervalKey) private var refreshInterval = RefreshPolicy.lowPowerDefault
    @AppStorage(AppAppearance.preferenceKey) private var appearance = AppAppearance.system.rawValue
    @AppStorage(AppIconStyle.preferenceKey) private var iconStyle = AppIconStyle.flat.rawValue
    @AppStorage(MenuBarQuotaDisplay.showPercentageKey) private var showMenuBarPercentage = false
    @AppStorage(SettingsView.selectedTabKey) private var selectedTab = "general"

    private var appearanceMode: AppAppearance {
        AppAppearance(rawValue: appearance) ?? .system
    }

    private var selectedIcon: AppIconStyle {
        AppIconStyle(rawValue: iconStyle) ?? .flat
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            Form {
                Section("本地数据") {
                    LabeledContent("Codex 数据目录") {
                        Text(store.selectedCodexPath.isEmpty ? "尚未授权" : store.selectedCodexPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(store.selectedCodexPath)
                            .textSelection(.enabled)
                            .foregroundStyle(DashboardPalette.secondaryInk)
                    }
                    LabeledContent("数据来源", value: store.dataSourceDescription)
                    Text(store.accountStatus).font(.caption).foregroundStyle(DashboardPalette.secondaryInk)
                    Button("重新选择 Codex 数据目录…", systemImage: "folder") {
                        store.chooseCodexFolder()
                    }
                    Text("Token 按所选目录统计，不区分账户。额度按当前登录隔离；账户变化后等待新采样。不会上传会话正文。")
                        .font(.caption).foregroundStyle(DashboardPalette.secondaryInk)
                }

                Section("刷新") {
                    Picker("自动刷新", selection: $refreshInterval) {
                        Text("每 5 分钟").tag(300.0)
                        Text("每 15 分钟").tag(900.0)
                        Text("每 30 分钟").tag(1_800.0)
                    }
                    Text("前台按所选间隔刷新；界面隐藏或被遮挡时，以 15 分钟起的间隔由系统调度。低电量模式以 30 分钟起的间隔刷新，温度较高时继续降频；打开摘要和手动刷新仍会按需检查，未变化的数据复用缓存。")
                        .font(.caption).foregroundStyle(DashboardPalette.secondaryInk)
                }

                Section("菜单栏") {
                    Toggle("显示额度百分比", isOn: $showMenuBarPercentage)
                    Text("实线弧越长，剩余额度越多；虚线表示上次采样，三点表示暂无有效额度。")
                        .font(.caption).foregroundStyle(DashboardPalette.secondaryInk)
                }

                Section("外观") {
                    Picker("显示模式", selection: $appearance) {
                        ForEach(AppAppearance.allCases) { mode in
                            Label(mode.title, systemImage: mode.icon).tag(mode.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)
                    HStack(spacing: 12) {
                        SettingsLogo(assetName: selectedIcon.assetName(for: colorScheme), size: 44)
                            .accessibilityLabel(selectedIcon.title)
                        Picker("应用 Logo", selection: $iconStyle) {
                            ForEach(AppIconStyle.allCases) { style in
                                Text(style.title).tag(style.rawValue)
                            }
                        }
                    }
                    Text("N 品牌与玻璃样式均随显示模式切换浅色和深色配色。Dock 与应用内 Logo 同步更新，无需重启。")
                        .font(.caption).foregroundStyle(DashboardPalette.secondaryInk)
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("通用", systemImage: "gearshape") }
            .tag("general")

            Form {
                Section("低额度提醒") {
                    Picker("提醒阈值", selection: $lowRateThreshold) {
                        Text("剩余 5% 以下").tag(5)
                        Text("剩余 10% 以下").tag(10)
                        Text("剩余 20% 以下").tag(20)
                        Text("剩余 30% 以下").tag(30)
                        Text("剩余 50% 以下").tag(50)
                    }
                    Toggle("同日提醒去重", isOn: $deduplicateAlerts)
                    Text("同时会在预测到额度可能于重置前耗尽时提示。")
                        .font(.caption).foregroundStyle(DashboardPalette.secondaryInk)
                }
                PermissionSettingsSection()
            }
            .formStyle(.grouped)
            .tabItem { Label("提醒", systemImage: "bell.badge") }
            .tag("notifications")

            APISettingsView()
                .tabItem { Label("API", systemImage: "key") }
                .tag("api")

            VStack(spacing: 10) {
                SettingsLogo(assetName: selectedIcon.assetName(for: colorScheme), size: 64)
                Text("Codex Health").font(.title2.weight(.bold))
                Text("v\(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—") · 本地优先的 Codex 用量健康中心")
                    .foregroundStyle(DashboardPalette.secondaryInk)
                AppUpdateSection()
                    .padding(.top, 12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .tabItem { Label("关于", systemImage: "info.circle") }
            .tag("about")
        }
        .frame(width: 520, height: 440)
        .scenePadding()
        .foregroundStyle(DashboardPalette.ink)
        .tint(DashboardPalette.ink)
        .preferredColorScheme(appearanceMode.colorScheme)
        .onAppear {
            if AppIconStyle(rawValue: iconStyle) == nil { iconStyle = AppIconStyle.flat.rawValue }
        }
        .onChange(of: iconStyle) { _, _ in AppIconStyle.applyDockIcon() }
        .onChange(of: appearance) { _, _ in AppIconStyle.applyDockIcon() }
    }
}
