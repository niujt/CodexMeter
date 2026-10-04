# Logo 资源

目前提供两种样式：黑白扁平版（默认）和玻璃黑白版。

- `Resources/Assets.xcassets/FlatAppIcon.imageset/FlatAppIcon.png`：黑底白色 C/H，右上一个独立圆弧。
- `Resources/Assets.xcassets/GlassAppIcon.imageset/GlassAppIcon.png`：玻璃外壳、扁平黑色 C/H，右上三段圆弧。
- `Resources/CodexHealth.icon/Assets/FlatLogo.png`：默认安装图标的 Icon Composer 图层，使用扁平版同一资源。

两版均由内置 image_gen 生成，保留透明背景。扁平版从最初黑白方案中提取，提示为：提取方案底部黑色圆角应用图标，保留白色 C/H 和一个独立圆弧；背景透明，无文字、渐变、阴影或玻璃效果。玻璃版从确认的玻璃方案中提取，提示为：保留通透圆角玻璃外壳和扁平黑色 C/H，右上三段圆弧；背景透明，无文字和其他图标。

旧的 `original` 图标偏好自动迁移到 `flat`；已选择 `glass` 的偏好继续保留。切换同步 Dock、应用内 Logo 和菜单栏标识；Finder 的安装图标使用扁平版。

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
