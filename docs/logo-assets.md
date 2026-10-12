# Logo 资源

目前提供两种样式：黑白扁平版（默认）和玻璃黑白版。每种样式均有浅色和深色配色，随显示模式切换：浅色白底黑字，深色黑底白字。

- `Resources/Assets.xcassets/FlatAppIcon.imageset/FlatAppIcon.png`：黑底白色 C/H，右上一个独立圆弧。
- `Resources/Assets.xcassets/FlatAppIconLight.imageset/FlatAppIconLight.png`：对应浅色扁平版，白底黑色 C/H，右上一个独立圆弧。
- `Resources/Assets.xcassets/GlassAppIcon.imageset/GlassAppIcon.png`：玻璃外壳、扁平黑色 C/H，右上三段圆弧。
- `Resources/Assets.xcassets/GlassAppIconDark.imageset/GlassAppIconDark.png`：对应深色玻璃版，黑色玻璃外壳、白色 C/H，右上三段圆弧。
- `Resources/CodexHealth.icon/Assets/FlatLogo.png`：默认安装图标的 Icon Composer 图层，使用扁平版同一资源。
- `Resources/CodexHealth.icon/Assets/FlatLogoLight.png`：安装图标的浅色图层，与深色图层按系统图标外观切换。

两版均由内置 image_gen 生成，保留透明背景。扁平版从最初黑白方案中提取，提示为：提取方案底部黑色圆角应用图标，保留白色 C/H 和一个独立圆弧；背景透明，无文字、渐变、阴影或玻璃效果。玻璃版从确认的玻璃方案中提取，提示为：保留通透圆角玻璃外壳和扁平黑色 C/H，右上三段圆弧；背景透明，无文字和其他图标。

浅色扁平与深色玻璃变体由内置 image_gen 基于原图编辑生成，保留 C/H 轮廓、圆弧数量、留白和透明外边缘，仅调整对应配色。提示分别为白色圆角底板加黑色 C/H、黑色玻璃底板加白色 C/H，禁止新增文字或改变图形结构。

旧的 `original` 图标偏好自动迁移到 `flat`；已选择 `glass` 的偏好继续保留。切换样式同步 Dock、应用内 Logo 和菜单栏标识；切换显示模式同步 Dock 与应用内 Logo 的浅深色配色。跟随系统时监听应用的系统外观变化，固定白天/暗黑模式时使用所选配色。Finder 的安装图标使用扁平版的浅深色图层，外观由系统管理，见 [Apple Icon Composer 文档](https://developer.apple.com/documentation/xcode/creating-your-app-icon-using-icon-composer)。

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
