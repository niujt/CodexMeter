# Codex Health

一个从本机 Codex 会话记录中查看 Token 用量与 7 天额度的桌面工具：macOS 提供原生菜单栏应用和桌面小组件，Windows 提供 Dashboard 与额度悬浮球。

界面采用「外围 Liquid Glass + 内部极简 Flat Content」：侧栏和工具栏使用系统材质，数据、图表和列表保持黑白灰扁平布局。支持浅色、深色和跟随系统外观；macOS 26 及以上使用 Liquid Glass，较早版本使用系统材质。

在「设置 → 通用 → 外观 → 应用 Logo」中可选择黑白扁平版或玻璃黑白版。黑白扁平版作为默认，切换 Dock、应用内 Logo 和菜单栏标识无需重启；Finder 中的安装包图标使用黑白扁平版。

> 数据只在本机读取与计算，不上传会话内容或用量数据。

## 下载

| 平台 | 安装包 |
| --- | --- |
| macOS 15+（Intel / Apple Silicon） | [1.0.8 DMG](https://github.com/niujt/CodexMeter/releases/tag/v1.0.8)，打开后将 `Codex Health.app` 拖入 Applications |
| Windows x64 | [0.1.1 安装包](https://github.com/niujt/CodexMeter/releases/download/windows-v0.1.1/Codex-Health-0.1.1-windows-x64-setup.exe) |
| Windows ARM64 | [0.1.1 安装包](https://github.com/niujt/CodexMeter/releases/download/windows-v0.1.1/Codex-Health-0.1.1-windows-arm64-setup.exe) |

[Windows 发布说明与校验文件](https://github.com/niujt/CodexMeter/releases/tag/windows-v0.1.1)。Windows 包未签名，原生拖动、置顶和不同 DPI 效果仍待目标机器实测。

当前发布包使用本机开发签名以确保 WidgetKit 扩展能被 macOS 识别；macOS 首次打开时可能提示无法验证开发者。请前往“系统设置 → 隐私与安全性”，在页面底部找到 Codex Health 的提示后选择“仍要打开”。

以下 macOS 截图由当前 SwiftUI 页面和虚构演示数据生成，不包含真实项目、会话、账户记录或 Token 用量。

## 健康报告

![Codex Health 黑白灰健康报告：浅色模式（演示数据）](docs/screenshots/dashboard.png)

<details>
<summary>查看深色模式</summary>

![Codex Health 黑白灰健康报告：深色模式（演示数据）](docs/screenshots/dashboard-dark.png)

</details>

<details>
<summary>应用 Logo 切换</summary>

仅保留黑白扁平版与玻璃黑白版，默认使用黑白扁平版。

| 黑白扁平版（默认） | 玻璃黑白版 |
| --- | --- |
| <img src="Resources/Assets.xcassets/FlatAppIcon.imageset/FlatAppIcon.png" width="128" alt="黑白扁平 Logo"> | <img src="Resources/Assets.xcassets/GlassAppIcon.imageset/GlassAppIcon.png" width="128" alt="玻璃黑白 Logo"> |

</details>

## 菜单栏摘要

菜单栏会显示当前 7 天额度剩余比例；点击后可快速查看额度、重置时间、平均回复速度、今日用量和权限提醒，并打开完整详情。

![Codex Health 菜单栏弹窗（匿名演示数据）](docs/screenshots/menu-popover.png)

## 桌面小组件

在 macOS 桌面编辑模式中添加“Codex Health”小组件。小号展示额度概览，中号同时展示三段 Token 用量、7 天额度与当前上下文。

![Codex Health 桌面小组件（匿名演示数据）](docs/screenshots/desktop-widget.png)

如果之前安装过旧版临时签名包，请先退出并移除 `/Applications/Codex Health.app`，再安装最新版并启动一次，然后重新打开桌面小组件编辑器搜索“Codex Health”。

## 使用趋势

![Codex Health 使用趋势（匿名演示数据）](docs/screenshots/usage-trends.png)

## 模型与效率

![Codex Health 模型与效率（匿名演示数据）](docs/screenshots/model-efficiency.png)

## 项目与用量

![Codex Health 项目与用量（已脱敏）](docs/screenshots/projects-usage.png)

## 预测与风险

![Codex Health 预测与风险（匿名演示数据）](docs/screenshots/forecast-risk.png)

## 历史记录

![Codex Health 历史记录（已脱敏）](docs/screenshots/history.png)

## Windows 界面与悬浮球

Windows 版沿用黑白灰 Dashboard，提供 x64 和 ARM64 安装包。

以下 Windows 截图来自前端界面与虚构演示数据，悬浮球截图为原尺寸；截图不代表 Windows 原生安装、置顶或 DPI 实测结果。

![Windows 健康报告：浅色模式（演示数据）](docs/screenshots/windows-dashboard.png)

<details>
<summary>查看 Windows 深色模式</summary>

![Windows 健康报告：深色模式（演示数据）](docs/screenshots/windows-dashboard-dark.png)

</details>

### 悬浮球

悬浮球显示七天剩余额度，可拖动并记住位置，双击打开 Dashboard；外观跟随主界面的浅色、深色或系统主题。没有有效额度或额度已到期时显示「—」。

| 浅色悬浮球 | 深色悬浮球 |
| --- | --- |
| <img src="docs/screenshots/windows-floating-light.png" width="88" alt="Windows 浅色悬浮球，剩余额度 58%（演示数据）"> | <img src="docs/screenshots/windows-floating-dark.png" width="88" alt="Windows 深色悬浮球，剩余额度 58%（演示数据）"> |

### 周用量小票

在 Dashboard 点击「导出小票」，预览后保存纯白背景 PNG，适合分享近七天的本机 Token 用量。

<img src="docs/screenshots/windows-receipt-full.png" width="320" alt="纯白周用量小票（演示数据）">

## 功能

- 菜单栏以白色图标和文字显示 7 天额度剩余百分比
- 今日、近 7 天、本月 Token 用量，以及输入、输出、缓存和推理 Token 分类
- 当前会话上下文进度与 7 天额度重置倒计时
- 用量预测：按近 1 / 6 / 24 小时额度变化加权估算
- 项目排名支持今日、7 天、30 天切换
- 模型占比、有效轮次样本数与端到端平均轮次耗时
- 菜单栏摘要与健康报告显示近 15 分钟平均回复速度（tokens/s）和有效轮次数
- 按日 / 按小时趋势，可按模型或项目筛选
- 低额度、预计提前耗尽、即将重置提醒；阈值和同日去重均可配置
- Codex `PermissionRequest` 权限提醒：系统通知、提示音、菜单栏需要关注数量与最近请求列表
- WidgetKit 桌面小组件：小号展示额度概览，中号展示三段用量、额度与上下文

## 使用

1. 打开 `dist/Codex Health.app`。
2. 第一次启动时，选择你的 Codex 数据目录（通常为 `~/.codex`）。
3. 点击菜单栏图标查看摘要；选择“打开详情”查看完整分析。
4. 在桌面编辑模式中添加“Codex Health”小组件。

### 权限提醒

1. 打开 Codex Health 设置中的“提醒”页，开启“Codex 权限提醒”。
2. 应用会把自己的 handler 增量合并到 `~/.codex/hooks.json`，并备份原文件；不会覆盖或删除已有 Hook。
3. 在 Codex 中运行 `/hooks`，检查并信任新安装的 `PermissionRequest` Hook。
4. 可在设置页发送测试提醒、重新检测或修复配置，也可以只卸载 Codex Health 自己的 Hook。

权限 Hook 只观察并上报事件，不会自动允许或拒绝请求。通知默认只显示项目名和工具类型；操作摘要需要手动开启，且会先过滤 token、密码、Authorization、Cookie 等敏感信息。由于 `PermissionRequest` 也可能由 Auto Review 继续处理，界面显示“最近权限请求 / 需要关注”，不把它描述为可靠的“当前待审批”。

应用会将已授权的数据目录保存为 macOS 安全书签，因此重新启动后仍可访问。

## 构建

环境要求：macOS 15+、Xcode 16+。发布脚本会自动使用本机 Apple Development 证书为应用和 WidgetKit 扩展签名；没有开发证书时才回退到临时签名（此模式下小组件可能不会出现在 macOS 选择器中）。

```bash
git clone https://github.com/niujt/CodexMeter.git
cd CodexMeter
./script/build_distribution.sh
```

如需强制使用临时签名进行本地测试，可执行 `SIGNING_MODE=adhoc ./script/build_distribution.sh`。

开发调试时可以执行：

```bash
./script/build_and_run.sh
```

更新 README 截图时可以执行：

```bash
python3 script/preview_screenshots.py
```

脚本打开独立演示应用，使用真实页面组件和内存中的演示数据，不读取 Codex 会话、登录凭据或真实重置历史。通过侧栏切换页面，通过“演示预览”菜单切换明暗模式、菜单栏摘要和小组件，再截取窗口。临时构建保留在系统临时目录，便于检查。

## 数据与限制

- 用量来自本机 `.codex/sessions` 和 `.codex/archived_sessions` 下的会话 JSONL 记录，不遍历插件缓存、技能目录或根目录的输入历史；也可直接选择会话目录。不同版本的 Codex 记录格式变化可能影响统计。
- 今日、近 7 天、本月及趋势按累计 Token 计数的增量和发生时间归属；计数下降时作为新计数段处理。历史列表按小时、模型和工作目录汇总。
- 菜单栏、详情窗口和设置共享同一份用量数据。打开详情会优先显示已有结果，仅在数据达到刷新间隔时检查更新；手动刷新立即检查变化文件。
- 首次读取及文件变化时流式解析该文件，未变化文件复用统计摘要。摘要保存在应用的本机缓存目录，重启后按文件路径、修改时间和大小校验后复用；缓存不包含对话正文，损坏或日历/时区变化时自动重建。缓存目录被系统清理后，下次启动会重新读取。
- 进度中的“检查文件”包含复用缓存的文件，“实际读取”仅统计本轮尝试解析的文件，两者分别显示。
- 前台自动刷新遵循设置的间隔；后台使用 macOS 系统调度，基准间隔不低于 15 分钟，允许系统合并或调整执行时机。低电量模式的基准间隔不低于 30 分钟，热压力严重时不低于 60 分钟；休眠时暂停调度。后台额度提醒也会随自动刷新降频，打开摘要及手动刷新可按需立即检查。
- 权限提醒仅在有事件需要过期或清理时安排一次处理；空历史不维持轮询计时器，内容不变不写文件。关闭菜单弹窗后停止速度重绘，显示时仅安排样本过期更新并按分钟合并；菜单栏文字和额度缓存未变化时也不重复绘制或写入。
- “平均耗时”只使用可配对的用户消息与明确的最终回答或任务完成事件；缺少完成标记的记录不计入有效轮次，不是服务端 API 延迟。
- “近 15 分钟平均回复速度”按窗口内完成的有效轮次计算：输出 Token 总数 ÷ 对应轮次耗时总和。优先使用任务开始事件，否则使用用户消息作为起点；终点为最终回答或任务完成事件。耗时包含思考、工具执行与等待，轮次之间的空闲时间不计入，因此这是端到端平均回复速度。输入 Token 不计入，推理 Token 不重复叠加到输出计数；未完成、已中止、缺少可靠输出增量或耗时异常的轮次不计入。无有效样本时显示“暂无样本”；样本按实际完成时间滚动过期，未变化文件的缓存也会重新筛选。
- 小组件显示最近成功读取的摘要；超过 30 分钟未更新会提示数据可能过期，额度达到重置时间后等待新周期采样。
- 额度预测依赖本机积累的额度历史，样本较少时会回退到当前周期平均速度。
- 这是一个非官方的本地辅助工具，与 OpenAI/Codex 没有隶属关系。

## 隐私

Codex Health 不会上传 `.codex` 目录、会话内容或统计数据。小组件通过 App Group 读取应用写入的本地摘要缓存。
