# macToolBox

一个 macOS 菜单栏常驻工具箱（Swift，macOS 14.0+）。**不进 Dock，只在菜单栏有图标**，点击弹出小窗口，里面展示功耗、线缆、Wi-Fi 信息和工具开关。

## 功能

1. **硬件概览** — 菜单顶部展示 CPU / GPU 功耗曲线，数显可在实时功耗与 5 分钟平均功耗之间切换；下方仅显示当前外接的线缆，并区分线缆规格能力与当前实际 PD / 数据 / DisplayPort 链路状态。
2. **外接显示器控制** — 通过 DDC/VCP 控制外接显示器亮度、对比度、音量与静音；菜单内提供显示器选择器和三条百分比滑杆，亮度默认使用平滑过渡。若显示器 Capability String 广告了色彩预设（Dell `0xE2` 优先，MCCS `0x14` 其次），菜单会多出「色彩预设」选择器，设置 → 显示器会列出可写预设。
3. **聚焦模式** — 自动保持当前使用的显示器清晰，并用点击穿透的黑色遮罩降低其他显示器的干扰。优先跟随键盘焦点窗口；辅助功能未授权或窗口不可读时继续按鼠标所在显示器回退。开关和“聚焦变暗强度”会持久保存。
4. **定时亮度** — 在设置 → 显示器中按本地时间配置覆盖全天的亮度时段；仅作用于当前所有可 DDC 写亮度的外接屏。手动滑杆调节单屏，直到下一个时段边界后恢复计划。仅在 ToolBox 运行时生效，建议配合开机自启动。
5. **擦屏幕** — 启用后所有屏幕全黑 60 秒，每个屏幕中央显示同步倒计时。
   - 退出：按下 `⌃ ⌥ ⌘ + Esc`；或等倒计时到 0 自动收起。
6. **后台干** — 防止系统睡眠（后台软件可继续运行），允许屏幕熄灭省电；接通电源时合盖也不睡。
   - 机制：`PreventUserIdleSystemSleep` 电源断言 + `caffeinate -s` 子进程（AC 电源下阻止合盖休眠）。
7. **菜单交互** — 左键点击菜单栏图标时，窗口贴着图标所在菜单栏下沿弹出，并完整限制在该屏幕的可见区域内；首次打开会在状态栏按钮完成布局后再定位，避免漂移到屏幕中部。点击其他区域或按 `Esc` 自动收起。右键点击菜单栏图标可直接打开面板、切换常用功能、进入“设置”或退出应用。弹窗采用紧凑的圆角玻璃表面和固定单页布局，不提供纵向滚动。
8. **分应用音频** — macOS 14.2+ 使用公开 Core Audio Process Tap，为正在播放音频的应用设置 0%–300% 音量并选择输出设备；100% 为原始增益。超过 100% 可能削波失真。
9. **区域截图** — 默认快捷键 `⌃⌥S` 冻结所有显示器后打开跨屏选择层。可点选窗口 / 辅助功能元素、拖拽矩形，或切换到滚动截图；完成后进入标注编辑器，并可选用本机 OCR。
10. **设置窗口** — “首页 / 线缆 / Wi-Fi / 显示器 / 音频 / 截图 / 快捷键 / 通用 / 关于”。显示器页含聚焦模式、实时控制和色彩预设；截图页显示屏幕录制、辅助功能与自动滚动所需的事件投递权限；关于页显示版本与更新状态。
11. **Wi-Fi 信号** — 使用公开 CoreWLAN 每 2 秒读取当前连接的 RSSI、噪声、SNR、链路速率、信道、频段、宽度、PHY 和安全模式；弹窗提供紧凑概览，设置 → Wi-Fi 提供最近 5 分钟的 RSSI / SNR 内存曲线和完整参数。
12. **自动更新** — 启动时及运行期间每 6 小时从 GitHub Release 检查最新正式版并自动下载，验证附件 SHA-256（GitHub 提供时）、应用版本、Bundle ID 和代码签名后提示重启安装。可在设置 → 关于切换 Beta 通道（可能不稳定）或关闭自动检查/下载；`DEV0.0.0` 开发版只检测和提醒，绝不自动下载。

## 构建

### 界面语言

ToolBox 会按 macOS 的首选语言自动选择界面语言。目前提供简体中文、繁体中文和英语；未匹配到这三种语言时使用英语。语言选择跟随系统设置，重启应用后生效。

```bash
brew install xcodegen        # 仅需一次
./build.sh                   # 校验 OCR 运行时 + 生成工程 + Release 构建 + 启动
```

构建产物位于 `build/Build/Products/Release/ToolBox.app`；脚本会将其内容原位同步到固定运行路径
`/Applications/ToolBox.app`，并始终从该路径启动。同步不会删除并重建目标 `.app` 目录。

首次构建会下载固定版本的 ONNX Runtime macOS arm64 官方归档（当前为 1.24.3），并在解压前校验
SHA-256；缓存位于未跟踪的 `.build/ocr-runtime`。高级 OCR 还会用带 wheel SHA-256 的 lock 安装
CPython 3.11.15 Worker 运行时，缓存位于 `.build/ocr-worker-runtime`。也可先单独执行：

```bash
./scripts/bootstrap_ocr_runtime.sh
./scripts/bootstrap_ocr_worker_runtime.sh --bootstrap
```

Xcode 的用户脚本沙箱保持开启，ONNX Runtime 由 Xcode 的标准 Embed Frameworks 阶段复制和签名；
Worker 运行时中的 `python3` / `.so` / `.dylib` 会在构建后由 `scripts/sign_nested_runtime.sh` 按同一签名身份重签。

本地默认版本号为 `DEV0.0.0`。可覆盖：

```bash
VERSION=1.2.3 BUILD_NUMBER=42 OPEN=0 ./build.sh
```

> 只想构建不自动打开：`OPEN=0 ./build.sh`

## 命令行工具

ToolBox.app 内含签名的 `toolbox` 命令行程序。首次安装应用后，可将它链接到当前用户的
`~/.local/bin`；该命令不会使用 `sudo`、覆盖其他文件或修改 shell 配置：

```bash
/Applications/ToolBox.app/Contents/Helpers/toolbox install
toolbox --help
```

若 `~/.local/bin` 尚未加入 `PATH`，按命令输出将它加入当前 shell 后重新打开终端。
`toolbox uninstall` 只删除由 ToolBox 创建并仍指向当前应用的链接。

常用命令：

```bash
toolbox status
toolbox display list
toolbox display get --display-id 1
toolbox display set --display-id 1 --brightness 55
toolbox focus set --enabled true --opacity 55
toolbox audio apps
toolbox audio devices
toolbox audio set --bundle-id com.apple.Music --volume 120
toolbox awake on
toolbox launch-at-login on
```

查询命令可加 `--json` 输出稳定的英文字段。控制命令在 ToolBox 未运行时会在后台启动应用，
因为显示器、音频、聚焦模式、TCC 和登录项仍由签名的 GUI 应用统一管理；加 `--no-launch`
可要求应用未运行时立即失败。`--help`、`--version` 和参数校验不会启动应用。

CLI 只开放 ToolBox 已有的控制能力，不接受任意 `defaults` key、shell 命令或提权操作。
显示器和音频一次只修改一个参数，避免多项硬件操作部分成功。退出码为：`0` 成功、`64`
参数错误、`69` 应用或控制协议不可用、`77` 权限不足、`1` 硬件或领域操作失败。

`build.sh` 固定使用 Bundle ID `com.youtonghy.toolbox`。首次构建会按顺序选择钥匙串中的第一张
`Developer ID Application`、`Apple Development` 或名为 `youtonghy` 的证书，并将其 SHA-1 identity 锁定在
`~/Library/Application Support/ToolBox/build-signing-identity`；后续构建若找不到同一张证书会
直接失败，不会静默改用另一张证书。也可以在首次构建时用
`CODE_SIGN_IDENTITY="证书名称或 SHA-1" ./build.sh` 选择钥匙串中有效的自签名代码签名证书。
只有在主动轮换证书时才应删除 identity 文件，轮换后 macOS 可能要求重新授权。
自签名证书没有 Apple Team ID，脚本会为这类本地构建启用 ONNX Runtime 所需的 Library
Validation 豁免（`Resources/ToolBox-AdHoc.entitlements`）；Apple Development / Distribution 和
Developer ID 签名使用空 entitlements，Hardened Runtime 仍由工程设置开启，嵌入动态库必须使用同一团队证书。

没有有效签名证书时，`ALLOW_ADHOC=1 ./build.sh` 可用于一次性 ad-hoc 构建，但 ad-hoc 包的
代码身份会随二进制变化，无法可靠保留辅助功能、输入监控等 TCC 授权。固定 Bundle ID、签名
证书和运行路径可显著减少重复授权，但证书轮换、权限数据库重置或 macOS 策略变化仍可能要求
重新授权。

版本号以 `DEV` 开头时，ToolBox 会自动将当前进程的完整 Unified Logging（含
debug/info/error/fault 以及系统框架日志）持续写入
`~/Library/Logs/ToolBox/DEV/`。每次启动创建独立日志文件，并保留最近 10 次会话；
正式版本不启动文件日志。

## 发布（CI）

GitHub Actions 工作流 [Release](.github/workflows/release.yml) 为手动触发：

1. 在 Actions → **Release** → **Run workflow**
2. 输入版本号（如 `1.2.3`）
3. CI 会引导 OCR Worker 运行时、跑 `./scripts/verify-audio-routing-build.sh`，再用该版本编译
4. 打包 `ToolBox-<version>.app.zip` 与 `ToolBox-<version>.dmg`，并生成 CycloneDX SBOM `sbom.cdx.json`
5. 创建 **Draft** Release，描述为上一正式 Release 之后的全部 commit message，附件包含 zip、dmg 和 SBOM

[Nightly](.github/workflows/nightly.yml) 每天北京时间 00:00 **检查**是否需要发 **Pre-release**，而不是每晚都构建。仅当 `main` 相对上一份 Beta 有新 commit 时才编译并发布；内容与上次相同则不发 Beta、也不占用 macOS runner。版本形如 `Beta 260814`（应用内和市场文件名为 `Beta260814`，tag 为 `beta-260814`）。Actions → **Nightly** → **Run workflow** 可手动强制构建；同一天重跑会覆盖当天的 beta。

本地打包（需已构建 `.app`）：

```bash
VERSION=1.2.3 APP_PATH=build/Build/Products/Release/ToolBox.app ./scripts/package-release.sh
```

本地公证（需 Apple ID / 团队 ID / app-specific password）：

```bash
NOTARY_APPLE_ID=... NOTARY_PASSWORD=... TEAM_ID=... ./scripts/notarize.sh /Applications/ToolBox.app
```

`REQUIRE_NOTARIZED=1 ./scripts/package-release.sh` 会在打包前用 `spctl` 和 stapler 校验已公证状态。

## 权限

- **全局快捷键**：无需权限（Carbon 全局热键）。
- **聚焦模式**：建议授予 **辅助功能 (Accessibility)**，以事件驱动方式跟随键盘焦点窗口；首次主动开启时会提示授权，设置 → 显示器会显示状态并提供系统设置入口。未授权时功能保持开启，跨屏鼠标移动会即时更新清晰显示器，另有约 2 秒健康检查兜底，不需要输入监控权限。
- **区域截图**：需要 **屏幕录制** 才能冻结画面。智能元素候选建议授予 **辅助功能**；自动滚动还需要 **事件投递**。设置 → 截图会显示这三项状态。
- **分应用音频**：首次启用非默认规则时需要允许 **系统音频录制**。拒绝权限或目标设备断开时，ToolBox 会停止路由并恢复应用原始输出路径。
- **Wi-Fi 信号**：只读取当前连接，不扫描附近网络，因此不会申请定位权限。macOS 仍可能因隐私策略不提供 SSID / BSSID，此时信号与链路指标继续显示，网络身份标记为“系统未提供”。

## 目录结构

| 文件 | 职责 |
|---|---|
| `project.yml` | XcodeGen 工程规格（应用类型、LSUIElement、entitlements） |
| `build.sh` | 锁定签名身份，引导 OCR 运行时，执行 `xcodegen` / `xcodebuild`，原位更新并启动固定路径下的应用 |
| `Sources/ToolBox/ToolBoxApp.swift` | `@main` SwiftUI App + AppDelegate adaptor |
| `Sources/ToolBox/AppDelegate.swift` | 状态栏图标 + 菜单浮层/右键菜单 + 硬件数据启动/停止 + 开关联动 |
| `Sources/ToolBoxCLI/*` | `toolbox` 参数解析、输出、安装和 XPC 客户端 |
| `Sources/ToolBoxControlProtocol/*` | GUI 与 CLI 共用的版本化控制协议和结构化响应 |
| `Sources/ToolBox/CLI/*` | 应用侧受认证 XPC 服务和命令路由 |
| `Sources/ToolBox/MenuBarPanelController.swift` / `GlassHostingViewController.swift` / `GlassPopoverViewController.swift` | AppKit 自定义菜单浮层控制器 / 通用液态玻璃容器 / 菜单弹窗封装 |
| `Sources/ToolBox/PopoverContent.swift` / `FeatureState.swift` | 弹窗内容 UI / 开关状态 |
| `Sources/ToolBox/HardwareData/*` | 菜单硬件模型与 AppKit 绘制视图 |
| `Sources/ToolBox/Power/*` | 整机芯片功耗采集与快照模型 |
| `Sources/ToolBox/CableData/*` | 线缆、USB-PD、数据传输和显示协议采集与快照模型 |
| `Sources/ToolBox/DisplayControl/*` | 外接显示器硬件 DDC 控制接口、能力快照、菜单控制区和 Darwin 后端 |
| `Sources/ToolBox/DisplayControl/DisplayColorPresetDDPMTable.swift` | 色彩预设名称表与 DDPM 兼容的写入命令 |
| `Sources/ToolBox/DisplayControl/Schedule/*` | 定时亮度领域模型、持久化、运行时协调与设置编辑 UI |
| `Sources/ToolBox/FocusMode/*` | 聚焦模式状态机、AX 焦点追踪、显示器目标解析和被动遮罩窗口 |
| `Sources/ToolBox/AudioRouting/*` | 分应用规则、HAL 进程/设备注册表、Process Tap 路由引擎、实时 DSP 与两套 UI |
| `Sources/ToolBox/WiFiSignal/*` | CoreWLAN 当前连接采样、五分钟内存历史、弹窗概览和设置详情 |
| `Sources/ToolBox/Screenshot/*` | 跨屏区域选择、Shift 多区域、滚动截图、标注编辑与受限内存 PNG 导出 |
| `Sources/ToolBox/Screenshot/Selection/AXAccessibilityActivator.swift` | 截图会话内临时打开目标应用的 AX 树，结束后还原 |
| `Sources/ToolBox/OCR/*` | PP-OCRv6 ONNX 推理、PP-StructureV3 / PaddleOCR-VL 本地 Worker、System OCR、模型选择、结果投影与下载校验 |
| `Sources/ToolBoxOCRWorker/*` | 仅本地运行的 PaddleOCR JSONL Worker 与 Structure/VL 结果归一化 |
| `third_party/ocr-worker/` | Worker 运行时 lock、hashed wheels 与引导说明 |
| `Sources/ToolBox/Settings/*` | 设置窗口玻璃卡片等共享 UI 原语 |
| `Sources/ToolBox/Permissions.swift` | 输入监控 / 辅助功能 / 屏幕录制 / 事件投递检测与引导 |
| `Sources/ToolBox/Shortcuts/*` | Carbon 全局快捷键、规则持久化、权限状态与设置 UI |
| `Sources/ToolBox/ScreenWipe/*` | 擦屏幕：每屏黑窗 + 倒计时；退出动作由统一快捷键注册器路由 |
| `Sources/ToolBox/Awake/*` | 后台干：电源断言 + caffeinate |
| `Resources/ToolBox-AdHoc.entitlements` | 本地 ad-hoc / 自签名构建：关闭 Library Validation，以便加载无 Team ID 的嵌入动态库 |
| `Resources/ToolBox.entitlements` | Apple 团队证书构建：空 entitlements；Hardened Runtime 由 `project.yml` 开启 |
| `Resources/OCRModels/` | 签名模型清单 `catalog-v1.json` / `catalog-v1.sig` 与第三方 NOTICE |
| `Resources/Assets.xcassets/AppIcon.appiconset` | 应用图标（Finder / 通知 / 「关于」使用；菜单栏图标仍是 SF Symbol `hammer` 模板图） |
| `Resources/AppIcon/hammer-glyph.png` | 图标源图形（锤子，黑色 + 透明），底板由脚本按规范重绘 |
| `scripts/generate-app-icon.py` | 由上述源图形重新生成整套 `AppIcon.appiconset`（改图后需重跑） |
| `scripts/bootstrap_ocr_runtime.sh` / `bootstrap_ocr_worker_runtime.sh` | 校验并缓存 ONNX Runtime / 本地 Python Worker 运行时 |
| `scripts/sign_nested_runtime.sh` | 按构建所用身份重签 Worker 运行时嵌套二进制 |
| `scripts/generate_sbom.sh` / `notarize.sh` / `package-release.sh` | 发布用 SBOM、公证与 zip/dmg 打包 |
| `THIRD_PARTY_NOTICES.md` | 第三方来源与许可摘要 |

## 已知限制

- **后台干合盖**：`caffeinate -s` 仅在 **AC 电源** 有效；电池下合盖仍可能睡眠。
- **外接显示器 DDC**：Apple Silicon 路径依赖 macOS 私有 `IOAVService` / `CoreDisplay` 符号，系统版本变化时可能降级为不可用；部分显示器只能写入、不能可靠读取 VCP，此时菜单会显示 `DDC write-only`。应用会优先使用硬件实时读值；读值失败时，带序列号的显示器会恢复上次成功读取或写入的亮度百分比，没有可用记忆时才显示估算值。滑杆按显示器报告的 VCP 原始范围量化（例如 20 档对应 5% 步进），写入期间会保持用户目标值，不会被滞后的回读值拉回。部分显示器不支持音量或静音 VCP，会在菜单中显示为不可用。菜单和设置页的「系统显示设置」按钮会打开 macOS 原生显示设置，用于排列、分辨率和刷新率等系统级选项。
- **色彩预设**：只在 Capability String 广告了 `0xE2(...)` 或 `0x14(...)` 枚举子集时出现；名称来自 DDPM 兼容对照表，未知值显示为 `Preset 0xXX`。写入必须是已广告值，写后读回确认；读回失败或 mismatch 会显示错误，不会把 UI 标成已切换。切换预设可能改变亮度、对比度和 RGB Gain；当前版本不写入 RGB Gain，也不处理 ICC / ColorSync / HDR。实时 `0xF3` 读取失败时，仅对已验证型号使用回退 Capability String（当前为 Dell U2723QE 固件 M2T105）。
- **定时亮度**：应用未运行时不会改写显示器；无独立守护进程。计划写入为离散跳变（`smooth: false`），强制绕过 write-only 缓存去重。无序列号的显示器不做持久身份绑定。
- **聚焦模式遮罩**：只在软件层覆盖其他显示器，不会修改 DDC / 硬件背光，也不会降低显示器功耗。单显示器时不会显示遮罩；不提供手动指定焦点屏幕。
- **分应用音频**：仅控制输出，不改变 Zoom 等第三方应用的麦克风输入。每个应用使用独立的 Tap-only capture aggregate，耳机作为独立输出 sink，因此不会把全双工耳机的麦克风流混入播放。路由先启动物理输出，再启动带静音属性的 capture；正常停止时使用现有 10 ms source ramp 静音并等待 12 ms，再先停 capture，避免输出启动失败或退出时让原应用保持静音。路由只有在 capture 和 output 都实际处理 frame 后才显示为活动；无数据会显示“权限、受保护内容或当前无可捕获音频”。实时缓冲按设备 period/latency/safety offset 计算并限制在 `256...2048` frames；ring 满会记录丢帧，高水位时跳到近期音频，underrun 恢复使用淡入。300% 是线性 3.0 倍增益，写入硬件前会清理非有限值并限制到 `[-1, 1]`，仍可能产生可闻失真。
- **Wi-Fi 网络身份**：当前版本不请求定位权限，也不主动扫描附近网络。RSSI、噪声、SNR、链路速率和信道来自公开 CoreWLAN 当前接口查询；SSID / BSSID 可能被系统隐藏。链路速率是当前 Wi-Fi 协商速率，不代表互联网下载速度。
- **应用与设备是独立概念**：Zoom 只是示例，ToolBox 不创建 `ZoomDevice` 或其他应用专用设备。输出设备列表来自 Core Audio 系统枚举；只要应用的 HAL Process Object 存在，音量调整会立即写入其 route，即使应用当时静音，也会在下一帧音频到来时使用新 gain。
- **输出设备兼容预检**：设置页会在创建 Tap 前读取输出 stream 的虚拟格式和 nominal sample rate。当前只接受 alive、单 stream、native-endian packed interleaved Float32 stereo，且源/目标采样率误差不超过 `1000 ppm` 的设备；不兼容项会禁用并显示原因，这表示明确降级，不代表设备损坏。蓝牙耳机收到 profile/流/格式变化通知时会立即暂停引用它的分应用路由；HAL 状态稳定 1 秒后重新读取完整配置，A2DP 恢复兼容时自动恢复路由。USB、HDMI、内建和有线设备不使用这条蓝牙保护路径。跨采样率转换、多声道与 non-interleaved layout 尚未启用。
- **区域截图**：快捷键会冻结所有显示器后打开跨屏选择层；鼠标按下只记录起点，松开时才区分 AX 元素点击与手动拖拽并进入编辑器。智能选择先锁定光标下最前方窗口，再查询该应用公开的辅助功能组件，滚轮可在组件、父容器和窗口兜底之间切换；高亮使用强调色与深色双层描边。对默认不暴露完整 AX 树的 AppKit / Electron 应用（如 VS Code、Chrome、微信），截图会话会临时打开 `AXEnhancedUserInterface` / `AXManualAccessibility`，并在会话结束时只还原本次实际改过的标志。按住 Shift 可连续点击边缘相接或重叠的窗口/辅助功能元素，松开 Shift 即完成选择；Shift 期间不接受手动拖拽。滚动截图需先切换到滚动模式，再点击或拖拽目标区域并立即开始捕获；滚动过程会锁定同一窗口，并提供自动/手动模式、重试、保留当前结果和取消。完成后可用矩形、椭圆、直线、箭头、画笔、高亮、文字、马赛克和序号标记编辑；预览支持触控板捏合和鼠标滚轮缩放，触控板双指滚动继续用于平移；复制会发布像素一致的 PNG 与 TIFF 剪贴板表示，也可另存为 PNG。自动滚动需要事件投递权限；目标窗口移动、缩放、换屏或消失时会暂停，避免拼接错误。
- **本地 OCR**：截图编辑器从签名模型清单和已打包 runtime 动态列出可用模型，避免显示无法下载或无法启动的占位项。**System OCR** 使用系统 Vision，无需下载，始终出现在列表顶部；短英文较快，中日文和密集排版仍建议 PaddleOCR。PP-OCRv6 Tiny / Small / Medium 使用进程内 ONNX Runtime，并固定使用 CPU 执行；PP-StructureV3 Full 和 PaddleOCR-VL v1 / v1.5 / v1.6 使用本地 JSONL Worker。Worker runtime 固定为 CPython 3.11.15、PaddleOCR 3.7.0、PaddlePaddle 3.2.1，并由带 wheel SHA-256 的 requirements lock 构建。所有可下载模型都经过固定 revision、长度和 SHA-256 校验后发布到本地版本目录；高级模型复用同一下载、校验和 lease 链路。Structure 结果保留布局、OCR、表格 HTML、公式和图表区块及来源多边形，VL 结果保留可复制 Markdown 与来源区块；识别覆盖层不会写入导出的 PNG。
- 默认快捷键可在设置 → 快捷键中修改；若新组合键与系统或其他 App 冲突，当前绑定保持不变。区域截图默认为 `⌃⌥S`，擦屏幕退出默认为 `⌃⌥⌘Esc`（不可关闭，只能改键）。

## 验证

完整自动验证可运行 `./scripts/verify-audio-routing-build.sh`；真机输出矩阵见 [`docs/testing/per-app-audio-acceptance.md`](docs/testing/per-app-audio-acceptance.md)。色彩预设验收记录见 [`docs/testing/display-color-preset-poc-acceptance.md`](docs/testing/display-color-preset-poc-acceptance.md)。

- **后台干**：开关 ON 后 `pmset -g assertions` 可见 `PreventUserIdleSystemSleep` 由 ToolBox 持有；`pgrep caffeinate` 命中 `caffeinate -s`；空闲过屏幕休眠计时→屏幕熄灭但系统不睡。
- **外接显示器控制**：连接支持 DDC/VCP 的外接屏后，菜单中选择该屏幕，亮度 / 对比度 / 音量滑杆应可写回显示器；若显示 `DDC write-only`，设置一个非 100% 亮度后断开并重连，确认带序列号显示器恢复上次百分比且连续拖动不会频闪。系统亮度、音量和静音键保持由 macOS 处理。需要排列、分辨率或刷新率时，使用「系统显示设置」按钮；ToolBox 不模拟控制中心内部菜单。
- **色彩预设**：菜单或设置 → 显示器出现「色彩预设」后，切换到另一个已广告值，确认 OSD / 读回一致；读回失败时应显示错误而不是把该项标为当前。切换后检查亮度/对比度是否被显示器一并改写。
- **定时亮度**：设置 → 显示器 → 开启「定时亮度」，确认当前时段写入所有可控外接屏；拖动滑杆后仅该屏被覆盖直至下个边界；改时段或重启应用后按当前本地时间重新应用。
- **聚焦模式**：连接两台显示器，开启辅助功能权限后在不同屏幕的应用窗口间切换键盘焦点，确认非焦点屏变暗且仍可点击；撤销权限后跨屏移动鼠标，确认功能保持开启并即时切换清晰屏。还需覆盖上下排列、全屏/空间切换、热插拔、睡眠唤醒、重启恢复，以及与擦屏幕同时开启。
- **分应用音频**：让 Zoom 或播放器持续发声，在弹窗中调整到 300% 并在设置 → 音频选择另一输出设备；确认声音切换。使用蓝牙耳机时启动和停止麦克风，确认 HFP 切换期间分应用路由暂停、应用与 ToolBox 界面保持响应，恢复 A2DP 后路由自动恢复。退出 ToolBox、拔出目标设备及拒绝权限后，确认应用原始输出立即恢复。
- **区域截图**：`⌃⌥S` 冻结画面后点选窗口或拖拽矩形进入编辑器；按住 Shift 连续选择相接窗口；切换滚动模式捕获长页。在 VS Code / Chrome 等应用上确认智能候选能落到内部组件，退出选择后辅助功能树被还原。编辑器内标注、缩放、复制 PNG 与另存为应保持像素一致。
- **本地 OCR**：设置 → 截图选择 System OCR 后无需下载即可识别；再选 PP-OCRv6 Tiny 并同意下载，确认校验通过后覆盖层可复制文字且导出 PNG 不含覆盖层。Worker 未打包时 Structure / VL 选项不应出现。
- **擦屏幕**：开关 ON→所有屏幕全黑 + 每屏同步倒计时；按下 `⌃⌥⌘+Esc` 收起；到 0 自动收起。
