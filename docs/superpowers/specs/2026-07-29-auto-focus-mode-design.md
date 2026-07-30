# 自动聚焦模式设计

## 背景

ToolBox 需要迁移 ScreenFocus 的自动聚焦能力：用户启用后，当前键盘焦点窗口所在的显示器保持清晰，其余显示器通过半透明黑色遮罩降低视觉干扰。功能入口位于菜单栏弹窗右下角，作为现有“擦屏幕”和“后台干”之后的第三个按钮。

参考分析材料对焦点来源存在冲突：功能概要称键盘焦点驱动，深度分析则确认原应用以鼠标所在显示器为主。本文采用已经确认的产品决策：**键盘焦点窗口优先，鼠标所在显示器作为无权限或查询失败时的回退**。

## 已确认的产品决策

| 决策 | 结果 |
|---|---|
| 模式 | 仅自动聚焦，不提供手动聚焦 |
| 主焦点来源 | 当前前台应用的 AX 聚焦窗口 |
| 无 AX 权限 | 模式继续启用，回退到鼠标所在显示器，并引导授权 |
| 变暗方式 | 半透明黑色遮罩，不修改显示器硬件亮度 |
| 强度配置 | 设置页连续滑杆，20%...85%，步长 1%，默认 55% |
| 动画 | 焦点切换时约 0.18 秒淡入淡出 |
| 持久化 | 模式开关和遮罩强度跨应用重启保留 |
| 弹窗入口 | 在右下角现有两个圆形按钮后追加“聚焦模式”按钮 |
| 右键菜单 | 不新增入口 |
| 不迁移内容 | 手动模式、悬停揭示、延迟变暗、四档预设、全局快捷键 |

## 目标

1. 准确跟随当前外部应用的键盘焦点窗口所在显示器。
2. 缺少辅助功能权限时仍可立即使用，并以鼠标位置稳定降级。
3. 遮罩不抢焦点、不接收鼠标事件、不改变真实亮度，也不干扰现有 DDC 亮度计划。
4. 正确处理跨屏窗口、ToolBox 自身窗口、多 Space、全屏、显示器热插拔和睡眠唤醒。
5. 将 AX 观察、显示器选择、遮罩生命周期、持久化和 UI 状态隐藏在一个小型协调器接口之后。
6. 为纯几何选择、权限回退、状态恢复和窗口增删提供确定性测试。

## 非目标

1. 不修改内建或外接显示器的物理亮度。
2. 不在 ToolBox 退出后继续运行。
3. 不提供每台显示器独立强度、显示器白名单或固定聚焦屏。
4. 不提供悬停临时揭示、变暗延迟、亮度档位或动画时长设置。
5. 不监听普通键盘输入，不新增 Input Monitoring 权限需求。
6. 不保证遮罩降低面板功耗；它只降低本地视觉亮度和干扰。

## 模块设计

### FocusModeCoordinator

新增一个 `@MainActor ObservableObject` 深模块，由 `AppDelegate` 持有，并在应用生命周期中调用 `start()` / `stop()`。界面只依赖以下接口：

- `@Published private(set) var isEnabled: Bool`
- `@Published private(set) var overlayOpacity: Double`
- `@Published private(set) var permissionState: FocusPermissionState`
- `func setEnabled(_ enabled: Bool)`
- `func setOverlayOpacity(_ opacity: Double)`
- `func requestAccessibilityPermission()`
- `func openAccessibilitySettings()`
- `func start()`
- `func stop()`

协调器内部拥有：

- 已持久化配置；
- 前台应用与 AX observer 生命周期；
- 鼠标回退 monitor；
- 屏幕参数、睡眠和唤醒观察；
- 最近一个有效的非 ToolBox 聚焦显示器；
- 每块非聚焦屏的遮罩窗口；
- 一个低频健康检查计时器。

调用者不直接读取 AX、枚举 `NSScreen`、创建窗口或写 `UserDefaults`。

### Focus target resolution

将屏幕选择规则放在纯值逻辑中。输入为当前屏幕几何、可选的 AX 窗口矩形、可选的鼠标点和可选的上次有效显示器 ID；输出为一个聚焦显示器 ID 或 `nil`。

普通情况下的优先级固定为：

1. 有效且不属于 ToolBox 的 AX 聚焦窗口；
2. 鼠标所在显示器；
3. 仍然在线的上次有效聚焦显示器；
4. `NSScreen.screens.first` 对应的主显示器；
5. 没有屏幕时返回 `nil`。

前台 PID 是 ToolBox 自身时使用一个明确特例：若最近一个外部应用聚焦屏仍在线，优先保留它；只有没有这项历史状态时才使用鼠标和主屏回退。这样用户点击菜单栏按钮或打开设置时，不会因为 ToolBox 自己获得键盘焦点而把工作屏切到菜单栏所在屏。

AX 的 `kAXPositionAttribute` 使用以主屏左上角为原点的全局坐标，而 `NSScreen.frame` 使用 AppKit 的左下角坐标。实现必须以主屏高度显式转换坐标，再计算窗口与各屏幕的交集，不能直接比较两个坐标系。

窗口跨屏时选择相交面积最大的屏幕。若面积相同，则优先窗口中心点所在屏；仍相同则保留上次有效屏；最后使用稳定的显示器 ID 排序，避免焦点抖动。空矩形、非有限值或与所有屏幕均无交集视为 AX 无结果并进入回退。

## 事件驱动的焦点追踪

### 前台应用

使用 `NSWorkspace.didActivateApplicationNotification` 跟踪前台应用。前台 PID 变化时：

1. 移除旧 `AXObserver` 的通知和 run-loop source；
2. 若 PID 是 ToolBox 自身，保留最近一个外部应用焦点屏，不把菜单弹窗或设置窗口当成工作屏；
3. 若有 AX 权限，为新 PID 创建应用级 `AXUIElement` 和 `AXObserver`；
4. 将 observer 的 run-loop source 加入主 run loop 的 common modes；
5. 查询并绑定当前聚焦窗口，然后立即 reconcile。

系统级 AX 元素不支持通知，因此 observer 必须绑定到具体前台应用。应用退出、observer 失效或前台应用切换时必须完整拆除旧注册。

### AX notifications

应用级观察至少注册 `kAXFocusedWindowChangedNotification`。得到新的聚焦窗口后，为该窗口注册移动和缩放通知；窗口更换时先注销旧窗口通知。

关注的事件为：

- 前台应用变化；
- 聚焦窗口变化；
- 聚焦窗口移动；
- 聚焦窗口缩放；
- 被观察应用终止或 AX 元素失效。

不同应用可能不支持某些 AX 通知。`kAXErrorNotificationUnsupported` 是可降级情况：保留其它通知并依靠健康检查；非法参数、无效 observer、消息失败和创建失败需要记录带上下文的诊断，但不能关闭聚焦模式。

AX callback 只负责转发事件到主 actor；窗口属性查询、屏幕选择和窗口更新统一在协调器内串行执行。

### Permission and fallback

用户主动把模式从关闭切换为启用且当前不受信任时，复用现有 `Permissions.requestAccessibilityOnce()`，其内部调用 `AXIsProcessTrustedWithOptions` 并设置 `kAXTrustedCheckOptionPrompt=true`。系统提示是异步的，当前返回值仍可能是 `false`，因此功能不得等待或拒绝启用。

若模式是从持久化状态自动恢复，启动时只通过 `Permissions.isAccessibilityTrusted` 检查，不反复触发系统提示。用户仍可在设置页再次请求权限或打开辅助功能设置。

未授权期间安装全局和本地 `mouseMoved | leftMouseDragged` monitor，通过 `NSEvent.mouseLocation` 更新回退屏幕。权限状态用低频检查刷新；检测到授权后自动安装 AX observer，并停止不再需要的频繁鼠标重算。AX 已授权但当前应用没有可用聚焦窗口时，仍使用鼠标回退。

设置页提供权限状态和“打开系统设置”动作，复用 `Permissions.openAccessibilitySettings()`。关闭聚焦模式时不主动提示权限。

### Health check

低频健康检查只用于修复第三方应用不支持或偶发丢失的 AX 通知，不作为主要追踪路径。建议启用且已授权时每 2 秒验证一次前台 PID、聚焦窗口身份和权限状态；结果未变化时不重建遮罩或启动动画。

## 遮罩窗口

### FocusOverlayWindow

每块非聚焦显示器最多一个专用遮罩窗口。窗口行为：

- borderless、不可成为 key/main window；
- 黑色背景，透明度由 `overlayOpacity` 控制；
- `ignoresMouseEvents = true`，鼠标事件穿透到下层应用；
- `hidesOnDeactivate = false`，不因 ToolBox 非活跃而消失；
- 覆盖完整 `screen.frame`，包括菜单栏和 Dock 区域；
- `collectionBehavior` 包含 `canJoinAllSpaces`、`stationary`、`fullScreenAuxiliary` 和 `ignoresCycle`；
- 使用不抢占激活状态的窗口类型和排序方式；
- 不调用 `NSApp.activate`，不临时切换 activation policy。

窗口层级需要覆盖普通窗口和全屏内容，但低于“擦屏幕”使用的 shielding level。实现时以 macOS 14 真机验证 `.screenSaver` 是否满足双屏、独立 Space、全屏和 Stage Manager；若需要调整，只允许在遮罩窗口实现内部改变，不扩大协调器接口。

### Reconciliation

每次焦点、配置或屏幕拓扑变化都进入一个私有 `reconcile(reason:)`：

1. 读取最新 `NSScreen.screens`，不缓存 `NSScreen` 数组；
2. 若禁用、屏幕数小于 2 或没有目标屏，移除全部遮罩；
3. 对聚焦屏淡出并在动画完成后关闭遮罩；
4. 为其它在线屏创建或复用遮罩，并淡入到当前强度；
5. 移除已拔出显示器对应的窗口；
6. 强度变化只更新现有遮罩 alpha，不重建窗口；
7. 相同目标和相同拓扑的重复事件不做窗口操作。

动画约 0.18 秒。新事件到来时以最新目标为准，取消或覆盖旧动画，避免快速切屏后留下错误遮罩。

### Lifecycle interactions

- 监听 `NSApplication.didChangeScreenParametersNotification`，显示器增加、移除、镜像或重排后重新枚举和 reconcile。
- 休眠时暂停健康检查并隐藏/清理遮罩；唤醒后重新检查权限、前台应用和屏幕拓扑，再重建。
- “擦屏幕”窗口使用更高 shielding level；聚焦协调器不因擦屏启动而关闭。ToolBox 被擦屏流程临时激活时，焦点解析继续忽略自身 PID并保留最后外部焦点屏。
- 应用退出时同步移除 observers、run-loop source、event monitors、timers 和全部遮罩窗口。

## Persistence

使用两个简单的 `UserDefaults` 键：

- `focusMode.enabled`
- `focusMode.overlayOpacity`

首次运行默认关闭，默认强度 0.55。加载和写入均将强度钳制到 `0.20...0.85`；缺失、非有限或越界值回退或钳制。`start()` 加载持久化状态；若保存为启用，应用启动后立即进入权限检查和 reconcile，不依赖用户打开弹窗或设置页。

开关和强度由协调器统一写入，SwiftUI 不直接使用 `@AppStorage`，避免 UI 值与后台运行状态分离。

## UI design

### Menu bar panel

`PopoverContent.controlsBar` 在“后台干”之后增加第三个 40pt 圆形按钮：

- SF Symbol: `scope`
- 标题: `聚焦模式`
- 提示: `突出当前使用的显示器`
- 启用强调色: system teal
- accessibility value: `已启用` / `已关闭`

按钮通过显式 binding 调用协调器的 `setEnabled(_:)`，不把持久化开关塞入临时 `FeatureState`。控件栏高度不变，现有 560pt 宽度可容纳第三个按钮。

### Settings > 显示器

在现有显示器页增加始终可见的“聚焦模式”section，不依赖外接屏或 DDC 状态，包含：

1. “启用聚焦模式”开关；
2. “聚焦变暗强度”滑杆，显示整数百分比；
3. 辅助功能权限状态；
4. 未授权时的“打开系统设置”按钮。

滑杆复用 `ScrollWheelSlider`，范围 `0.20...0.85`，步长 `0.01`。修改后立即写入、发布并更新现有遮罩。首页功能列表增加“聚焦模式”。

## Error handling and diagnostics

1. AX 未授权、当前无窗口、通知不支持或应用暂时无响应属于可恢复状态，使用鼠标回退并保留模式开启。
2. observer 创建、通知注册、属性转换和窗口创建失败必须记录错误类别、目标 PID 或显示器 ID；重复错误需要限频，避免健康检查刷日志。
3. 不把权限提示结果误认为同步授权结果。
4. 无效 AX position/size、非有限 opacity 和失效显示器引用不得进入窗口操作。
5. 停止和清理必须幂等；移除未注册通知等预期清理错误不覆盖真正的先前错误。

## Testing

### Unit tests

- AX/AppKit 坐标转换，包括显示器位于主屏上方、下方和负 X 方向；
- 窗口完整位于某屏、跨屏最大交集、相同交集 tie-break；
- ToolBox 自身 PID 过滤；
- AX 无权限、无窗口、无效矩形时的鼠标/上次屏/主屏回退；
- 单屏和零屏返回；
- 开关与强度加载、保存、默认值、非有限值和范围钳制；
- start/stop 幂等、observer 更换、健康检查不产生重复 reconcile；
- 屏幕增加、移除、重排时的期望遮罩集合；
- 强度变化只更新 alpha，不重建遮罩；
- 快速切换时 latest-target-wins。

AX、工作区通知、时钟和遮罩窗口操作通过内部 seam 注入 fake；屏幕选择与坐标转换保持纯函数。测试不依赖实际辅助功能权限或真实多显示器。

### Integration and manual checks

1. 运行聚焦 XCTest 和完整 `ToolBoxTests`。
2. 运行 Debug build 与 `git diff --check`。
3. 双屏真机检查首次授权、拒绝授权、授权后自动升级和撤销权限后的回退。
4. 检查点击暗屏后下层应用收到点击并触发聚焦切换。
5. 检查左右、上下排列以及跨屏窗口拖动/缩放。
6. 检查独立 Space、全屏应用、Mission Control 和 Stage Manager。
7. 检查显示器热插拔、镜像切换、睡眠唤醒和应用重启恢复。
8. 检查与“擦屏幕”同时使用时的窗口层级和恢复。

## Documentation

更新 README 的功能清单、设置说明、权限说明、源码目录和限制：聚焦模式需要辅助功能权限以精确跟随键盘焦点；未授权时使用鼠标回退；遮罩不修改或节省硬件亮度/功耗。
