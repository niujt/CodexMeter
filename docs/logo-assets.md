# Logo 资源

默认使用 N 品牌图标，也可在设置中选择原有的玻璃黑白样式。两种样式均有浅色和深色配色。

- `Resources/Assets.xcassets/FlatAppIconLight.imageset/FlatAppIconLight.png` 和 `Resources/Assets.xcassets/FlatAppIcon.imageset/FlatAppIcon.png` 是 N 品牌的浅色和深色资源，分别使用近白底和近黑底。
- `Resources/Assets.xcassets/GlassAppIcon.imageset/GlassAppIcon.png` 和 `Resources/Assets.xcassets/GlassAppIconDark.imageset/GlassAppIconDark.png` 是玻璃样式的浅色和深色资源。
- `Resources/CodexHealth.icon/Assets/FlatLogoLight.png` 和 `Resources/CodexHealth.icon/Assets/FlatLogo.png` 是默认安装图标的浅色和深色 Icon Composer 图层。

N 品牌图标由内置 ImageGen 生成。中央以无边框的终端符号为主体，鲸尾笔画向右上倾斜并指向约 80% 的额度分界，环底有三个信号点，右下角为 N 角标。

旧的 `original` 图标偏好迁移到默认样式 `flat`；已选择 `glass` 的偏好继续保留。Dock 和应用内 Logo 随应用显示模式切换。Finder 安装图标的外观由系统管理，见 [Apple Icon Composer 文档](https://developer.apple.com/documentation/xcode/creating-your-app-icon-using-icon-composer)。

## 2026-10-11 更新与验证

- 为扁平和玻璃样式补齐浅深色配色，修复仅切换显示模式时 Dock 图标不更新的问题。
- 当前工作区 Debug 构建通过；隔离图标工具的 44 项检查通过，覆盖编译后资源加载、黑白对比度、固定模式和系统模式、同一样式连续切换及旧偏好迁移。
- 已替换安装 `/Applications/Codex Health.app`，应用和小组件签名验证通过，运行进程及已安装图标资源与构建结果一致；本次两个构建目录已按确认范围清理。
- 原生界面截图工具超时，未完成安装后截图验证；版本号保持 1.0.8 (16)。

## 2026-10-13 外观与能耗优化

- 菜单栏 C/H、百分比和提醒数量统一使用系统模板着色：浅色背景下黑字，深色背景下白字，外观变化无需重绘整张标识。
- 经确认改用精确脚本清理图标：四版统一为 1024 × 1024，扁平浅深色共用原版 C/H 蒙版和圆角边界，玻璃版保留原有字形与反光，仅裁去透明边缘杂点；安装图层同步更新。
- 隐藏摘要不再触发读取；打开摘要通过刷新节流检查，窗口被遮挡时使用后台调度。保留手动刷新及原有后台、低电量和温度降频策略。
- 首轮加载保留渐进快照；已有完整结果时只更新进度计数，文件活动通知合并发送，最终汇总仅生成一次。小组件刷新年龄与额度到期判断保持原有语义。
- 84 项合成测试通过。160 文件场景实测 3 次活动回调、1 次完整汇总；未变化的后续刷新读取 0 字节、重建 0 次汇总。独立原生状态栏控件的浅深色模板渲染通过，尚未量测实际电池续航改善。
- 当前工作区 Debug 构建及应用/小组件签名验证通过；版本号仍为 1.0.8 (16)。本轮安装替换与构建清理需要另行确认。

## 已移除的旧资源

以下目标均相对于项目根目录，已在获得二次确认后移除，不包含应用数据或配置。

- `Resources/Assets.xcassets/AppIcon.appiconset/`（旧版备用安装图标）
- `Resources/Assets.xcassets/LightAppIcon.imageset/`（旧版浅色 Logo）
- `Resources/Assets.xcassets/DarkAppIcon.imageset/`（旧版深色 Logo）
- `Resources/Assets.xcassets/CodexHealthMark.imageset/`（旧版应用内 Logo）
- `Resources/Assets.xcassets/CodexUsageTemplate.imageset/`（已无代码引用的旧菜单栏模板）
- `Resources/CodexHealth.icon/Assets/icon_512x512@2x.png`（旧版 Icon Composer 图层）
- `Resources/CodexHealth.icon/Assets/DarkAppIcon.png`（旧版深色 Icon Composer 图层）
- `docs/screenshots/logo-settings.png`（展示旧版默认选项的过期截图）
