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
