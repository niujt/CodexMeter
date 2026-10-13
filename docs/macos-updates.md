# macOS 应用内更新发布指南

## 本次代码与当前阻塞

关于页使用 Sparkle 2.10.0 标准更新窗口：检查 → 下载 → 验证签名 → 安装并重启。Sparkle 负责版本比较、下载进度、取消、错误提示与重启，应用不自行挂载 DMG、执行替换脚本或绕过 Gatekeeper。控制器为应用级单例，关闭设置不会销毁正在进行的更新。

依赖同时登记在 Xcode 工程和 Swift Package Manager。演示截图构建显式使用 `CODEX_HEALTH_PREVIEW`，不启动更新器，也不连接更新服务。

当前只有代码接入与发布配置模板；公钥、签名更新源和正式更新包尚未配置或发布。未配置的构建会显示具体原因，并禁用检查按钮。当前仓库的构建脚本使用 Apple Development 或 ad-hoc 签名，不代表已经具备 Developer ID 公证发布流程。没有生成密钥、读取钥匙串、安装应用或发布任何内容。

旧版 1.0.8 不含更新器，需要安装一次包含 Sparkle 的首版；之后才能通过应用内更新升级。不要把对旧版的首次迁移说成也能自动完成。

## 发布前必须准备

1. 在受信任的 macOS 构建环境，经所有者明确批准后，准备一次 Sparkle Ed25519 更新签名密钥。可使用受信任 Mac 的钥匙串，也可在单独确认后经安全渠道配置 GitHub Actions 受保护 Environment 的加密 secret；不要求用户个人 Mac。密钥生成和 secret 持久配置必须单独确认。私钥不得写入仓库、聊天、构建参数或普通日志。应用中只包含公开的 `SUPublicEDKey`。
2. 确认 macOS 发布身份及权限：正式分发推荐 Developer ID 签名、公证，并保留应用与 Widget 的 App Group、嵌套代码签名。不要关闭 library validation、Gatekeeper 或任何系统安全检查来让更新通过。现有开发签名和 ad-hoc 包必须分别实测，不能假定它们是可分发安装包。
3. 专用稳定更新源规划为 `https://raw.githubusercontent.com/niujt/CodexMeter/main/updates/macos/appcast.xml`。这里只是规划位置，不是已验证上线的 URL。应用要求此精确 HTTPS 地址；更换域名或分支需要同步修改配置校验与测试。
4. 将 `Resources/Updates.xcconfig.example` 复制到构建机本地，填入真实的公开签名公钥。通过 `UPDATE_XCCONFIG=/absolute/path/Updates.xcconfig` 传给现有构建脚本。此文件只包含公开配置，不能放入私钥。
5. 设置递增的 `CFBundleVersion`，并同步应用与 Widget 的展示版本/构建号。当前版本号尚未修改。Sparkle 按构建号比较；同一构建号不得对应不同发布内容。

## 构建和配置门禁

在 Mac 上完成配置后，构建命令模板：

```bash
UPDATE_XCCONFIG=/absolute/path/Updates.xcconfig REQUIRE_APP_UPDATES=1 ./script/build_distribution.sh
```

该脚本保留已有签名选择，不擅自改证书。新增门禁验证公钥格式、专用更新源、两项强制签名校验、禁用签名失败过期降级、构建号及嵌入的 Sparkle.framework。此门禁不替代 `codesign`、公证或端到端更新测试。现有构建脚本会清理旧构建产物；运行前仍须遵循 AGENTS.md 的精确目标确认要求。

使用正式分发构建时，按 Sparkle 官方建议通过 Xcode Archive/Export 完成正确的嵌套签名。验证：

```bash
codesign --verify --deep --strict '/path/to/Codex Health.app'
spctl --assess --type execute --verbose '/path/to/Codex Health.app'
python3 script/validate_update_config.py '/path/to/Codex Health.app'
```

## 生成更新源（模板，未执行）

经授权使用可信 macOS 构建机或 GitHub Actions macOS runner，以及官方 Sparkle 2.10.0 工具。归档目录只放已验证的 macOS 包，不混放 Windows 包；初期不启用 delta。现有通用 DMG 可以作为 Sparkle 更新载荷，无需用户手动拖拽。需验证其中确实同时包含 arm64/x86_64，且主应用、Widget、版本与签名均正确。

```bash
/path/to/Sparkle/bin/generate_appcast \
  --maximum-deltas 0 \
  --download-url-prefix 'https://github.com/niujt/CodexMeter/releases/download/vNEXT_VERSION/' \
  /path/to/macos-update-archives
```

`vNEXT_VERSION` 必须替换为本次真实发布标签；生成后核对 enclosure URL。`generate_appcast` 从归档中读取 `SURequireSignedFeed` 并签名 feed、release notes 和更新包；本机可使用已获授权的钥匙串；CI 可从已获授权的加密 secret 经标准输入传给 `--ed-key-file -`，不可将私钥放进命令行参数、文件附件或日志。工具可能移动旧归档，始终使用专用发布工作目录，不使用源码目录。

发布流程：先上传并核对更新包，再发布完整的签名 `appcast.xml` 到上述规划位置；不要发布占位 appcast。签名后不能再手工编辑 feed 或说明，任何编辑都必须重新签名。不可未经确认推送仓库、创建 Release 或上传发布包。本次没有执行这些步骤。

## Mac 验收清单

- 当前源码使用 macOS 26 SDK / Icon Composer，构建需 Xcode 26。Xcode 和 SwiftPM 两条构建路径均解析固定的 Sparkle 2.10.0；检查嵌入框架及 helper/XPC 签名。
- `./script/test_usage.sh`，包括 AppUpdateCheckerTests；测试使用合成数据，不读取真实 Codex 会话。
- 未配置公钥/feed 的构建：明确提示且禁用检查；不得退化成未验证的下载安装。
- 真实旧/新两版：无更新、发现新版、下载、取消后重试、断网后重试、多次点击、关闭设置再打开、安装并重启。
- 下载完成后按钮进入安装/重启阶段；重启后的版本、Widget、用户设置及数据保留正确。
- 篡改包/无签名或错误签名的 feed/说明/包必须被拒绝。
- 稳定源不包含 Windows 或测试/预发布版本；验证 macOS 最低版本、Intel 与 Apple Silicon。
- 从只读 DMG、无写权限目录启动时应给出安全失败或系统授权，绝不绕过安全检查。
- 首次含更新器的版本需单独安装一次，此后才验证自动替换升级。

## 验证记录

云端 Linux 无 Swift、Xcode、macOS SDK 和签名工具。Python 配置测试与静态检查可运行；Swift 测试、应用编译、依赖实际嵌入、UI、签名和安装重启仍需 Mac 实测。

## 官方依据

- [Sparkle 基础配置与签名](https://sparkle-project.org/documentation/)
- [SwiftUI 程序化接入与 API 使用约定](https://sparkle-project.org/documentation/programmatic-setup/)
- [发布更新与 appcast](https://sparkle-project.org/documentation/publishing/)
- [签名校验与默认行为](https://sparkle-project.org/documentation/customization/)
- [Sparkle 2.10.0 官方版本](https://github.com/sparkle-project/Sparkle/releases/tag/2.10.0)

## GitHub Actions 与两类签名

不必把项目搬到个人 Mac；GitHub-hosted macOS runner 可以构建、测试、打包与签名。当前只准备工作流代码，不表示已经运行，也不表示所需证书或 secret 已存在。当前无密钥验证工作流允许默认分支手动触发，以及已获批准的 codex/macos-about-updater 专用分支 push 触发；签名任务放在配置了审批人的 GitHub Environment 中，不向来自 fork/未信任 PR 的代码开放密钥。

- **Sparkle Ed25519 更新签名**：证明 appcast、发布说明和更新包由可信发布者产生。私钥签名，公钥内置应用；与 Apple 开发者证书是两套独立材料。本实现要求签名 feed 和提取前包验证，并将签名失败过期时间设置为 0，绝不因为失败时间过长而降级。
- **Apple Developer ID 代码签名和公证**：让 macOS/Gatekeeper 识别发布身份并验证分发包，正确覆盖应用、Widget、Sparkle helper/XPC。Sparkle 签名不代替这项；Developer ID/公证也不代替更新源的签名。没有 Apple 分发证书时可做编译验证，但不能宣称已获得正式可分发包。

未来 CI 需要的受保护输入：Sparkle 更新签名私钥（secret）与公开公钥（variable），Developer ID Application 证书及其导出密码、团队 ID，以及用于公证的 Apple 身份/API 密钥材料。若 Widget/App Group 需要 provisioning profile，也需准备正确 profile。实际 secret 名称以工作流为准；不要把任何材料发到普通聊天。添加凭据、权限或发布均需独立确认。

建议上线次序：先运行无凭据的 macOS 构建/测试；在审批环境安全配置所需凭据；验证 Archive/Export、Developer ID 签名与公证；生成已签名的更新包和 feed；经批准发布；最后实测安装旧版→下载→安装并重启。检查更新源和用户数据保留后才能宣布功能已上线。
