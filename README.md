# macToolBox

一个 macOS 菜单栏常驻工具箱（Swift）。**不进 Dock，只在菜单栏有图标**，点击弹出小窗口，里面展示功耗、线缆信息和工具开关。

## 功能

1. **硬件概览** — 菜单顶部展示 CPU / GPU 功耗曲线，数显可在实时功耗与 5 分钟平均功耗之间切换；下方仅显示当前外接的线缆，并区分线缆规格能力与当前实际 PD / 数据 / DisplayPort 链路状态。
2. **外接显示器控制** — 通过 DDC/VCP 控制外接显示器亮度、对比度、音量与静音；菜单内提供显示器选择器和三条百分比滑杆，亮度默认使用平滑过渡。
3. **擦屏幕** — 启用后所有屏幕全黑 60 秒，每个屏幕中央显示同步倒计时。
   - 退出：长按 `⌃ ⌥ ⌘ + Esc` ≥ 1.5 秒；或等倒计时到 0 自动收起。
4. **后台干** — 防止系统睡眠（后台软件可继续运行），允许屏幕熄灭省电；接通电源时合盖也不睡。
   - 机制：`PreventUserIdleSystemSleep` 电源断言 + `caffeinate -s` 子进程（AC 电源下阻止合盖休眠）。
5. **菜单交互** — 左键点击菜单栏图标弹出窗口，点击其他区域自动收起；右键点击菜单栏图标可直接打开面板、切换常用功能、进入“设置”或退出应用。硬件、线缆、显示器和工具区域采用无需纵向滚动的紧凑单窗口布局，弹窗使用真正裁切的圆角玻璃表面。
6. **设置窗口** — 提供“首页 / 通用”两个选项页；“通用”中可管理开机自启动，并跳转到系统登录项设置。

## 构建

```bash
brew install xcodegen        # 仅需一次
./build.sh                   # 生成工程 + Release 构建 + 启动
```

产物：`build/Build/Products/Release/ToolBox.app`（ad-hoc 签名 + Hardened Runtime）。

> 只想构建不自动打开：`OPEN=0 ./build.sh`

## 权限

- **后台干**：无需任何权限。
- **外接显示器媒体键 / 擦屏幕长按退出检测**：需要授予 **输入监控 (Input Monitoring)** 权限。首次启用对应功能时会自动弹窗引导；或到 *系统设置 → 隐私与安全性 → 输入监控* 手动开启。
- 部分机型可能还需要 **辅助功能 (Accessibility)**。

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
| `Sources/ToolBox/Permissions.swift` | 输入监控 / 辅助功能检测与引导 |
| `Sources/ToolBox/HotKeyController.swift` | Carbon 全局热键（无需权限） |
| `Sources/ToolBox/DisplayControl/DisplayControlMediaKeyController.swift` | 外接显示器亮度 / 音量媒体键 CGEventTap |
| `Sources/ToolBox/ScreenWipe/*` | 擦屏幕：每屏黑窗 + 倒计时 + 长按退出 |
| `Sources/ToolBox/Awake/*` | 后台干：电源断言 + caffeinate |
| `Resources/ToolBox.entitlements` | 仅 `hardened-runtime`（非沙盒） |

## 已知限制

- **后台干合盖**：`caffeinate -s` 仅在 **AC 电源** 有效；电池下合盖仍可能睡眠。
- **外接显示器 DDC**：Apple Silicon 路径依赖 macOS 私有 `IOAVService` / `CoreDisplay` 符号，系统版本变化时可能降级为不可用；部分显示器只能写入、不能可靠读取 VCP，此时菜单会显示 `DDC write-only`，百分比为估算值但滑杆仍可调节。滑杆按显示器报告的 VCP 原始范围量化（例如 20 档对应 5% 步进），写入期间会保持用户目标值，不会被滞后的回读值拉回。部分显示器不支持音量或静音 VCP，会在菜单中显示为不可用。
- 默认快捷键（`⌃⌥⌘+Esc`）若与系统或其它 App 冲突可在源码中修改。

## 验证

- **后台干**：开关 ON 后 `pmset -g assertions` 可见 `PreventUserIdleSystemSleep` 由 ToolBox 持有；`pgrep caffeinate` 命中 `caffeinate -s`；空闲过屏幕休眠计时→屏幕熄灭但系统不睡。
- **外接显示器控制**：连接支持 DDC/VCP 的外接屏后，菜单中选择该屏幕，亮度 / 对比度 / 音量滑杆应可写回显示器；若显示 `DDC write-only`，确认估算百分比仍能调节且连续拖动不会频闪。媒体键在有可控外接屏时控制外接屏。
- **擦屏幕**：开关 ON→所有屏幕全黑 + 每屏同步倒计时；长按 `⌃⌥⌘+Esc` 收起；到 0 自动收起。
