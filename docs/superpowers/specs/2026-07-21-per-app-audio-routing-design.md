# 分应用音频路由设计

## 背景

ToolBox 需要为单个应用提供独立的输出音量和输出设备规则。例如，Zoom 可以以 `300%` 音量输出到耳机，同时其他应用继续通过系统默认扬声器播放。

macOS 没有公开的“替另一个进程设置输出设备”属性，也没有公开 API 强制第三方应用切换输入源。macOS 14.2 起提供 Core Audio Process Tap，可以捕获指定进程的输出，在 Tap 被读取时静音原始输出，再由 ToolBox 重新播放到指定硬件设备。因此本设计只采用 Process Tap，不引入 Background Music 的虚拟 HAL 驱动。

## 目标

- 按应用保存输出音量规则，范围为 `0%-300%`，默认 `100%`。
- 按应用保存输出设备规则；未指定时跟随系统默认输出。
- 在菜单栏弹窗中提供紧凑的音量步进控制。
- 在设置窗口中提供精细滑块和输出设备选择。
- 应用退出、设备断开、权限拒绝或音频管线失败时，不能让原应用永久静音。
- 使用 bundle ID 作为持久化身份，并能在应用重启或 helper 进程变化后重新绑定。
- 保持现有 macToolBox 的 provider -> service -> model -> view 分层。

## 非目标

- 本版本不强制第三方应用更换输入设备。
- 本版本不创建虚拟输入设备，也不安装 `/Library/Audio/Plug-Ins/HAL` 驱动。
- 不复制 Background Music 的 GPLv2 源码；只参考其架构和公开 API 行为。
- 不修改真实输出设备的 master volume。应用增益只作用于被捕获的应用流。
- 不承诺所有应用都能被同一个 bundle ID 识别；helper 进程识别必须通过公开进程信息和可维护的兼容映射完成。

## 能力边界

### 输出音量

用户百分比与 DSP 增益严格分离：

```text
volumePercent = 0...300
linearGain = volumePercent / 100.0
```

`100%` 表示不改变样本，`300%` 表示 `3.0x` 振幅，约 `+9.54 dB`。`0%` 仍然需要读取 Tap，以便让 `mutedWhenTapped` 接管原始输出，然后将该路写成静音。

最终写入硬件前执行 Float32 峰值保护并将样本限制在 `[-1, 1]`。限制次数和峰值通过非实时遥测上报给 UI；UI 对超过 `100%` 的规则显示削波风险，但不偷偷把用户设置改回较低值。

### 输出设备

设备规则持久化为稳定的 device UID，而不是会随启动、热插拔或 `coreaudiod` 重启变化的 `AudioObjectID`。特殊值 `systemDefault` 表示每次解析当前系统默认输出设备。

Process Tap 不改变 Zoom 自己的设备选择，而是执行以下数据流：

```text
目标进程
  -> CATapDescription.processes
  -> Process Tap (CATapMutedWhenTapped)
  -> 私有 Aggregate Device
  -> Route Engine: 增益 / 声道映射 / 峰值保护
  -> 指定硬件输出设备
```

未配置规则的应用不创建 Tap，继续沿系统原始路径播放。

### 输入设备

本版本不提供分应用输入设备设置，也不在规则模型或 UI 中保留无法执行的输入偏好。后续若要实现输入，需要单独设计虚拟输入设备和应用内选择流程。

## 系统版本、权限和分发

- Process Tap 功能最低为 macOS 14.2。
- 项目整体仍可保持 macOS 14.0 部署目标；在 14.0 和 14.1 上音频功能显示为不可用，并且不调用不可用的符号。
- `Info.plist` 必须加入 `NSAudioCaptureUsageDescription`，说明 ToolBox 需要捕获应用音频。
- 第一次启动包含 Tap 的 Aggregate Device 时由系统请求系统音频录制权限。权限状态不能通过高频轮询“修复”；创建或启动失败应进入明确的错误状态，并提供打开系统设置的入口。
- Process Tap 核心不需要管理员安装、HAL 驱动或重启 `coreaudiod`，但仍需要验证 Developer ID 签名、notarization 和权限说明。

## 架构

### 组件关系

```text
AudioRuleStore                 持久化 bundle ID -> AppAudioRule
       |
AudioRoutingService            主线程/控制面，编译规则并协调生命周期
   /            \
ProcessRegistry   DeviceRegistry
   |                 |
ProcessTapController  RoutePlanCompiler
       \             /
          AudioRouteEngine (ObjC++ / Core Audio)
                    |
       Process Tap + private Aggregate + IOProc
```

SwiftUI 只接触 `AudioRoutingMenuModel` 和 `AudioRoutingSettingsModel`。实时 IO 回调不调用 SwiftUI、Combine、UserDefaults、日志格式化或可能分配内存的 API。

### `AudioRuleStore`

负责版本化的 `UserDefaults` 编码、边界校验和迁移。建议模型：

```swift
struct AppAudioRule: Codable, Equatable, Identifiable {
    var bundleID: String
    var volumePercent: Int
    var outputDeviceUID: String?

    var id: String { bundleID }
}
```

约束：

- `volumePercent` 解码后夹在 `0...300`；缺失值使用 `100`。
- `nil` 的 `outputDeviceUID` 表示 `systemDefault`。
- 运行时的 PID、Process Object ID、Tap ID、Aggregate Device ID 和 AudioObjectID 不持久化。
- 损坏、未知版本或无效 UID 的数据记录 OSLog 错误并忽略对应条目，不阻塞应用启动。

### `ProcessRegistry`

通过 `kAudioHardwarePropertyProcessObjectList` 和 Process Object 属性发现当前连接到 HAL 的进程，维护：

- PID、bundle ID、显示名称和 Process Object ID；
- `kAudioProcessPropertyIsRunningOutput` 状态；
- bundle ID 到当前 Process Object ID 集合的映射。

规则以 bundle ID 匹配，运行时绑定到当前进程对象。进程退出或 Process Object 消失时销毁对应 Tap；同 bundle ID 的新进程出现时重新绑定。

初版只使用公开信息。Zoom、Teams、浏览器等实际发声可能来自 helper，因此允许加入版本化的公开 bundle ID 兼容映射。无法确认归属时，UI 显示独立的 helper 进程，不使用私有 LaunchServices API 猜测 responsible process。

### `DeviceRegistry`

监听：

- `kAudioHardwarePropertyDevices`；
- `kAudioHardwarePropertyDefaultOutputDevice`；
- 每个候选设备的 alive、stream configuration、nominal sample rate 和 channel layout；
- `kAudioHardwarePropertyServiceRestarted`。

对外发布稳定的设备快照：UID、名称、是否可输出、通道数、采样率、是否可用。设备列表更新不能把已保存的 UID 删除；设备暂时消失时由路由服务进入降级状态。

### `RoutePlanCompiler`

将规则和进程快照编译成运行时计划：

```swift
struct RoutePlan {
    var routes: [OutputDeviceUID: OutputRoute]
}

struct OutputRoute {
    var targetDeviceUID: String
    var sources: [RoutedProcess]
}

struct RoutedProcess {
    var processObjectID: AudioObjectID
    var bundleID: String
    var volumePercent: Int
}
```

只有以下规则需要进入计划：

- 增益不是 `100%`；或
- 输出设备不是 `systemDefault`。

`systemDefault` 在编译时解析为当前默认输出设备 UID。默认输出变化时重新编译计划，不能把旧的 AudioObjectID 继续用于新设备。

### `ProcessTapController`

每个 `RoutedProcess` 建立一个 Tap：

```text
CATapDescription.processes = [processObjectID]
description.isPrivate = true
description.isMixdown = true
description.isMono = false
description.muteBehavior = .mutedWhenTapped
```

创建顺序必须满足故障安全：

1. 创建 Tap，但不主动停止原进程。
2. 创建并配置目标 Aggregate Device 和 Route Engine。
3. 完成输出 IOProc 注册并成功启动目标设备。
4. 开始读取 Tap，依赖 `mutedWhenTapped` 让原输出在读取期间静音。

任一步失败都先停止新管线、销毁 Aggregate/Tap，再报告错误；由于 Tap 没有持续被读取，原音频应恢复。

停止顺序相反：先停止 IOProc 和 Aggregate，再销毁 Tap。禁止先销毁仍在读取的 Tap。

### `AudioRouteEngine`

AudioRouteEngine 负责每个目标输出设备的一组 Tap。实现放在 Objective-C++/C++ 边界，Swift 侧只调用生命周期和原子参数接口，原因是 IO 回调需要明确的实时安全约束。

每个 route 包含：

- 一个私有 Aggregate Device；
- 目标硬件输出设备作为 Aggregate 的 sub-device；
- 该 route 的 Tap UID 列表；
- 一个预分配的 IOProc 上下文和固定 source slot；
- 每个 source slot 的原子 gain、启用状态和峰值计数器。

Aggregate 的 Tap 列表和 sub-device 列表只在控制队列上修改。Route 变更时，在非实时线程停止 IO、更新 composition、重新建立格式转换状态，再启动 IO。

IOProc 约束：

- 只使用预分配 buffer、原子数值、无锁 ring buffer 或 Core Audio 提供的当前 buffer；
- 不使用 malloc/free、Objective-C 消息发送、Swift ARC、UserDefaults、Combine、OSLog 或阻塞锁；
- 对每个输入 source 应用线性增益，按目标输出声道数复制/丢弃/映射；
- 统一执行 Float32 峰值检测与 `[-1, 1]` 限制；
- 用原子计数器记录 underrun、overrun、格式不匹配和削波，控制面异步读取这些计数器。

格式处理必须在启动 route 前准备好。首版支持双声道 Float32；设备通道超过 2 时将 stereo 映射到前两个输出通道，其余通道置零。若 Tap 和目标设备的采样率不同，使用预配置的 AudioConverter/等价 Core Audio 转换路径；转换器不得在 IOProc 中首次创建。

### `AudioRoutingService`

服务运行在主 actor，控制队列负责 HAL 对象生命周期。它提供：

```swift
func start()
func stop()
func setVolume(bundleID: String, percent: Int)
func setOutputDevice(bundleID: String, deviceUID: String?)
func resetRule(bundleID: String)
```

服务职责：

- 读取和保存规则；
- 合并 ProcessRegistry、DeviceRegistry 和权限状态；
- 编译新 RoutePlan；
- 对只改变音量的规则执行原子 gain 更新，不重建 Tap；
- 对改变设备、进程绑定或 Aggregate composition 的规则执行 route rebuild；
- 将运行状态发布为 `inactive`、`starting`、`active`、`degraded` 或 `failed`，并携带用户可读原因。

## UI 设计

### 菜单栏弹窗

现有弹窗是固定尺寸、非滚动布局。音频区域采用紧凑列表，不把所有已安装应用塞入主面板：

- 显示当前正在输出音频或已经配置规则的应用；
- 以稳定高度显示最多 4 行；
- 每行包含应用图标、名称、减号按钮、百分比和加号按钮；
- 步长为 `5%`，范围为 `0%-300%`；
- 默认没有规则时显示 `100%`，但不创建 Tap；
- 配置更多应用的入口打开设置页音频标签；
- Tap 未授权、目标设备不可用或管线失败时，百分比旁显示状态，而不是把数字当成已生效值。

按钮使用现有 SF Symbols 和 tooltip/accessibility label。加减按钮的布局使用固定宽度，避免 `100%`、`300%` 等文本导致行宽变化。

### 设置窗口

新增“音频”侧边栏标签，沿用当前 `SettingsView`、`SettingsChrome`、`SettingsSection` 和 `SettingsInnerCard` 风格。

每个应用行提供：

- 应用图标、名称和 bundle ID 辅助信息；
- `0...300` 的精细滑块；
- 可编辑百分比和 `100%` 重置按钮；
- 输出设备 Picker：`系统默认` + 当前可用输出设备；
- 当前状态：已生效、等待应用启动、设备不可用、需要音频权限或管线失败。

设置页列表支持搜索和纵向滚动；弹窗不复用设置页的滚动容器。两者都只调用 `AudioRoutingService`，不直接读写 UserDefaults 或 Core Audio。

## 状态与错误处理

### 规则状态

```text
inactive        无自定义规则，原始系统输出
waitingProcess  规则已保存，但目标进程尚未成为 HAL client
starting        Tap / Aggregate / IOProc 正在建立
active          Tap 正在读取且目标设备已输出
degraded        规则存在，但设备或 helper 当前不可用，原始输出已恢复
failed          最近一次建立或重建失败，原始输出已恢复
```

### 必须可见的错误

- 音频捕获权限被拒绝；
- Process Tap 创建失败；
- Aggregate Device 创建、composition 更新或 IO 启动失败；
- 目标设备消失或不再支持输出；
- 采样率、声道布局或格式转换不可用；
- `coreaudiod` 重启导致服务状态失效。

错误必须写入 OSLog（控制面）并发布到 UI；不能在 catch 中无条件吞掉错误。实时回调只计数，不能直接记录日志。

### 故障安全

所有 route rebuild 都遵循“新管线未启动前不读取 Tap”的原则。旧管线切换时，如果新管线无法启动，旧 Tap 必须停止读取并销毁，使应用回到原始 Core Audio 路径。设备断开时不把 Zoom 留在静音状态；规则保留，状态降级，等待设备恢复或用户改为系统默认。

## 测试策略

### 单元测试

- `0`、`100`、`300` 和超范围百分比的校验与 `linearGain` 映射；
- 默认规则不创建 Tap；非默认设备或非 `100%` 才进入 RoutePlan；
- `systemDefault` 在默认设备变化后解析为新 UID；
- UserDefaults round-trip、损坏数据、未知版本和 UID 持久化；
- PID/Process Object 变化后按 bundle ID 重新绑定；
- helper 兼容映射不会把未知进程误归属；
- 设备消失、权限失败和 route rebuild 失败时状态为 `degraded/failed` 且不报告 `active`；
- 只改音量时保持 Tap/route ID 不变，只更新原子 gain。

### 音频核心测试

用固定 Float32 输入 buffer 和 fake route context 验证：

- `0%` 输出全零；
- `100%` 保持样本；
- `300%` 乘以 `3.0` 并在输出边界限制；
- 多 source 混音、双声道映射和额外通道静音；
- 峰值计数、underrun 和格式不匹配计数；
- IOProc 不创建对象、不分配内存、不调用控制面接口。

### 真机集成测试

至少覆盖 Zoom、Music、Chrome helper，以及内建扬声器、USB 耳机、有线耳机和蓝牙设备：

- 单应用改增益；
- Zoom 到耳机、Music 到扬声器；
- 两个应用同时路由到同一设备；
- 两个应用路由到不同设备；
- 应用启动、退出和 helper PID 变化；
- 设备热插拔、睡眠唤醒、蓝牙通话 profile 变化；
- 权限首次授权、拒绝、系统设置重新授权；
- ToolBox 退出或崩溃后原始系统输出恢复。

验收以“没有永久静音、规则状态真实、路由设备正确、`300%` 可听且削波状态可解释”为准。

## 文档和实施顺序

实施前先完成一个不包含正式 UI 的 Process Tap 原型，验证 Zoom/helper、Aggregate 输出格式、权限和热插拔。原型通过后按以下顺序实现：

1. `AudioRuleStore`、设备/进程快照和纯数据模型；
2. Objective-C++ `AudioRouteEngine` 与固定 buffer DSP 测试；
3. `ProcessTapController`、route lifecycle 和故障恢复；
4. `AudioRoutingService` 与 AppDelegate 生命周期接线；
5. 弹窗紧凑控制；
6. 设置页详细控制；
7. README 权限、系统版本、音量削波和输入限制说明；
8. Debug/Release 构建、签名和真机验收。

正式实现计划应把原型失败（尤其是多 Aggregate 同时使用同一物理设备、Zoom helper 识别和蓝牙 profile）作为阻断项处理，不在 UI 层用假状态掩盖底层能力不足。

## 参考

- [Background Music 调研笔记](../../research/backgroundmusic-macos-audio-api.md)
- [Apple: Capturing system audio with Core Audio taps](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps)
- [Apple: CATapDescription](https://developer.apple.com/documentation/coreaudio/catapdescription)
- [Apple: AudioHardwareCreateProcessTap](https://developer.apple.com/documentation/coreaudio/audiohardwarecreateprocesstap(_:_:))
- [Apple: AudioHardwareCreateAggregateDevice](https://developer.apple.com/documentation/coreaudio/audiohardwarecreateaggregatedevice(_:_:))
- [Background Music source at commit 8c25450](https://github.com/kyleneideck/BackgroundMusic/tree/8c25450e9b0d3867417c4872018b03fb30c0c85c)
