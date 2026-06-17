# macToolBox

一个 macOS 菜单栏常驻工具箱（Swift）。**不进 Dock，只在菜单栏有图标**，点击弹出小窗口，里面是三个开关。

## 功能

1. **擦屏幕** — 启用后所有屏幕全黑 60 秒，主屏中央显示倒计时。
   - 退出：长按 `⌃ ⌥ ⌘ + Esc` ≥ 1.5 秒；或等倒计时到 0 自动收起。
2. **后台干** — 防止系统睡眠（后台软件可继续运行），允许屏幕熄灭省电；接通电源时合盖也不睡。
   - 机制：`PreventUserIdleSystemSleep` 电源断言 + `caffeinate -s` 子进程（AC 电源下阻止合盖休眠）。
3. **放键盘** — 只禁用**内置键盘**，外接蓝牙/USB 键盘照常可用。
   - 解锁：在外接键盘上按 `⌃ ⌥ ⌘ + K`（组合键，单按一个键不会解锁）。
   - 机制：IOHID 独占(seize)内置键盘的 HID 设备，使它的输入不再进入系统。
   - 安全：检测不到外接键盘时拒绝启用；10 分钟自动解锁兜底。

## 构建

```bash
brew install xcodegen        # 仅需一次
./build.sh                   # 生成工程 + Release 构建 + 启动
```

产物：`build/Build/Products/Release/ToolBox.app`（ad-hoc 签名 + Hardened Runtime）。

> 只想构建不自动打开：`OPEN=0 ./build.sh`

## 权限

- **后台干**：无需任何权限。
- **擦屏幕**（长按退出检测）、**放键盘**（独占 HID）：需要授予 **输入监控 (Input Monitoring)** 权限。首次启用对应功能时会自动弹窗引导；或到 *系统设置 → 隐私与安全性 → 输入监控* 手动开启。
- 部分机型可能还需要 **辅助功能 (Accessibility)**。

## 目录结构

| 文件 | 职责 |
|---|---|
| `project.yml` | XcodeGen 工程规格（应用类型、LSUIElement、entitlements） |
| `build.sh` | `xcodegen generate && xcodebuild && open` |
| `Sources/ToolBox/ToolBoxApp.swift` | `@main` SwiftUI App + AppDelegate adaptor |
| `Sources/ToolBox/AppDelegate.swift` | 状态栏图标 + NSPopover + 三个 coordinator + 开关联动 |
| `Sources/ToolBox/PopoverContent.swift` / `FeatureState.swift` | 弹窗 UI / 开关状态 |
| `Sources/ToolBox/Permissions.swift` | 输入监控 / 辅助功能检测与引导 |
| `Sources/ToolBox/HotKeyController.swift` | Carbon 全局热键（无需权限） |
| `Sources/ToolBox/EventTapController.swift` | 通用 listen-only CGEventTap |
| `Sources/ToolBox/ScreenWipe/*` | 擦屏幕：每屏黑窗 + 倒计时 + 长按退出 |
| `Sources/ToolBox/Awake/*` | 后台干：电源断言 + caffeinate |
| `Sources/ToolBox/KeyboardPark/*` | 放键盘：HID 检测 + 独占内置键盘 |
| `Resources/ToolBox.entitlements` | 仅 `hardened-runtime`（非沙盒） |

## 已知限制

- **放键盘**：`kIOHIDOptionsTypeSeizeDevice` 在个别机型上可能不稳定或被其它进程占用；若独占失败会提示并回退。真正的「纯内置键盘」精确方案（Karabiner 式 DriverKit 虚拟 HID）属于后续工作。
- **后台干合盖**：`caffeinate -s` 仅在 **AC 电源** 有效；电池下合盖仍可能睡眠。
- 默认快捷键（`⌃⌥⌘+Esc` / `⌃⌥⌘+K`）若与系统或其它 App 冲突可在源码中修改。

## 验证

- **后台干**：开关 ON 后 `pmset -g assertions` 可见 `PreventUserIdleSystemSleep` 由 ToolBox 持有；`pgrep caffeinate` 命中 `caffeinate -s`；空闲过屏幕休眠计时→屏幕熄灭但系统不睡。
- **擦屏幕**：开关 ON→全屏黑 + 倒计时；长按 `⌃⌥⌘+Esc` 收起；到 0 自动收起。
- **放键盘**：插外接键盘→开关 ON→内置键盘无反应、外接正常；单按任意键不解锁；外接键盘按 `⌃⌥⌘+K` 解锁。
