# macToolBox

一个 macOS 菜单栏常驻工具箱（Swift）。**不进 Dock，只在菜单栏有图标**，点击弹出小窗口，里面展示功耗、线缆信息和工具开关。

## 功能

1. **硬件概览** — 菜单顶部展示 CPU / GPU 功耗曲线，数显可在实时功耗与 5 分钟平均功耗之间切换；下方仅显示当前外接的线缆，并区分线缆规格能力与当前实际 PD / 数据 / DisplayPort 链路状态。
2. **外接显示器控制** — 通过 DDC/VCP 控制外接显示器亮度、对比度、音量与静音；菜单内提供显示器选择器和三条百分比滑杆，亮度默认使用平滑过渡。
3. **定时亮度** — 在设置 → 显示器中按本地时间配置覆盖全天的亮度时段；仅作用于当前所有可 DDC 写亮度的外接屏。手动滑杆 / 媒体键调节单屏，直到下一个时段边界后恢复计划。仅在 ToolBox 运行时生效，建议配合开机自启动。
4. **擦屏幕** — 启用后所有屏幕全黑 60 秒，每个屏幕中央显示同步倒计时。
   - 退出：长按 `⌃ ⌥ ⌘ + Esc` ≥ 1.5 秒；或等倒计时到 0 自动收起。
5. **后台干** — 防止系统睡眠（后台软件可继续运行），允许屏幕熄灭省电；接通电源时合盖也不睡。
   - 机制：`PreventUserIdleSystemSleep` 电源断言 + `caffeinate -s` 子进程（AC 电源下阻止合盖休眠）。
6. **菜单交互** — 左键点击菜单栏图标弹出窗口，点击其他区域自动收起；右键点击菜单栏图标可直接打开面板、切换常用功能、进入“设置”或退出应用。硬件、线缆、显示器和工具区域采用无需纵向滚动的紧凑单窗口布局，弹窗使用真正裁切的圆角玻璃表面。
7. **设置窗口** — “首页 / 线缆 / 显示器 / 通用”；显示器页含实时控制与定时亮度编辑，通用页可管理开机自启动与输入监控状态。

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
- **外接显示器媒体键（亮度 / 音量）**：需要 **辅助功能 (Accessibility)** + **输入监控 (Input Monitoring)**。
  - 拦截媒体键使用可修改事件的 `CGEvent` tap（`.defaultTap`），用于吞掉系统媒体键，避免内置屏也被调节；因此通常还需要辅助功能，而不仅是输入监控。
  - 设置 → 通用 会分别显示两项权限状态；「打开系统设置」会按当前缺失项跳转（常见是辅助功能），并先登记 ToolBox。
  - 打开开关并返回 ToolBox 后，应用会在重新激活时检测并重建事件监听，无需后台轮询。
  - 首次创建事件监听失败时仅弹窗引导一次；之后不再打扰。
  - **两项权限都已开启仍失败时，请完全退出并重新打开 ToolBox**（macOS TCC 对当前进程有时需重启才生效）。
  - 调试构建路径/签名变化时，列表里可能出现多条 ToolBox，请只打开当前正在运行的那一项。
  - 请始终用 `./build.sh` 启动 Release 产物，避免误开旧的 Debug/其他路径副本。

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
| `Sources/ToolBox/Settings/*` | 设置窗口玻璃卡片等共享 UI 原语 |
| `Sources/ToolBox/Permissions.swift` | 输入监控 / 辅助功能检测与引导 |
| `Sources/ToolBox/HotKeyController.swift` | Carbon 全局热键（无需权限） |
| `Sources/ToolBox/DisplayControl/DisplayControlMediaKeyController.swift` | 外接显示器亮度 / 音量媒体键 CGEventTap |
| `Sources/ToolBox/ScreenWipe/*` | 擦屏幕：每屏黑窗 + 倒计时 + 长按退出 |
| `Sources/ToolBox/Awake/*` | 后台干：电源断言 + caffeinate |
| `Resources/ToolBox.entitlements` | 仅 `hardened-runtime`（非沙盒） |

## 已知限制

- **后台干合盖**：`caffeinate -s` 仅在 **AC 电源** 有效；电池下合盖仍可能睡眠。
- **外接显示器 DDC**：Apple Silicon 路径依赖 macOS 私有 `IOAVService` / `CoreDisplay` 符号，系统版本变化时可能降级为不可用；部分显示器只能写入、不能可靠读取 VCP，此时菜单会显示 `DDC write-only`。应用会优先使用硬件实时读值；读值失败时，带序列号的显示器会恢复上次成功读取或写入的亮度百分比，没有可用记忆时才显示估算值。滑杆按显示器报告的 VCP 原始范围量化（例如 20 档对应 5% 步进），写入期间会保持用户目标值，不会被滞后的回读值拉回。部分显示器不支持音量或静音 VCP，会在菜单中显示为不可用。
- **定时亮度**：应用未运行时不会改写显示器；无独立守护进程。计划写入为离散跳变（`smooth: false`），强制绕过 write-only 缓存去重。无序列号的显示器不做持久身份绑定。
- 默认快捷键（`⌃⌥⌘+Esc`）若与系统或其它 App 冲突可在源码中修改。

## 验证

- **后台干**：开关 ON 后 `pmset -g assertions` 可见 `PreventUserIdleSystemSleep` 由 ToolBox 持有；`pgrep caffeinate` 命中 `caffeinate -s`；空闲过屏幕休眠计时→屏幕熄灭但系统不睡。
- **外接显示器控制**：连接支持 DDC/VCP 的外接屏后，菜单中选择该屏幕，亮度 / 对比度 / 音量滑杆应可写回显示器；若显示 `DDC write-only`，设置一个非 100% 亮度后断开并重连，确认带序列号显示器恢复上次百分比且连续拖动不会频闪。媒体键在有可控外接屏时控制外接屏。
- **定时亮度**：设置 → 显示器 → 开启「定时亮度」，确认当前时段写入所有可控外接屏；拖动滑杆后仅该屏被覆盖直至下个边界；改时段或重启应用后按当前本地时间重新应用。
- **擦屏幕**：开关 ON→所有屏幕全黑 + 每屏同步倒计时；长按 `⌃⌥⌘+Esc` 收起；到 0 自动收起。
