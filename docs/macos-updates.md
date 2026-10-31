# macOS 应用内更新发布指南

## 1.0.24（34）DeepSeek 余额

- 新增独立的 DeepSeek 余额页面，使用官方 `GET https://api.deepseek.com/user/balance`，展示总可用余额、充值余额、未过期赠金和 API 余额可用状态；人民币和美元分别展示，不合并换算，金额按十进制解析。
- 设置的 API 页支持选择 OpenAI 或 DeepSeek，分别输入或导入对应密钥。DeepSeek 使用独立的钥匙串 service/account；OpenAI 原有存储标识保持一致。只有用户点击保存或导入时才写入钥匙串。
- 查询禁用磁盘缓存、Cookie 和跳转，不调用模型。页面按需查询，5 分钟内复用内存结果；失败保留带时间的上次成功结果并标明旧状态，换密钥会清空旧账户数据并拒绝过期请求回写。
- 193 项 Swift 回归（含 12 项 DeepSeek 测试）、7 项更新配置、4 项 Widget 版本和 2 项工作流检查通过。生成 13 张 DeepSeek 隔离快照，目视检查单币种浅色、双币种浅色、失败后旧数据深色、设置深色和服务商选择器浅色；均使用虚构数据与凭据。
- 本地 Release 双架构构建、应用/Widget/Sparkle 嵌套签名、App Group、更新配置、DMG 完整性及 Applications 快捷方式验证通过。沿用 Apple Development 签名，未做 Developer ID 公证。
- 未读取或复用用户的 OpenAI 密钥，未提供真实 DeepSeek 密钥，未进行真实 DeepSeek 账户查询或钥匙串写入。升级后的实际启动、独立密钥保存/导入、余额查询与 Widget 保留仍待用户验收。
- GitHub 签名与公开下载复核将在发布后补充。未直接替换或重启已安装的主应用与 Widget，未清理本地构建或历史安装包。

## 1.0.23（33）API 用量与费用

- 新增独立的 OpenAI 官方组织费用、文本 API Token/请求数和月度消费上限页面，以及设置中的密钥输入/文件导入。用户点击保存或导入时才写入此 Mac 的钥匙串；安装包和统计缓存不含密钥，API 查询结果只保存在内存中。
- API 查询仅使用三个官方 GET 接口，禁用磁盘缓存、Cookie 和跳转。进入页面按需查询，5 分钟内复用内存结果；完整读取分页，分页失败不显示不完整汇总。UTC 日桶查询包含当天费用；替换密钥取消旧请求并清空旧组织结果。
- 未配置消费上限、权限不足、其他 HTTP 403、网络失败分别处理。预算剩余仅作估算，不能替代充值余额或 ChatGPT 套餐额度。
- 181 项 Swift 回归（含 13 项 API 测试）、7 项更新配置、4 项 Widget 版本与 2 项签名工作流测试通过。API 页与设置生成 9 张虚构数据隔离快照，目视检查浅色成功、深色预算、深色失败、未配置密钥和设置共 5 张；不代表真实安装后的 UI 操作验收。
- 用户授权的真实密钥已通过新客户端 URLSession 只读验证：费用与文本用量接口成功，消费上限返回未配置状态；未将密钥写入钥匙串或安装包。真实钥匙串保存与文件导入操作仍待更新后验收。
- 本地 Release 双架构构建、应用/Widget/Sparkle 嵌套签名、App Group、更新配置、DMG 完整性及 Applications 快捷方式验证通过。沿用 Apple Development 签名，未做 Developer ID 公证。
- 源码提交 `4f097d0725764ce2cd3aacb5328d24c963559bac`，标签 [macos-v1.0.23](https://github.com/niujt/CodexMeter/releases/tag/macos-v1.0.23)。[签名 CI](https://github.com/niujt/CodexMeter/actions/runs/41172757492) 成功；本机独立验证公开下载包的 SHA-256、长度与 Ed25519 签名、已签名更新源以及篡改包/篡改源拒绝，公钥保持一致。更新源保留 1.0.23 和 1.0.22；未删除 GitHub 历史安装包。
- DMG SHA-256：`7e1dae7c45a5452120009e02988503ecaab04be8cce6a273781ada16af01cdb4`。
- 未直接替换或重启已安装的主应用与 Widget，未清理本地产物；用户点击更新后的安装、实际启动、钥匙串保存、文件导入与功能验收待完成。

## 1.0.18（27）发布与验收边界

- 本次修复历史自然日统计范围、目录切换后的失效筛选、模型有效轮次、中止与零耗时判定，以及新通知在拒绝授权或提交失败时的重试。提醒保留既有去重标记；旧版已经误记的同日标记仍按原有日期/周期边界失效，不强制重发既有提醒。
- 首页新增读取问题及目录选择/重试入口；小组件明确提示统计不完整；常规时间线刷新与启动时旧扩展恢复分开。
- 147 项 Swift 测试、7 项更新配置测试、2 项工作流测试通过。隔离渲染生成 8 张恢复入口首屏和 44 张小组件快照，分别目视检查 3 张首屏与本次受影响的 12 种小组件组合；不代表真实桌面宿主验证。
- 本地 Release 构建通过，主应用与 Widget 均为 1.0.18（27），包含 arm64 / x86_64。嵌套签名、App Group、更新配置、DMG 完整性和指向 `/Applications` 的快捷方式均通过验证。
- DMG SHA-256：`af14d2d2808b6f731382db39cb60710bd65666d3ca97d757919dced522a4915a`。
- GitHub 包签名、签名更新源发布和公开下载复核结果在完成后补充。使用现有 Apple Development 签名，未做 Developer ID 公证；未直接替换或重启本机已安装应用与 Widget，未读取真实 Codex 会话，未清理本地产物。
- 用户在已安装应用中点击更新后的安装、重启、设置保留与真实桌面 Widget 显示仍待验收。

## 更新功能与发布状态

关于页使用 Sparkle 2.10.0 标准更新窗口：检查 → 下载 → 验证签名 → 安装并重启。Sparkle 负责版本比较、下载进度、取消、错误提示与重启，应用不自行挂载 DMG、执行替换脚本或绕过 Gatekeeper。控制器为应用级单例，关闭设置不会销毁正在进行的更新。

依赖同时登记在 Xcode 工程和 Swift Package Manager。演示截图构建显式使用 `CODEX_HEALTH_PREVIEW`，不启动更新器，也不连接更新服务。

源码包含更新器和公开配置。构建需要实际传入更新源和公开公钥，不能只依据未填写的模板判断本机或 GitHub Actions 是否已配置签名密钥。只有构建后的配置确实缺失时，才显示原因并禁用检查按钮。已有 `SPARKLE_PRIVATE_KEY` 应在受信任 CI 中复用，公开公钥注入应用，私钥不得下载到本地或输出到日志。当前构建脚本使用 Apple Development 或 ad-hoc 签名，不代表已经具备 Developer ID 公证发布流程。

本次已通过独立手动流程 `macos-public-update-config.yml` 复用现有 Secret，生成 `Resources/Updates.xcconfig` 与 `updates/macos/appcast.xml`，并由 Sparkle 2.10.0 官方工具验证签名和拒绝篡改。该流程只在当前仓库默认分支手动运行，源码和工具准备步骤不接收 Secret；私钥仅经标准输入交给受信任工具，不写入文件或产物。手动发布时可以复用同一流程签署已在本机验证的 DMG：先把已在本机验证的包发布为与源码提交绑定的预发布 Release，并传入 SHA-256；只读 CI 令牌无法读取草稿，因此必须先公开测试包。CI 核对标签、摘要、签名、更新配置、版本及双架构后，才接收 Secret。输出包含包签名、签名 appcast 和公开验证记录；不自动发布 Release 或推送更新源。

早期 1.0.8（16）不含更新器，需先手动安装含 Sparkle 的版本。已集成更新源的 1.0.8（17）可以检查并升级至本次 1.0.9（18）；不能只凭展示版本判断是否支持更新。

## 发布前必须准备

1. 复用现有 GitHub Actions `SPARKLE_PRIVATE_KEY` 与已安装应用中的公开公钥，不重新生成密钥。私钥仅在受信任的默认分支手动作业内经标准输入使用，不写入仓库、聊天、构建参数或普通日志。签署包前验证派生公钥与仓库公开配置一致，拒绝隐式更换信任身份。
2. 确认 macOS 发布身份及权限：正式分发推荐 Developer ID 签名、公证，并保留应用与 Widget 的 App Group、嵌套代码签名。不要关闭 library validation、Gatekeeper 或任何系统安全检查来让更新通过。现有开发签名和 ad-hoc 包必须分别实测，不能假定它们是可分发安装包。
3. 专用稳定更新源为 `https://raw.githubusercontent.com/niujt/CodexMeter/main/updates/macos/appcast.xml`。签名后的更新源随源码推送，未来只能加入已验证的 Mac 更新包；更换域名或分支需要同步修改配置校验与测试。
4. Xcode 工程与构建脚本默认读取 `Resources/Updates.xcconfig` 中的真实公钥。如需其他公开配置，可通过 `UPDATE_XCCONFIG=/absolute/path/Updates.xcconfig` 显式覆盖。此文件只包含公开配置，不能放入私钥；只有确实需要新密钥时才使用模板，不能覆盖现有签名身份。
5. 设置递增的 `CFBundleVersion`，并同步应用与 Widget 的展示版本/构建号。当前更新验证包为 1.0.9（18），用于从已集成更新器的 1.0.8（17）测试升级。该包采用同一团队的 Apple Development 签名，尚未公证，不能把它称为 Developer ID 公证发布。Sparkle 按构建号比较；同一构建号不得对应不同发布内容。

## 构建和配置门禁

在 Mac 上完成配置后，构建命令模板：

```bash
UPDATE_XCCONFIG=/absolute/path/Updates.xcconfig REQUIRE_APP_UPDATES=1 ./script/build_distribution.sh
```

该脚本保留已有签名选择，不擅自改证书。新增门禁验证公钥格式、专用更新源、两项强制签名校验、禁用签名失败过期降级、构建号及嵌入的 Sparkle.framework。此门禁不替代 `codesign`、公证或端到端更新测试。构建使用新的输出目录，拒绝覆盖已有应用和发布文件，不自动删除产物；下载的依赖保留在 `output/macos/source-packages`，可用 `SOURCE_PACKAGES_DIR` 调整。安装替换和清理仍须遵循 AGENTS.md 的精确目标确认要求。

使用正式分发构建时，按 Sparkle 官方建议通过 Xcode Archive/Export 完成正确的嵌套签名。验证：

```bash
codesign --verify --deep --strict '/path/to/Codex Health.app'
spctl --assess --type execute --verbose '/path/to/Codex Health.app'
python3 script/validate_update_config.py '/path/to/Codex Health.app'
```

## 生成更新源

经授权使用可信 macOS 构建机或 GitHub Actions macOS runner，以及官方 Sparkle 2.10.0 工具。归档目录只放已验证的 macOS 包，不混放 Windows 包；初期不启用 delta。现有通用 DMG 可以作为 Sparkle 更新载荷，无需用户手动拖拽。需验证其中确实同时包含 arm64/x86_64，且主应用、Widget、版本与签名均正确。

```bash
/path/to/Sparkle/bin/generate_appcast \
  --maximum-deltas 0 \
  --download-url-prefix 'https://github.com/niujt/CodexMeter/releases/download/vNEXT_VERSION/' \
  /path/to/macos-update-archives
```

`vNEXT_VERSION` 必须替换为本次真实发布标签；生成后核对 enclosure URL。`generate_appcast` 从归档中读取 `SURequireSignedFeed` 并签名 feed、release notes 和更新包；本机可使用已获授权的钥匙串；CI 可从已获授权的加密 secret 经标准输入传给 `--ed-key-file -`，不可将私钥放进命令行参数、文件附件或日志。工具可能移动旧归档，始终使用专用发布工作目录，不使用源码目录。

发布流程：先上传并核对更新包，再发布完整的签名 `appcast.xml`。签名后不能再手工编辑 feed 或说明，任何编辑都必须重新签名。本次用户已授权推送代码、上传 GitHub 包并发布签名更新源，以便亲自测试应用内升级；保留当前已安装版本作为升级起点，不进行本机手动替换。

macOS 安装版本保留最近两个版本。导出脚本在临时输出中按构建号保留最新两个更新条目，再完成签名与篡改拒绝检查；签名文件验证通过后才替换公开更新源。历史 GitHub Release 和本地安装包的删除仍需列出精确目标并获得二次确认，不自动删除源码、Git 标签或构建缓存。

## Mac 验收清单

- 当前源码使用 macOS 26 SDK / Icon Composer，构建需 Xcode 26。Xcode 和 SwiftPM 两条构建路径均解析固定的 Sparkle 2.10.0；检查嵌入框架及 helper/XPC 签名。
- `./script/test_usage.sh`，包括 AppUpdateCheckerTests；测试使用合成数据，不读取真实 Codex 会话。
- 未配置公钥/feed 的构建：明确提示且禁用检查；不得退化成未验证的下载安装。
- 真实旧/新两版：无更新、发现新版、下载、取消后重试、断网后重试、多次点击、关闭设置再打开、安装并重启。
- 下载完成后按钮进入安装/重启阶段；重启后的版本、Widget、用户设置及数据保留正确。
- 篡改包/无签名或错误签名的 feed/说明/包必须被拒绝。
- 源不包含 Windows 包；本次经用户明确授权发布 Mac 更新验证包，并在说明中标注开发签名、未公证的限制。正式稳定发布需满足 Developer ID 与公证要求。验证 macOS 最低版本、Intel 与 Apple Silicon。
- 从只读 DMG、无写权限目录启动时应给出安全失败或系统授权，绝不绕过安全检查。
- 首次含更新器的版本需单独安装一次，此后才验证自动替换升级。

## 小组件随主应用更新

- 发布包中的主应用与 `CodexMeterWidget.appex` 必须具有相同的展示版本和构建号；`validate_distribution.sh` 会对应用和只读挂载后的 DMG 分别验证，版本不一致即停止发布。DMG 同时保留 `Codex Health.app` 和 `/Applications` 快捷方式。
- Sparkle 更新整个应用包后，macOS 仍可能保留此前的小组件进程。1.0.12 起在启动和发布新快照时，读取本安装路径下扩展的代码签名摘要，与同用户运行中的扩展比较；只有安装路径、签名标识和团队一致而代码摘要不同，才结束旧扩展并请求新时间线。同代码摘要的当前扩展、其他安装和其他用户均不处理。
- 旧可执行文件被更新器替换后，`proc_pidpath` 可能返回 `ENOENT`。此时从内核 `KERN_PROCARGS2` 读取原始可执行路径，不使用可伪造的 `argv[0]`；运行签名也从内核读取，避免误读已替换的新文件。结束进程前重新核对身份和启动时间，防止 PID 复用。
- 旧应用被移动到备份目录时，`proc_pidpath` 会返回备份中的现存路径。恢复逻辑也检查内核记录的原始启动路径，并归一化 `/var` 等符号链接别名；只有原安装位置匹配、用户和签名身份一致且代码摘要过期时才回收。从其他位置独立启动的同签名组件不会被回收。
- Dashboard 的刷新按钮、刷新菜单和全量重读均标记为用户操作，成功写入共享快照后会强制请求小组件重载。检查文件不会伪造新的额度采样时间。
- 版本号、包签名、共享快照和时间线请求通过，不能代替桌面实际展示验收。真实升级后还需确认运行扩展的签名对应新包、小组件显示最新快照、用户设置和数据保留正确。WidgetKit 的展示调度仍由系统管理。

## 早期 Linux 验证记录

云端 Linux 无 Swift、Xcode、macOS SDK 和签名工具。Python 配置测试与静态检查可运行；Swift 测试、应用编译、依赖实际嵌入、UI、签名和安装重启仍需 Mac 实测。

## 官方依据

- [Sparkle 基础配置与签名](https://sparkle-project.org/documentation/)
- [SwiftUI 程序化接入与 API 使用约定](https://sparkle-project.org/documentation/programmatic-setup/)
- [发布更新与 appcast](https://sparkle-project.org/documentation/publishing/)
- [签名校验与默认行为](https://sparkle-project.org/documentation/customization/)
- [Sparkle 2.10.0 官方版本](https://github.com/sparkle-project/Sparkle/releases/tag/2.10.0)

## GitHub Actions 与两类签名

GitHub-hosted macOS runner 可以构建、测试、打包与签名。现有无密钥验证工作流仍只验证故意未配置的通用包；独立的 `macos-public-update-config.yml` 已在默认分支手动执行，复用已有 Secret 生成公开公钥和签名更新源，也可签署已审核的预发布 Release 中的包，由本地独立核对后发布签名更新源。未来正式分发签名任务应使用配置了审批人的 GitHub Environment，不向 fork 或未信任 PR 开放密钥。

- **Sparkle Ed25519 更新签名**：证明 appcast、发布说明和更新包由可信发布者产生。私钥签名，公钥内置应用；与 Apple 开发者证书是两套独立材料。本实现要求签名 feed 和提取前包验证，并将签名失败过期时间设置为 0，绝不因为失败时间过长而降级。
- **Apple Developer ID 代码签名和公证**：让 macOS/Gatekeeper 识别发布身份并验证分发包，正确覆盖应用、Widget、Sparkle helper/XPC。Sparkle 签名不代替这项；Developer ID/公证也不代替更新源的签名。没有 Apple 分发证书时可做编译验证，但不能宣称已获得正式可分发包。

签名更新源流程已复用现有 `SPARKLE_PRIVATE_KEY`；公开公钥保存在仓库公开配置中。未来正式分发 CI 还需要受保护的 Developer ID Application 证书及其导出密码、团队 ID，以及用于公证的 Apple 身份/API 密钥材料。若 Widget/App Group 需要 provisioning profile，也需准备正确 profile。实际 secret 名称以工作流为准；不要把任何私密材料发到普通聊天。不重新生成密钥或新增凭据；本次沿用现有 Secret，发布范围已获用户确认。

建议上线次序：先运行无凭据的 macOS 构建/测试；在审批环境安全配置所需凭据；验证 Archive/Export、Developer ID 签名与公证；生成已签名的更新包和 feed；经批准发布；最后实测安装旧版→下载→安装并重启。检查更新源和用户数据保留后才能宣布功能已上线。

## 1.0.9（18）更新验证记录

- 源码提交：`56723f6409da392576a323501eb757f4f9395078`；标签 `macos-v1.0.9`。
- [历史源码标签](https://github.com/niujt/CodexMeter/tree/macos-v1.0.9)；旧安装包按保留最近两个版本的策略清理。该版本使用与当时已安装 1.0.8（17）相同的 Apple Development 团队签名；主应用和 Widget 均为 Intel / Apple Silicon 通用二进制，DMG 含 Applications 快捷方式。
- [实际签名 CI](https://github.com/niujt/CodexMeter/actions/runs/38425047834) 已通过。包 SHA-256：`d7e391a5451e3a9cf9dd6dab7f4a761ca72cc100a1ff0de82c143d98be08effd`。CI 复用已有 Secret，验证签名并拒绝篡改包和篡改 feed。
- 本机用已安装 App 的公开公钥独立验证公开下载的 DMG 与 CI appcast，并再次验证篡改拒绝。发布签名 appcast 后，才提供应用内更新。
- 97 项 Swift 测试、7 项公开更新配置测试、最终 22 项刷新/账户回归通过。安装、重启、设置与 Widget 保留仍由用户执行真实 17 → 18 升级验收；本次未手动替换本机应用，未做 Developer ID 公证。

## 1.0.12（21）发布与验收边界

- 源码提交：`d03e6c416cea7bb148313df65d2c1ff68fedc283`；[历史源码标签](https://github.com/niujt/CodexMeter/tree/macos-v1.0.12)为 `macos-v1.0.12`，旧安装包按保留最近两个版本的策略清理。主应用和小组件均为 1.0.12（21），支持 arm64 / x86_64。
- 105 项 Swift 测试（含 8 项小组件刷新回归）、7 项更新配置测试、本地 Release 构建、嵌套签名、App Group、DMG 完整性和 Applications 快捷方式均通过。
- [签名 CI](https://github.com/niujt/CodexMeter/actions/runs/39016134589) 复用原有 Secret，对公开包再次验证后生成包签名和签名 appcast。独立使用已安装应用的公钥验证公开下载包与 appcast，篡改包和篡改 feed 均被拒绝；保留原有 3 个更新条目。
- DMG SHA-256：`986b5b858d0f20aaa5beb306baef3027bac976c00ab850e4f86a05040692c194`。
- 本机只回收已确认过期的小组件进程，系统重启的扩展签名已与当前安装包一致，且新扩展生成时间线成功；主应用进程和已安装文件保持原状。桌面实际显示及用户点击更新后的 1.0.12 启动、功能和设置保留尚待验收。本次沿用 Apple Development 签名，未做 Developer ID 公证；本地构建产物保留，未执行清理。
