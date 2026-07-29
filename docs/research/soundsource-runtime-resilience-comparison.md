# SoundSource 与 ToolBox 动态音源切换健壮性对比

日期：2026-07-29
对象：SoundSource 6.0.6、当前工作树中的 ToolBox per-app audio routing

## 结论

用户描述的“某些软件播放时突然变成电流声，多切换几次应用内音源后恢复”，最符合下面这条故障链：

1. 应用切换内部播放器、helper、输出设备或内容后，进程关联设备、Tap 格式或采样率发生变化；
2. ToolBox 的既有 route 没有可靠重建，实时回调仍按启动时的 Float32 stereo 和采样率解释输入；
3. 44.1 kHz 与 48 kHz 的差异远超当前 ring buffer 约 0.1% 的漂移修正能力，或者不同 sample type 的位模式被当作 Float32；
4. 回调仍在前进，因此 watchdog 认为 route 存活；持续 underrun、resync、clipping 或错误样本最终听成电流声；
5. 再切几次音源后，格式碰巧回到旧 route 的假设，或进程/设备刷新最终触发重建，于是恢复。

SoundSource 的关键差异不是“多重试几次”，而是四层防线：

- 把捕获格式转换成稳定的内部工作格式，而不是假设输入格式永远不变；
- 持续跟踪 player、进程与设备关系，并为每个设备维护可更新、可失效的 IO context；
- 监测采样率、时钟与 IO 连续性，变化时 passivate/reset/rebuild Tap；
- 在设备切换期先静音，并平滑恢复音量，避免重建过程产生爆音或残留脏数据。

因此，ToolBox 当前最应先解决的是“变化没有导致重建”和“没有真实格式转换”两件事，而不是增加更激进的 ring buffer 漂移补偿。

## 证据分级

| 等级 | 含义 | 本文用法 |
|---|---|---|
| A：官方/源码 | Apple SDK 头文件或 ToolBox 源码可直接确认 | 用于说明 API 语义与 ToolBox 实际行为 |
| B：二进制直接证据 | SoundSource/ACP/SSAudio 可执行文件中的导出符号、selector 或日志字符串 | 用于确认产品包含对应机制，但不声称完整控制流已还原 |
| C：逆向笔记 | `/Users/youtonghy/Downloads/break/SoundSource/*.md` 中的类结构和伪代码 | 用于解释可能的内部数据流；属于高可信逆向推断，不等同官方源码 |

注意：逆向笔记把 Core Audio Process Tap 的可用版本写成 macOS 12.3+，但当前 Xcode SDK 的 `AudioHardwareTapping.h` 标注为 macOS 14.2+。本文以 SDK 为准，并不把笔记视为官方文档。

## 横向对比

| 维度 | SoundSource 6.0.6 | ToolBox 当前实现 | 对本故障的影响 |
|---|---|---|---|
| 捕获格式契约 | `ACPTapConfig` / `ACPTapIOContextConfig` 显式携带 channel、frameCount、sampleRate；`ACPTapIOConverter` 桥接 context 与工作格式（C） | 启动时校验 capture/output ASBD，之后 callback 直接假设单 buffer、双声道、interleaved Float32（A） | ToolBox 可在运行中 ASBD 变化后误读数据 |
| 采样率转换 | 二进制存在 `ACPTapIOConverter`；逆向伪代码显示双向 `raesampler`、preroll 和残余帧缓冲（B/C） | ring 只做约 +/-1000 ppm 的微小速率修正，没有 44.1/48 kHz SRC（A） | ToolBox 无法吸收真正的采样率切换 |
| 采样率变化恢复 | ACP 字符串包含 `Forcing reset due to ... sample rate change`、`Passivating due to sample rate change`；主程序包含 `SampleRateChanged`、`rebuildAll`（B） | 设备格式有 listener，但 route generation 的发布条件会漏掉“格式变化同时 UI model 也变化”的情况（A） | 旧 route 可能继续运行；这是当前最高置信度回归 |
| Tap 生命周期 | ACP 存在 `resetTaps`、`_createTaps`、`_destroyTaps`、`invalidate`；SSAudio 有 `onDidInvalidate`、`updateWithConfig:`（B） | controller 可 stop/recreate 整条 route，但没有 Tap/aggregate 运行时格式 listener（A） | ToolBox 恢复动作更粗，而且可能根本未被触发 |
| 进程与设备迁移 | 逆向材料显示 `device.players` 观察、`activeDevices`/`hoggingDevices` 和每设备 `SSTap` context（B/C） | route 启动时只读一次 `kAudioProcessPropertyDevices`；process registry 只监听 running/runningOutput（A） | 应用内部切源或 helper 迁移后 Tap 可能仍固定在旧设备 |
| 连续性诊断 | ACP 二进制含 `IO cycle missed`、`Timer clock discontinuity`、`IO deadline missed`（B） | 已计数 underrun、overrun、forcedResync、non-finite、clipped，但 watchdog 主要看 callback/frame 是否推进（A） | PCM 已坏但回调仍活跃时，ToolBox 不会自愈 |
| 重建瞬态 | SSAudio 导出 `beginDeviceChangeMuting`；存在 10 ms volume smoother（B/C） | 有 gain ramp、underrun fade，但没有包围整个设备重配置的明确静音状态（A） | ToolBox 的切换过程更容易暴露爆音/旧缓冲 |
| 故障隔离 | 每设备/进程 IO context 可独立失效更新；配置模型显式分离（C） | 多 source 共享一条 output route；单 source mismatch 被静音但 route 仍可标 active（A） | 一个 source 的坏状态可能长期留在共享 route 中 |

## SoundSource 如何处理这类变化

### 1. 稳定工作格式，而非透传设备假设

逆向材料中的 `ACPTapIOConverter` 同时持有：

- context frame count / sample rate；
- converted frame count / sample rate；
- channel map；
- 输入、输出两个 resampler；
- 可保留重采样尾部的内部 buffer。

当采样率相同时，它按 channel stride 拷贝；不同时则通过 `raesampler` 转换，并在创建时 preroll，降低初始化瞬态。这样上层处理回调面对的是稳定格式，设备侧变化不会直接变成错误 PCM。

SoundSource 二进制能够直接确认 `ACPTapIOConverter` 类和两个 `raesampler_t` 状态存在；具体算法顺序来自逆向伪代码，因此不能把缓冲长度等细节当作官方保证。

### 2. 变化被建模为 context 生命周期事件

SoundSource 并非把 Tap 当成“一次创建、永久有效”的资源。可见接口包括：

- `updateWithConfig:`；
- `onWillStart` / `onDidStop` / `onDidInvalidate`；
- `resetTaps` / `_createTaps` / `_destroyTaps`；
- 每设备 `deviceTaps` 和 `device.players` 观察。

因此，当 player 集合、目标进程、设备或格式变化时，它有明确的位置更新配置、失效旧 context 并创建新 Tap，而不需要让已经不匹配的 callback 无限运行。

### 3. 采样率变化属于必须重置的状态变化

ACP 二进制中的日志模板直接表明两种行为：

- 采样率变化导致 passivate；
- 某类采样率变化导致 forcing reset。

SoundSource 主程序还包含采样率变化通知、`rebuildAll` 和 macOS Tahoe sample-rate compatibility 标记。能确认的是“产品显式处理采样率变化并具有重建路径”；仅凭字符串不能还原所有触发条件或版本分支。

### 4. 检测时间轴异常，而不只检测线程是否还活着

ACP 会记录 IO cycle missed、clock discontinuity 和 IO deadline missed。逆向笔记还显示 IO 周期包含序列号校验。这里的设计重点是：

- callback 运行不代表 PCM 正确；
- 时间戳、周期序列、格式和采样率共同定义 route 是否健康；
- 一旦这些状态破坏，需要重置转换器或 context，而不是继续输出错误数据。

### 5. 重建期间控制听感

`SSAudio.framework` 导出了 `beginDeviceChangeMuting`，逆向材料还显示音量使用约 10 ms 的 smoother。由此可确认 SoundSource 把“设备重配置”和“用户可听到的过渡”分开处理：先隔离不稳定窗口，再平滑恢复。

`AHRADeclickNode` 虽然存在，但它属于通用处理图节点，现有证据不足以证明它负责修复本次电流声，不能把它当作主要答案。

## ToolBox 的具体断点

### P0：route generation 会漏发

`AudioDeviceRegistry.apply` 同时计算 `routeConfigurationChanged` 和 `publishedModelChanged`，但当前只有在 `!publishedModelChanged` 时才递增 `routeGeneration`。采样率/ASBD 改变通常也会改变发布给 UI 的 model，于是恰好被这条条件挡住。

随后虽然普通 snapshot 更新会触发 reconcile，但 `AudioRoutePlan` 不包含 sample rate/ASBD；同 UID、同 process IDs、同 generation 的 plan 会被 controller 判为 unchanged。Engine 又只在 start 时校验格式，旧 IOProc/Tap/aggregate 因此继续运行。

这条链条能够最好地解释“多切几次后来恢复”：当内容再次切回旧采样率时，旧 route 的假设重新成立。

### P0：健康检查只覆盖活性，不覆盖音频质量

ToolBox 已经采集以下指标：

- underrun / overrun；
- forced resync；
- format mismatch；
- non-finite sample；
- clipped sample。

但 watchdog 的关键判断仍是 capture/output frame 是否推进和 fatal mismatch。持续输出坏 PCM 时，callback 仍能推进，route 因而可长期保持 active。

### P1：没有追踪 process-device 和 Tap 格式的运行时变化

Apple 的 `kAudioProcessPropertyDevices` 正是进程当前正在使用的输入/输出设备列表；scope 区分方向。ToolBox 启动 route 时查询一次，但 `AudioProcessRegistry` 没有为该属性注册 listener。

Apple 同时公开 `kAudioTapPropertyFormat`，其值是 Tap 当前可用于 aggregate device 的 ASBD。ToolBox 没有监听 Tap format 或 private aggregate input stream virtual format，因此无法在 callback 解释方式已经失效时主动重建。

### P1：把微小时钟漂移当成了格式转换

现有 occupancy correction 上限约 0.1%，适合处理独立时钟的小漂移，不是 sample-rate converter。44.1 kHz 到 48 kHz 相差约 8.84%，继续扩大补偿上限只会产生明显变调或不稳定，不应作为修复方向。

## 建议顺序

1. **先修重建触发链**：任何 route signature 的 sample rate、stream ID、ASBD 变化都必须推进 generation；补一条“UI model 同时变化仍重建”的回归测试。
2. **让质量指标参与恢复**：用指标增量和时间窗口判断 route degraded；先静音，随后限频重建，避免重建风暴。
3. **监听动态关联**：监听每个活跃 process 的 `kAudioProcessPropertyDevices`，以及 Tap/aggregate 的运行时格式；只重建受影响 route。
4. **引入真实的格式归一化层**：把 capture 的实际 ASBD 转成统一内部工作格式，至少覆盖 44.1/48 kHz、mono/stereo、interleaved/non-interleaved；ring buffer 继续只负责缓冲和微漂移。
5. **增加设备切换静音状态**：重配置时停止向旧 route 取样，清空或代际隔离旧 buffer，再用短 ramp 恢复。
6. **最后再做隔离深化**：把 source context 的 format/lifecycle 独立化，避免一个 source 的坏格式长期污染共享 route 的健康状态。

不建议复制 SoundSource 的 ACE/ecaudiod 私有驱动架构。ToolBox 已使用 Apple 公开的 Process Tap；真正值得借鉴的是状态模型、转换边界、失效/重建策略和诊断闭环。

## 建议验收矩阵

需要真实应用或可控音频客户端覆盖以下转换，并在每次转换后检查输出、ASBD 与诊断计数：

| 变化 | 预期 |
|---|---|
| 44.1 kHz -> 48 kHz -> 44.1 kHz | 无持续噪声；转换或受控重建后恢复 |
| stereo -> mono -> stereo | 正确映射或明确静音并重建，不能误读 buffer |
| interleaved -> non-interleaved | 正确转换或拒绝并恢复，不能按错误布局强转 |
| 主进程 -> helper process | 自动更新捕获对象，不依赖用户反复切源 |
| process output device A -> B | 监听关联变化，只重建受影响 route |
| output device profile/rate change | generation 必须推进；旧 callback 不再读写新代际资源 |
| callback 继续但 clipping/resync 激增 | route 进入 degraded 并执行限频恢复 |

最有区分度的真机证据是：故障发生时同时记录 process device IDs、tap/aggregate ASBD、route generation，以及 diagnostics 的增量。若强制一次 route rebuild 立即恢复，基本可确认 stale route/format，而非源文件本身损坏。

## 证据来源

### Apple 官方（A）

- Xcode SDK `CoreAudio.framework/Headers/AudioHardwareTapping.h`：`AudioHardwareCreateProcessTap` 可用性为 macOS 14.2。
- Xcode SDK `CoreAudio.framework/Headers/AudioHardware.h`：`kAudioProcessPropertyDevices`、`kAudioTapPropertyFormat`、`kAudioAggregateDeviceTapAutoStartKey`。
- Xcode SDK `CoreAudio.framework/Headers/AudioHardwareBase.h`：`kAudioStreamPropertyVirtualFormat`。
- Apple Developer Documentation：[Capturing system audio with Core Audio taps](https://developer.apple.com/documentation/coreaudio/capturing-system-audio-with-core-audio-taps)。

### SoundSource 二进制（B）

- `/Users/youtonghy/Downloads/break/SoundSource.app/Contents/MacOS/SoundSource`
- `/Users/youtonghy/Downloads/break/SoundSource.app/Contents/Frameworks/ACP.framework/Versions/A/ACP`
- `/Users/youtonghy/Downloads/break/SoundSource.app/Contents/Frameworks/SSAudio.framework/Versions/A/SSAudio`

主要核对命令：

```sh
strings -a SoundSource.app/Contents/Frameworks/ACP.framework/Versions/A/ACP
nm -gU SoundSource.app/Contents/Frameworks/ACP.framework/Versions/A/ACP
nm -gU SoundSource.app/Contents/Frameworks/SSAudio.framework/Versions/A/SSAudio
strings -a SoundSource.app/Contents/MacOS/SoundSource
```

### 逆向材料（C）

- `/Users/youtonghy/Downloads/break/SoundSource/README.md`
- `/Users/youtonghy/Downloads/break/SoundSource/02-程序架构设计.md`
- `/Users/youtonghy/Downloads/break/SoundSource/03-代码逻辑伪代码.md`
- `/Users/youtonghy/Downloads/break/SoundSource/04-调用接口APIs.md`
- `docs/research/soundsource-vs-toolbox-audio-diagnosis.md`

### ToolBox 源码（A）

- `Sources/ToolBox/AudioRouting/AudioDeviceRegistry.swift`
- `Sources/ToolBox/AudioRouting/AudioProcessRegistry.swift`
- `Sources/ToolBox/AudioRouting/AudioRouteEngine.mm`
- `Sources/ToolBox/AudioRouting/AudioRouteRealtime.cpp`
- `Sources/ToolBox/AudioRouting/AudioRouteController.swift`
- `Sources/ToolBox/AudioRouting/AudioRoutingService.swift`
- `Sources/ToolBox/AudioRouting/AudioRoutingModels.swift`

## 限制

- SoundSource 是闭源软件。本文可证明二进制包含相应类、selector 和日志路径，但不能仅凭符号证明每个分支在本次故障中必然执行。
- 逆向笔记中的数据流和伪代码未经官方确认，已与二进制交叉核对，但仍应视为推断。
- 本轮没有对 SoundSource 或 ToolBox 做运行时注入、动态跟踪，也没有录到发生电流声当刻的 ASBD/设备/计数快照。
- 本轮只做横向研究，没有修改 ToolBox 音频实现。
