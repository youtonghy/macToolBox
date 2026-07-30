# 音频引擎动态格式与运行时恢复重构设计

日期：2026-07-29  
状态：设计已最终批准，尚未进入实施  
范围：重构 `AudioRouteEngine.mm` 及其 C++ 实时模块，控制面尽可能迁移到 Swift

## 1. 目标

重构 ToolBox 分应用音频引擎，使应用在内部切换播放器、helper、输出设备、声道布局或采样率时，不会因为旧 route 继续解释新格式而产生持续电流声、失真或永久静音。

设计借鉴 SoundSource 的四类核心技巧：

1. 持续观察进程、设备、Tap 和 stream 的动态关系；
2. 把变化的捕获格式转换成稳定的内部工作格式；
3. 把格式或拓扑变化建模为可失效、可回滚的 realization 生命周期；
4. 同时监测 PCM 质量和 callback 连续性，并在重建窗口内静音和平滑恢复。

不复制 SoundSource 的 ACE、ecaudiod 或其他私有驱动实现。ToolBox 继续只使用 Apple 公开的 Core Audio Process Tap 和 HAL interface。

## 2. 已确认约束

- 保持现有规则存储、UI 和 `AudioRouteEngineControlling` 外部 interface 不变。
- `AudioRouteController` 的行为不重构；最多只调整 engine factory/wiring。
- Swift 负责 desired state、HAL 查询与监听、格式协商、生命周期、健康判定和恢复策略。
- Objective-C++ 只保留 Core Audio callback trampoline、`AudioBufferList` 验证和 opaque pointer 转发。
- C++ 只保留硬实时路径必须使用的预分配 kernel、callback lease、ring、SRC、声道映射、mix、ramp 和原子计数。
- Swift、Objective-C 消息、日志、锁、动态分配和 Task/Actor hop 均不得进入 IOProc。
- 不新增输入规则、虚拟麦克风、驱动安装或规则 schema。
- PID、AudioObjectID、Tap ID、Aggregate ID 和 stream ID 都是当前 audio-server generation 的瞬态值，不持久化。

## 3. 路线选择

采用“Swift route runtime + 最小 Objective-C++ bridge + C++ realtime kernel”。

未采用的方案：

| 方案 | 不采用原因 |
|---|---|
| 仅用 Swift 包装现有 C++ engine | 生命周期、格式和恢复知识仍分散在 C++，无法获得足够 locality |
| IOProc 也使用 Swift | 无法严格保证不触发 ARC、动态分配、运行时检查或不可控延迟 |

## 4. 目标架构

```text
AudioRouteController
        |
        | existing AudioRouteNativeEngineControlling
        v
SwiftAudioRouteEngineAdapter
        |
        | complete desired state
        v
AudioRouteRuntime (Swift)
        |
        +--> CoreAudioHAL (Swift)
        +--> AudioRouteRecoveryPolicy (Swift)
        +--> AudioRouteHealthEvaluator (Swift)
        |
        v
TBAudioHALCallbackBridge.mm
        |
        v
TBAudioRealtimeKernel.cpp
```

### 4.1 SwiftAudioRouteEngineAdapter

该 adapter 满足现有 `AudioRouteNativeEngineControlling`，把 `changedPlans`、`removingRouteIDs`、retained parameters 和 gain 更新还原成完整 desired state，再交给 runtime 收敛。

它只负责兼容现有调用方式，不执行 HAL 操作，也不拥有 native resource。

### 4.2 AudioRouteRuntime

这是新的 Swift 深 module，也是 route/source 生命周期的唯一所有者。内部 interface 收敛为：

```swift
protocol AudioRouteRuntimeControlling {
    func converge(to intent: AudioRuntimeIntent) throws -> AudioRuntimeApplyResult
    func snapshot() -> [AudioRouteDiagnosticsSnapshot]
    func shutdown(reason: AudioRouteStopReason) -> AudioRouteStopReport
}
```

当前 controller actor 已串行化 engine 调用，因此 runtime 不再创建第二套相互竞争的 actor ownership。HAL property listener 只投递合并事件，所有状态变更最终回到 runtime 的单一控制执行器。

`converge` 接受完整 intent，而不是让调用者指挥 Tap、fade、maintenance 或 rollback 的执行顺序。

### 4.3 CoreAudioHAL

Swift module 负责：

- 查询 output device、process device、Tap format 和 stream virtual format；
- 创建、启动、停止和销毁 Process Tap、private Aggregate 与 IOProc；
- 安装和移除 property listener；
- 将 OSStatus、失败阶段和资源 receipt 保留为 typed result；
- 形成一致的 `HALObservationSnapshot`。

Core Audio audio server 是 true external dependency。module 内部使用生产 adapter 和 scripted test adapter，但该 seam 不暴露到产品外部 interface。

implementation-private port 保持三个入口：

```swift
protocol CoreAudioHALPort {
    func observe(_ request: HALObservationRequest) throws -> HALObservationSnapshot
    func execute(_ transaction: HALTransaction) throws -> HALTransactionReceipt
    func changes(for observations: Set<HALObservation>) -> AsyncStream<HALChange>
}
```

`observe` 一次形成一致快照，`execute` 执行带 rollback receipt 的资源事务，`changes` 只传递事实事件，不直接改变 runtime 状态。生产使用系统 HAL adapter，测试使用 scripted adapter。

### 4.4 TBAudioHALCallbackBridge.mm

最终只保留：

- `CaptureIOProc` 和 `OutputIOProc`；
- `AudioBufferList` 与不可变 format contract 的严格匹配；
- callback lease acquire/release/detach；
- 将 buffer view 和时间戳转发给 opaque C++ kernel；
- contract 不匹配时清零并递增 fatal counter。

不再保存 route 字典、quarantine 数组、retirement epoch 或 HAL 生命周期状态。

### 4.5 TBAudioRealtimeKernel

C++ kernel 按 realization generation 预创建，包含：

- source capture adapters；
- 预分配 ring；
- sample type/layout conversion；
- channel mapping/downmix；
- 真正的 sample-rate converter；
- source gain、mute envelope、crossfade 和 mix；
- generation fencing；
- 原子 diagnostics。

控制线程 constructor/configuration 可以分配。`pushCapture` 与 `renderOutput` 必须 `noexcept`、无锁、无分配。

## 5. Realization 身份

是否重建不能只取决于 `AudioRoutePlan` 或 device configuration generation。

```text
RealizationKey =
    desired graph fingerprint
  + process-device fingerprint
  + output device stream ASBD
  + Tap ASBD
  + Aggregate input stream ASBD
  + audio-server generation
```

相同用户配置下，只要应用内部换源导致任一观察指纹变化，旧 realization 就失效。

不变量：

- 相同 intent 和相同 HAL fingerprint 必须幂等返回 unchanged；
- 相同 intent 但 HAL fingerprint 改变必须重新 realize；
- 每个 active realization 绑定不可变 format contract；
- 任何送入 mix 的 PCM 都必须属于当前 generation，并满足该 contract；
- `.applied` 只表示 candidate 已完整提交；不允许未说明的半应用状态。

## 6. 四层防线

### 6.1 第一层：动态拓扑与格式观察

持续监听：

- `kAudioProcessPropertyDevices`；
- `kAudioTapPropertyFormat`；
- Aggregate input stream 的 `kAudioStreamPropertyVirtualFormat`；
- output device alive、streams、nominal sample rate 和 stream virtual format；
- audio-server generation。

监听事件先合并，再生成不可变 `HALObservationSnapshot`。

事件分类：

| 变化 | 动作 |
|---|---|
| process device、Tap ASBD、Aggregate ASBD、output ASBD、server generation | 硬失效，静音并重建受影响 source/route |
| gain | 原子参数快路径 |
| 无关设备 | 忽略 |
| 重复通知 | 合并为一次 converge |

### 6.2 第二层：稳定工作格式

每条 output route 使用固定 canonical format：

```text
Float32
non-interleaved
stereo
sample rate = current output nominal rate
```

每个 source 在启动前生成不可变 `AudioFormatContract`：

```text
actual Tap ASBD
  -> sample type/layout adapter
  -> channel mapping
  -> sample-rate converter
  -> canonical route format
```

首版支持策略：

- mono 复制到左右声道；
- stereo interleaved/non-interleaved 均转换为 canonical；
- 44.1、48 和 96 kHz 使用真实 SRC；
- multichannel 只有存在明确 downmix matrix 时才支持；
- 未知 sample type、变长包或运行中 ASBD 突变立即输出零并触发重建。

SRC、buffer、channel map 和 converter state 均在控制线程创建、预热和预分配。不得在 IOProc 中创建、reset 或修改 converter property。

优先使用系统级、已验证的 SRC 实现。进入默认路径前必须证明稳态 callback 不产生分配，并通过第 10 节的质量 Gate；不能通过时保持 fail closed，不用 ring drift correction 代替 SRC。

### 6.3 第三层：事务化生命周期

每个 source 使用以下状态：

```text
absent -> preparing -> prerolling -> active
active -> muting -> rebuilding -> active
preparing/rebuilding -> rollback -> old realization | failClosed
active -> muting -> detached -> drainingCallbacks -> retired
```

重建事务：

1. 旧 kernel 开始短 mute ramp；
2. 控制线程准备 candidate Tap、Aggregate、contract、SRC、ring 和 lease；
3. candidate capture 进行有界 preroll；
4. candidate 可输出后原子提交新 generation；
5. 新 realization fade in；
6. detach 旧 callback target；
7. 等待 in-flight callback 清零；
8. 安全停止 IOProc，并销毁 Aggregate、Tap 和 kernel；
9. 失败时撤销 candidate。旧 realization 格式仍安全才允许恢复，否则释放 Tap 并 fail closed，让应用回到原始输出路径。

只有 HAL 允许旧、新 capture realization 同时存在时才使用 make-before-break。若同一进程或设备组合不允许并存，则安全降级为：旧 realization 10 ms fade-to-zero、detach 并停止旧 capture、创建和 preroll candidate、再用 10 ms fade-in。该路径允许短静音，不允许输出旧格式 PCM。

一个 source 的重建不能中断同 route 的 sibling source。

### 6.4 第四层：健康与听感保护

C++ 只记录原子计数和执行实时保护。Swift 按时间窗口分析指标增量。

立即重建或 fail closed：

- callback buffer/layout 与 contract 不符；
- non-finite 输入持续出现；
- capture/output callback 停滞；
- process-device 或 ASBD fingerprint 改变；
- 旧 generation callback 到达。

先进入 degraded，再按恢复预算处理：

- underrun、overrun 或 forced resync 在窗口内暴增；
- ring 长期偏离目标水位；
- IO 周期或 sample time 不连续。

只记录，不错误重建：

- 高于 100% gain 产生的 clipping；
- 单次 underrun；
- 合法静音或暂时没有捕获数据。

听感策略：

- 设备变化先 mute，再重建；
- 启动、恢复和切换都使用短 ramp/crossfade；
- resync 后丢弃陈旧帧，不慢速追赶旧音频；
- 异常 source 输出零，坏 PCM 不进入共享 mix；
- 重建使用 per-route 退避和重试预算，避免无限循环。

初始健康策略采用现有 250 ms watchdog cadence：

| 信号 | 初始判定 | 动作 |
|---|---|---|
| callback/ABL format mismatch | 任意一次 | source 立即 mute，触发硬重建 |
| process-device、ASBD 或 server generation 变化 | 任意一次确认后的新 fingerprint | 受影响 realization 立即失效 |
| 已 active 的 capture 或 output 无 frame 增量 | 连续 2 个 tick（500 ms） | degraded 并重建 |
| non-finite input | 连续 2 个 tick 均有新增 | source mute 并重建 |
| forced resync | 1 秒内新增至少 2 次 | degraded；连续两个窗口则重建 |
| underrun/overrun | 单个 tick 超过 2 个 output period 的帧数 | degraded；连续两个窗口则重建 |
| clipping | 只记录比例 | 不触发 route 重建 |

每个 route 在 30 秒窗口内最多自动重建 3 次，退避为 250 ms、1 秒、4 秒。耗尽预算后释放对应 Tap 并进入 fail closed；只有新的用户 intent、HAL fingerprint 或 audio-server generation 才能重置预算。阈值只能依据确定性测试和真机数据调整，并同步更新本文档。

## 7. 错误语义

内部错误必须结构化，至少保留：

```swift
enum AudioRuntimeFailure: Error, Sendable {
    case invalidIntent(String)
    case objectUnavailable(kind: HALObjectKind, id: UInt32)
    case unsupportedFormat(routeID: String, observed: AudioFormatFingerprint)
    case prepareFailed(routeID: String, stage: HALStage, status: OSStatus)
    case commitFailed(
        routeID: String,
        stage: HALStage,
        status: OSStatus,
        rollbackSucceeded: Bool
    )
    case cleanupDeferred(routeID: String, resources: [HALResourceKind])
    case audioServerRestarted
}
```

adapter 可以把错误映射为现有 apply status，但 diagnostics 必须保留 route、source、stage、OSStatus、expected/observed format fingerprint、retry count 和 rollback 结果。禁止只返回字符串或吞掉 teardown 错误。

## 8. 文件落点

新增 Swift：

```text
Sources/ToolBox/AudioRouting/AudioRouteRuntime.swift
Sources/ToolBox/AudioRouting/SwiftAudioRouteEngineAdapter.swift
Sources/ToolBox/AudioRouting/CoreAudioHAL.swift
Sources/ToolBox/AudioRouting/AudioFormatContract.swift
Sources/ToolBox/AudioRouting/AudioRouteRecoveryPolicy.swift
Sources/ToolBox/AudioRouting/AudioRouteHealthEvaluator.swift
Sources/ToolBox/AudioRouting/AudioRouteRuntimeModels.swift
```

收缩或替换：

```text
Sources/ToolBox/AudioRouting/AudioRouteEngine.mm
Sources/ToolBox/AudioRouting/AudioRouteEngine.h
Sources/ToolBox/AudioRouting/AudioRouteRealtime.cpp
Sources/ToolBox/AudioRouting/AudioRouteRealtime.hpp
Sources/ToolBox/AudioRouting/AudioRouteCallbackLease.cpp
Sources/ToolBox/AudioRouting/AudioRouteCallbackLease.hpp
Sources/ToolBox/AudioRouting/AudioRouteDSP.cpp
Sources/ToolBox/AudioRouting/AudioRouteDSP.hpp
Sources/ToolBox/AudioRouting/AudioRouteFormat.cpp
Sources/ToolBox/AudioRouting/AudioRouteFormat.hpp
```

测试文件按现有命名扩展，不为测试把内部 HAL seam 暴露到产品 interface。

## 9. 迁移阶段

| 阶段 | 内容 | 完成 Gate |
|---|---|---|
| 0. Characterization | 固化 route diff、gain、teardown、server restart、diagnostics；加入动态格式失败测试 | 现有测试通过，新测试能够证明旧缺陷 |
| 1. Realtime seam | opaque C interface；callback、lease、ring、mix、计数进入 kernel | PCM 与旧行为一致；ASan/TSan、detach race 和无分配约束通过 |
| 2. Swift runtime skeleton | adapter、完整 desired state、typed errors、scripted HAL | 幂等、stale generation、rollback、cleanup 测试通过 |
| 3. HAL lifecycle | 查询、Tap、Aggregate、IOProc 编排和 listener 迁到 Swift | 旧 ObjC++ 生命周期删除；100 次 start/stop 资源归零 |
| 4. Format defense | format contract、layout/channel adapter、真实 SRC | 44.1/48/96 kHz 与 interleaved/non-interleaved 通过 |
| 5. Transactional rebuild | candidate、preroll、mute、commit、drain、source retirement | 失败保留旧 route；sibling source 不受影响 |
| 6. Health recovery | 指标窗口、degraded、退避、自动 converge、fail closed | callback 活跃但 PCM 损坏时可检测并恢复 |
| 7. Legacy removal | 删除旧 RouteContext 生命周期和重复校验 | `.mm` 只剩 callback bridge，无双轨实现 |

每一阶段都必须删除被替代的旧实现，禁止长期通过 feature flag 维持两套 engine。

## 10. 验收 Gate

### 10.1 格式与拓扑

- 44.1 -> 48 -> 96 -> 44.1 kHz 连续切换无持续噪声；
- mono、stereo、interleaved、non-interleaved 不发生错误强转；
- 主进程/helper 与 process output device 变化可局部重建；
- format fatal 后立即静音，最迟一个 watchdog 周期进入恢复；
- 重建失败恢复安全旧 realization，或释放 Tap 后 fail closed；不得永久静音。

### 10.2 生命周期与实时安全

- 100 次真实设备切换和 1,000 次 synthetic rebuild 后资源回到基线；
- callback 内无 Swift、分配、锁、日志或 Objective-C 消息；
- 旧 generation callback 只能输出零，不能访问新 realization 或已释放资源；
- ASan、TSan、callback detach race 和 retirement tests 通过。

### 10.3 音质与性能

- SRC SNR >= 90 dB；
- THD+N <= -90 dB；
- 20 Hz-18 kHz ripple <= 0.1 dB；
- alias <= -80 dBFS；
- unity path 幅值误差不超过 `1e-6`；
- 内建/USB 48 kHz 稳态额外延迟 p95 <= 50 ms，目标 <= 35 ms；
- 单 route CPU p95 <= 5%，四 route <= 15%；
- 8 小时连续播放无持续 underrun、重建风暴或内存单调增长。

### 10.4 真机矩阵

必须覆盖内建输出、USB、HDMI、蓝牙 profile/rate 变化、设备拔插、睡眠唤醒、主进程/helper 迁移，以及至少一个能够稳定触发应用内多音源切换的真实软件。

自动化测试不能替代真机结果。

## 11. 非目标

- 不复制或依赖 SoundSource 私有实现；
- 不新增虚拟驱动、输入路由或虚拟麦克风；
- 不重构规则层、设置 UI 或音量交互；
- 不用扩大 ring、提高 drift correction 或 hard clamp 掩盖格式错误；
- 不把内部 HAL port 暴露为新的产品 interface；
- 不为追求全 Swift 让 Swift 进入硬实时 callback。

## 12. 证据与文档关系

SoundSource 技巧和 ToolBox 当前断点的证据分级见：

- `docs/research/soundsource-runtime-resilience-comparison.md`
- `docs/research/soundsource-vs-toolbox-audio-diagnosis.md`
- `docs/superpowers/plans/2026-07-22-per-app-audio-reliability-quality-compatibility.md`

Core Audio Process Tap、Tap format、process devices 和 stream virtual format 的语义以当前 Xcode SDK 的 `AudioHardwareTapping.h`、`AudioHardware.h` 和 `AudioHardwareBase.h` 为准。Context7 当前未返回相关 Core Audio 条目，因此不使用其无关结果替代 Apple SDK 头文件。
