# macToolBox

一个 macOS 菜单栏常驻工具箱（Swift）。**不进 Dock，只在菜单栏有图标**，点击弹出小窗口，里面展示功耗、线缆信息和工具开关。

## 功能

1. **硬件概览** — 菜单顶部展示 CPU / GPU 功耗曲线，数显可在实时功耗与 5 分钟平均功耗之间切换；下方仅显示当前外接的线缆，并区分线缆规格能力与当前实际 PD / 数据 / DisplayPort 链路状态。
2. **外接显示器控制** — 通过 DDC/VCP 控制外接显示器亮度、对比度、音量与静音；菜单内提供显示器选择器和三条百分比滑杆，亮度默认使用平滑过渡。
3. **聚焦模式** — 自动保持当前使用的显示器清晰，并用点击穿透的黑色遮罩降低其他显示器的干扰。优先跟随键盘焦点窗口；辅助功能未授权或窗口不可读时继续按鼠标所在显示器回退。开关和“聚焦变暗强度”会持久保存。
4. **定时亮度** — 在设置 → 显示器中按本地时间配置覆盖全天的亮度时段；仅作用于当前所有可 DDC 写亮度的外接屏。手动滑杆 / 媒体键调节单屏，直到下一个时段边界后恢复计划。仅在 ToolBox 运行时生效，建议配合开机自启动。
5. **擦屏幕** — 启用后所有屏幕全黑 60 秒，每个屏幕中央显示同步倒计时。
   - 退出：长按 `⌃ ⌥ ⌘ + Esc` ≥ 1.5 秒；或等倒计时到 0 自动收起。
6. **后台干** — 防止系统睡眠（后台软件可继续运行），允许屏幕熄灭省电；接通电源时合盖也不睡。
   - 机制：`PreventUserIdleSystemSleep` 电源断言 + `caffeinate -s` 子进程（AC 电源下阻止合盖休眠）。
7. **菜单交互** — 左键点击菜单栏图标时，窗口会贴着图标下方弹出，并完整限制在图标所在的屏幕内；点击其他区域自动收起。右键点击菜单栏图标可直接打开面板、切换常用功能、进入“设置”或退出应用。硬件、线缆、显示器和工具区域采用无需纵向滚动的紧凑单窗口布局，弹窗使用真正裁切的圆角玻璃表面。
8. **分应用音频** — macOS 14.2+ 使用公开 Core Audio Process Tap，为正在播放音频的应用设置 0%–300% 音量并选择输出设备；100% 为原始增益。超过 100% 可能削波失真。
9. **设置窗口** — “首页 / 线缆 / 显示器 / 音频 / 通用”；显示器页提供聚焦模式开关和 20%–85% 变暗强度，音频页提供精确百分比滑杆、恢复 100% 和输出设备选择。

## 构建

```bash
brew install xcodegen        # 仅需一次
./build.sh                   # 生成工程 + Release 构建 + 启动
```

产物：`build/Build/Products/Release/ToolBox.app`（ad-hoc 签名 + Hardened Runtime）。

本地默认版本号为 `DEV0.0.0`。可覆盖：

```bash
VERSION=1.2.3 BUILD_NUMBER=42 OPEN=0 ./build.sh
```

> 只想构建不自动打开：`OPEN=0 ./build.sh`

## 发布（CI）

GitHub Actions 工作流 [Release](.github/workflows/release.yml) 为手动触发：

1. 在 Actions → **Release** → **Run workflow**
2. 输入版本号（如 `1.2.3`）
3. CI 会用该版本编译，打包 `ToolBox-<version>.app.zip` 与 `ToolBox-<version>.dmg`
4. 创建 **Draft** Release，描述为上一正式 Release 之后的全部 commit message

本地打包（需已构建 `.app`）：

```bash
VERSION=1.2.3 APP_PATH=build/Build/Products/Release/ToolBox.app ./scripts/package-release.sh
```

## 权限

- **后台干 / 擦屏幕退出热键**：无需权限（Carbon 全局热键）。
- **聚焦模式**：建议授予 **辅助功能 (Accessibility)**，以事件驱动方式跟随键盘焦点窗口；首次主动开启时会提示授权，设置 → 显示器会显示状态并提供系统设置入口。未授权时功能保持开启，跨屏鼠标移动会即时更新清晰显示器，另有约 2 秒健康检查兜底，不需要输入监控权限。
- **外接显示器媒体键（亮度 / 音量）**：需要 **辅助功能 (Accessibility)** + **输入监控 (Input Monitoring)**。
  - 拦截媒体键使用可修改事件的 `CGEvent` tap（`.defaultTap`），用于吞掉系统媒体键，避免内置屏也被调节；因此通常还需要辅助功能，而不仅是输入监控。
  - 设置 → 通用 会分别显示两项权限状态；「打开系统设置」会按当前缺失项跳转（常见是辅助功能），并先登记 ToolBox。
  - 打开开关并返回 ToolBox 后，应用会在重新激活时检测并重建事件监听，无需后台轮询。
  - 首次创建事件监听失败时仅弹窗引导一次；之后不再打扰。
  - **两项权限都已开启仍失败时，请完全退出并重新打开 ToolBox**（macOS TCC 对当前进程有时需重启才生效）。
  - 调试构建路径/签名变化时，列表里可能出现多条 ToolBox，请只打开当前正在运行的那一项。
  - 请始终用 `./build.sh` 启动 Release 产物，避免误开旧的 Debug/其他路径副本。
- **分应用音频**：首次启用非默认规则时需要允许 **系统音频录制**。拒绝权限或目标设备断开时，ToolBox 会停止路由并恢复应用原始输出路径。

## 目录结构

| 文件 | 职责 |
|---|---|
| `project.yml` | XcodeGen 工程规格（应用类型、LSUIElement、entitlements） |
| `build.sh` | `xcodegen generate && xcodebuild && open` |
| `Sources/ToolBox/ToolBoxApp.swift` | `@main` SwiftUI App + AppDelegate adaptor |
| `Sources/ToolBox/AppDelegate.swift` | 状态栏图标 + 菜单浮层/右键菜单 + 硬件数据启动/停止 + 开关联动 |
| `Sources/ToolBox/MenuBarPanelController.swift` / `GlassHostingViewController.swift` / `GlassPopoverViewController.swift` | AppKit 自定义菜单浮层控制器 / 通用液态玻璃容器 / 菜单弹窗封装 |
| `Sources/ToolBox/PopoverContent.swift` / `FeatureState.swift` | 弹窗内容 UI / 开关状态 |
| `Sources/ToolBox/HardwareData/*` | 菜单硬件模型与 AppKit 绘制视图 |
| `Sources/ToolBox/Power/*` | 整机芯片功耗采集与快照模型 |
| `Sources/ToolBox/CableData/*` | 线缆、USB-PD、数据传输和显示协议采集与快照模型 |
| `Sources/ToolBox/DisplayControl/*` | 外接显示器硬件 DDC 控制接口、能力快照、菜单控制区、媒体键拦截和 Darwin 后端 |
| `Sources/ToolBox/DisplayControl/Schedule/*` | 定时亮度领域模型、持久化、运行时协调与设置编辑 UI |
| `Sources/ToolBox/FocusMode/*` | 聚焦模式状态机、AX 焦点追踪、显示器目标解析和被动遮罩窗口 |
| `Sources/ToolBox/AudioRouting/*` | 分应用规则、HAL 进程/设备注册表、Process Tap 路由引擎、实时 DSP 与两套 UI |
| `Sources/ToolBox/Settings/*` | 设置窗口玻璃卡片等共享 UI 原语 |
| `Sources/ToolBox/Permissions.swift` | 输入监控 / 辅助功能检测与引导 |
| `Sources/ToolBox/HotKeyController.swift` | Carbon 全局热键（无需权限） |
| `Sources/ToolBox/DisplayControl/DisplayControlMediaKeyController.swift` | 外接显示器亮度 / 音量媒体键 CGEventTap |
| `Sources/ToolBox/ScreenWipe/*` | 擦屏幕：每屏黑窗 + 倒计时 + 长按退出 |
| `Sources/ToolBox/Awake/*` | 后台干：电源断言 + caffeinate |
| `Resources/ToolBox.entitlements` | 仅 `hardened-runtime`（非沙盒） |
| `Resources/Assets.xcassets/AppIcon.appiconset` | 应用图标（Finder / 通知 / 「关于」使用；菜单栏图标仍是 SF Symbol `hammer` 模板图） |
| `Resources/AppIcon/hammer-glyph.png` | 图标源图形（锤子，黑色 + 透明），底板由脚本按规范重绘 |
| `scripts/generate-app-icon.py` | 由上述源图形重新生成整套 `AppIcon.appiconset`（改图后需重跑） |

## 已知限制

- **后台干合盖**：`caffeinate -s` 仅在 **AC 电源** 有效；电池下合盖仍可能睡眠。
- **外接显示器 DDC**：Apple Silicon 路径依赖 macOS 私有 `IOAVService` / `CoreDisplay` 符号，系统版本变化时可能降级为不可用；部分显示器只能写入、不能可靠读取 VCP，此时菜单会显示 `DDC write-only`。应用会优先使用硬件实时读值；读值失败时，带序列号的显示器会恢复上次成功读取或写入的亮度百分比，没有可用记忆时才显示估算值。滑杆按显示器报告的 VCP 原始范围量化（例如 20 档对应 5% 步进），写入期间会保持用户目标值，不会被滞后的回读值拉回。部分显示器不支持音量或静音 VCP，会在菜单中显示为不可用。
- **定时亮度**：应用未运行时不会改写显示器；无独立守护进程。计划写入为离散跳变（`smooth: false`），强制绕过 write-only 缓存去重。无序列号的显示器不做持久身份绑定。
- **聚焦模式遮罩**：只在软件层覆盖其他显示器，不会修改 DDC / 硬件背光，也不会降低显示器功耗。单显示器时不会显示遮罩；不提供手动指定焦点屏幕。
- **分应用音频**：仅控制输出，不改变 Zoom 等第三方应用的麦克风输入。每个应用使用独立的 Tap-only capture aggregate，耳机作为独立输出 sink，因此不会把全双工耳机的麦克风流混入播放。路由先启动物理输出，再启动带静音属性的 capture；正常停止时使用现有 10 ms source ramp 静音并等待 12 ms，再先停 capture，避免输出启动失败或退出时让原应用保持静音。路由只有在 capture 和 output 都实际处理 frame 后才显示为活动；无数据会显示“权限、受保护内容或当前无可捕获音频”。实时缓冲按设备 period/latency/safety offset 计算并限制在 `256...2048` frames；ring 满会记录丢帧，高水位时跳到近期音频，underrun 恢复使用淡入。300% 是线性 3.0 倍增益，写入硬件前会清理非有限值并限制到 `[-1, 1]`，仍可能产生可闻失真。
- **应用与设备是独立概念**：Zoom 只是示例，ToolBox 不创建 `ZoomDevice` 或其他应用专用设备。输出设备列表来自 Core Audio 系统枚举；只要应用的 HAL Process Object 存在，音量调整会立即写入其 route，即使应用当时静音，也会在下一帧音频到来时使用新 gain。
- **输出设备兼容预检**：设置页会在创建 Tap 前读取输出 stream 的虚拟格式和 nominal sample rate。当前只接受 alive、单 stream、native-endian packed interleaved Float32 stereo，且源/目标采样率误差不超过 `1000 ppm` 的设备；不兼容项会禁用并显示原因，这表示明确降级，不代表设备损坏。蓝牙耳机收到 profile/流/格式变化通知时会立即暂停引用它的分应用路由；HAL 状态稳定 1 秒后重新读取完整配置，A2DP 恢复兼容时自动恢复路由。USB、HDMI、内建和有线设备不使用这条蓝牙保护路径。跨采样率转换、多声道与 non-interleaved layout 尚未启用。
- 默认快捷键（`⌃⌥⌘+Esc`）若与系统或其它 App 冲突可在源码中修改。

## 验证

完整自动验证可运行 `./scripts/verify-audio-routing-build.sh`；真机输出矩阵见 [`docs/testing/per-app-audio-acceptance.md`](docs/testing/per-app-audio-acceptance.md)。

- **后台干**：开关 ON 后 `pmset -g assertions` 可见 `PreventUserIdleSystemSleep` 由 ToolBox 持有；`pgrep caffeinate` 命中 `caffeinate -s`；空闲过屏幕休眠计时→屏幕熄灭但系统不睡。
- **外接显示器控制**：连接支持 DDC/VCP 的外接屏后，菜单中选择该屏幕，亮度 / 对比度 / 音量滑杆应可写回显示器；若显示 `DDC write-only`，设置一个非 100% 亮度后断开并重连，确认带序列号显示器恢复上次百分比且连续拖动不会频闪。媒体键在有可控外接屏时控制外接屏。
- **定时亮度**：设置 → 显示器 → 开启「定时亮度」，确认当前时段写入所有可控外接屏；拖动滑杆后仅该屏被覆盖直至下个边界；改时段或重启应用后按当前本地时间重新应用。
- **聚焦模式**：连接两台显示器，开启辅助功能权限后在不同屏幕的应用窗口间切换键盘焦点，确认非焦点屏变暗且仍可点击；撤销权限后跨屏移动鼠标，确认功能保持开启并即时切换清晰屏。还需覆盖上下排列、全屏/空间切换、热插拔、睡眠唤醒、重启恢复，以及与擦屏幕同时开启。
- **分应用音频**：让 Zoom 或播放器持续发声，在弹窗中调整到 300% 并在设置 → 音频选择另一输出设备；确认声音切换。使用蓝牙耳机时启动和停止麦克风，确认 HFP 切换期间分应用路由暂停、应用与 ToolBox 界面保持响应，恢复 A2DP 后路由自动恢复。退出 ToolBox、拔出目标设备及拒绝权限后，确认应用原始输出立即恢复。
- **擦屏幕**：开关 ON→所有屏幕全黑 + 每屏同步倒计时；长按 `⌃⌥⌘+Esc` 收起；到 0 自动收起。
