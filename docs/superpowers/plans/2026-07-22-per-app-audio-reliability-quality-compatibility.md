# 分应用音频稳定性、音质与兼容性优化实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在保留现有公开 Core Audio Process Tap 输出架构的前提下，把分应用输出音量和输出设备路由提升到可观测、可恢复、低延迟、可判定兼容的生产级状态。

**Architecture:** 输出链继续使用“每个逻辑应用一个 private Process Tap + tap-only capture Aggregate + 每个物理输出设备一个独立 output IOProc”，不把全双工物理设备放进 capture Aggregate。控制面通过一个可注入的深模块串行协调 HAL 生命周期、route-level diff、运行时参数和诊断；实时面只使用预分配存储、原子状态和无锁 DSP。产品 schema、服务和 UI 均不增加分应用输入能力。

**Tech Stack:** Swift 5、SwiftUI、Combine、Objective-C++/C++、Core Audio HAL、Process Tap、AudioConverter/Accelerate（通过门控后使用）、XCTest、XcodeGen、GitHub Actions。

## 计划状态

- 本文面向当前工作区中的未提交分应用音频实现，不假设这些文件已经合并到 `main`。
- 本文只规划后续优化；现有 [初版实施计划](2026-07-21-per-app-audio-routing.md) 继续作为已完成骨架的记录。
- 执行必须按 Gate 顺序推进。P0 稳定性未通过时，不开始 SRC 或峰值保护。
- 本计划和产品范围仅包含输出音量与输出设备。分应用输入不进入规则 schema、服务、UI、构建或发布声明。

### 2026-07-22 执行进度

- Task 1 已完成：可注入 controller/fake registries、typed compilation、generation 防陈旧结果、重复规则规范化和 gain-only runtime path 已落地。
- Task 2 已完成自动化部分：native diagnostics 与 watchdog 已落地，只有 capture/output 都前进才进入 `active`，fatal mismatch 会在一个 watchdog tick 内停止路由。
- Task 3 已完成自动化 P0 切片：拓扑变化改为 route-level diff；watchdog 只摘除失败 route；输出先启动，正常 teardown 先用 10 ms source ramp 静音并等待 12 ms，再停止 capture；HAL 原始 `clientData` 使用单原子 detach/readers 状态和 65,536-slot 固定 arena，50,000 次 acquire/detach race 与退休循环覆盖延迟回调拒绝；`coreaudiod` 重启不直接 delete 旧指针；进程/设备通知分别合并且只监听必要对象。真实 HAL fault injection 与真机重启仍未完成。
- Task 4 已完成边界切片：ring/drift/resync 已抽到独立 C++ 模块；水位按 buffer/latency/safety offset 推导并限于 `256...2048` frames；覆盖 10,000 次回绕、full/empty、overrun、underrun 淡入和非有限样本。24 小时等效随机漂移仿真和实机 p95 延迟测量仍未完成。
- Task 5 部分完成：非有限 gain/input/output 均 fail closed，最终 hard clamp 与精确 10 ms gain ramp 已落地；正常 teardown 复用 source ramp 并等待 12 ms。独立的设备切换 envelope、limiter 候选和硬件音质测量尚未完成。
- Task 6 完成首版 fail-closed 预检：Swift 设备快照与 native engine 共用格式和 `+/-1000 ppm` 采样率判定，设置页禁用不兼容或非 alive 设备并显示原因；同 UID 的 alive/格式/rate/profile 变化会推进 generation 并重建。non-interleaved、mono/multichannel 和 SRC adapter 仍未实现。
- Task 9 完成写入切片：gain target 立即更新，规则持久化延迟合并，并在 stop/shutdown 强制刷新；详细诊断复制和 clipping UI 尚未实现。
- Task 10 已加入本地/CI 验证脚本及真机验收矩阵；当前全量 XCTest 151 项、ASan 16 项、TSan 12 项以及 Debug/Release 构建均通过。矩阵结果、Developer ID/notarization 与多系统实机行仍未完成。

## 1. 路线选择

采用 Process Tap-only 输出路线：支持 `0...300%` 分应用音量和按稳定 UID 选择输出设备，不改变系统默认输出，不提供或暗示分应用输入能力。虚拟音频驱动、Audio Server Plug-in、输入 broker 和 `inputDeviceUID` 均不属于本计划。

## 2. 当前基线与缺口

| 能力 | 当前状态 | 主要缺口 |
|---|---|---|
| `0...300%` 规则、bundle ID/device UID 持久化 | 已完成 | gain 立即更新，持久化已合并并在停止时刷新 |
| Process/Device Registry | 已完成骨架 | 已合并事件、过滤无关设备并在单对象读取失败时保留其余快照；能力快照仍缺完整声道、transport、可用 rate range 和 hog mode |
| RoutePlanCompiler | typed 结果已完成 | 短暂停播仍会反复重建；逻辑应用/helper 分组未完成 |
| Tap-only capture + 独立物理 sink | 已完成但缺真机证据 | callback/frames/格式异常已可见；TCC 与合法静音仍无法由公开 API 精确区分 |
| 实时 ring、漂移微调、硬限制 | P0 切片已完成 | 已采用动态水位与高水位 resync；缺长时随机仿真、跨采样率和实机延迟证据 |
| 生命周期恢复 | P0 切片已完成 | route diff、output-first start、渐隐后 capture-first stop、固定 callback lease arena 和 generation retirement 已落地；缺 HAL fault harness 与真机 `coreaudiod` 重启证明 |
| 音质 | 部分完成 | 已有非有限清理和 10 ms gain ramp；300% 仍仅 hard clamp，无 RMS/peak UI 或 limiter 质量数据 |
| 格式兼容 | 首版预检已完成 | Swift/native 共用判定；仅同采样率、单 stream、interleaved packed Float32 stereo |
| 应用兼容 | 基础 bundle ID | 没有 CapturePolicy、精确 app group、macOS 26 bundle ID tap 路径 |
| 自动化测试 | 全量 XCTest 151 项、ASan 子集 16 项、TSan 子集 12 项，当前实跑通过 | 缺真实 HAL fault、长时并发/SRC、UI 自动化和硬件矩阵；全仓测试不能替代真机证据 |
| 发布产物 | Debug/Release strict codesign 当前可通过 | Release 当前是 ad-hoc、arm64 thin；尚未证明 Intel、Developer ID、notarization 或真实分发 TCC |

## 3. 全局约束

1. 项目 deployment target 保持 macOS 14.0；Process Tap 只在 macOS 14.2+ 启用。
2. 输出链只使用公开 Core Audio API，不加入私有 SPI，不改变系统默认输出设备。
3. 保留 tap-only capture Aggregate + 独立 physical sink。外部参考中的“真实输出设备作为同一 Aggregate main subdevice”不进入正式实现，除非另有隔离原型证明其在全双工、多 stream、多声道设备上更安全。
4. 持久化只保存 bundle ID 和 device UID；PID、AudioObjectID、Tap ID、Aggregate ID、stream ID 和 client ID 都是当前 HAL generation 的瞬态值。
5. IOProc 中禁止分配、锁、日志、Objective-C/Swift 消息、UserDefaults、Combine、同步 dispatch 和转换器首次初始化。
6. 任何不支持的格式或 fatal callback 状态都 fail closed：先停止读取 Tap，让原应用恢复原始输出，再回收其余资源。
7. `active` 表示 capture 和 output 都实际处理过 frame；不能仅依据 Core Audio 创建/启动返回 `noErr`。
8. TCC 没有可靠公开 preflight。零数据只能显示“权限、受保护内容或当前无可捕获音频”，不得伪装成确定的权限结论。
9. 不新增输入规则、虚拟麦克风、输入 broker、驱动安装路径或麦克风权限文案。
10. 所有共享 interface、规则 schema、Xcode target、签名和安装变更由主代理串行集成；读代码和测试矩阵可并行审阅。

## 4. 目标架构

```text
SwiftUI
  -> AudioRoutingService (@MainActor, UI facade)
       -> RuleStore / ProcessRegistry / DeviceRegistry
       -> RoutePlanCompiler (pure, returns plans + typed rejections)
       -> AudioRouteController actor
            -> NativeAudioRouteEngine adapter
                 -> AppSource: one Process Tap for one logical app
                 -> tap-only capture Aggregate
                 -> preallocated realtime source pipeline
                 -> one output sink per physical output device
            -> diagnostics watchdog + generation retirement
```

### 深模块 interface

`AudioRoutingService` 不再了解 Tap/Aggregate 的创建顺序。它只提交 desired state 并接收结果：

```swift
protocol AudioRouteEngineControlling: Sendable {
    func reconcile(plans: [AudioRoutePlan], generation: UInt64) async -> AudioRouteApplyReport
    func update(parameters: [AudioRouteRuntimeParameters]) async -> AudioRouteApplyReport
    func diagnostics() async -> [AudioRouteDiagnosticsSnapshot]
    func stopAll(reason: AudioRouteStopReason) async -> AudioRouteStopReport
}
```

该 interface 同时是生产 adapter 和 fake adapter 的测试 seam。Tap、Aggregate、IOProc、ring、fade、limiter 和 quarantine 都隐藏在 native adapter 内，不为 UI 暴露浅层控制方法。

### 计划与运行参数分离

- `AudioRoutePlan`：逻辑应用身份、Process Object ID 集合或 macOS 26 bundle ID、目标输出 UID、格式 adapter。变化需要 reconcile。
- `AudioRouteRuntimeParameters`：target gain、mute、output envelope、峰值保护开关。变化只更新原子值。
- `AudioRouteDiagnosticsSnapshot`：frame/callback、最后 host time、ring 水位、under/overrun、resync、format mismatch、non-finite、limited/clipped sample、当前 generation。
- `AudioRuleResolution`：每条规则的 `planned/waiting/degraded/rejected` 和 typed reason。UI 文案由 Swift 层映射。

## 5. 量化验收门槛

| 维度 | Gate |
|---|---|
| 故障安全 | 正常停止、设备拔出、格式变化、route 创建失败后 1 秒内停止读取对应 Tap；不得出现永久静音 |
| 状态真实性 | capture/output 尚未产生 frame 时不能为 `active`；fatal format flag 在下一次 250 ms watchdog tick 内触发 teardown |
| 资源生命周期 | 100 次 start/stop、设备切换或模拟 generation rebuild 后 Tap/Aggregate/context 数回到基线；无单调内存增长 |
| 延迟 | 内建/USB 48 kHz 稳态额外输出延迟发布门为 p95 <=50 ms，优化目标 <=35 ms；启动缓冲不能固定为 4096 frames |
| 长测 | 参考 Apple Silicon 机器 8 小时连续播放无崩溃、永久静音、dropped frame 或持续过载；warmup 后支持设备上无 underrun |
| CPU/内存 | 单 route CPU p95 <=5%，四 route <=15%；预热后内存增长斜率 <1 MB/hour，并记录参考硬件/OS |
| 基础音质 | 单 source、100%、无需格式转换时幅值误差不超过 `1e-6`，无 NaN/Inf、无 DC 注入 |
| 实机透明度 | 100% unity 路径的 loopback RMS 增益误差 <=0.05 dB；设备不变时快速调节不出现超过测试底噪 20 dB 的控制脉冲 |
| gain 变化 | `0% <-> 300%` 使用 10 ms sample ramp；控制变化不产生由参数阶跃导致的 click |
| SRC | 44.1 <-> 48 kHz 测试信号 SNR 至少 90 dB、THD+N 不高于 -90 dB、20 Hz-18 kHz ripple <=0.1 dB、alias <=-80 dBFS；不满足时继续 fail closed |
| 峰值保护 | 最终输出始终在 `[-1, 1]`；持续 limiter/hard-clamp 比例可见；保护器超出延迟/CPU Gate 时不进入默认路径 |

---

### Task 1: 建立可测试的 engine seam 和 typed plan result [P0]

**Files:**
- Create: `Sources/ToolBox/AudioRouting/AudioRouteController.swift`
- Modify: `Sources/ToolBox/AudioRouting/AudioRoutingModels.swift`
- Modify: `Sources/ToolBox/AudioRouting/RoutePlanCompiler.swift`
- Modify: `Sources/ToolBox/AudioRouting/AudioRoutingService.swift`
- Modify: `Sources/ToolBox/AudioRouting/AudioRuleStore.swift`
- Create: `Tests/ToolBoxTests/AudioRoutingServiceTests.swift`
- Modify: `Tests/ToolBoxTests/RoutePlanCompilerTests.swift`
- Modify: `Tests/ToolBoxTests/AudioRuleStoreTests.swift`

**Interfaces:**
- Produces the four-method `AudioRouteEngineControlling` interface above.
- Produces `AudioRouteCompilation(plans:resolutions:)` and typed `AudioRouteRejectionReason`.
- Keeps existing public UI calls `setVolume`, `stepVolume`, and `setOutputDevice` source-compatible.

- [ ] Add fake-engine tests for gain-only update, affected-route rebuild, unavailable default device, cleanup failure, service generation change, and stale async result rejection.
- [ ] Change `RoutePlanCompiler.compile` to return plans plus a resolution for every persisted rule; surface missing default device, unavailable target, unsupported capability, capacity, excluded process and waiting process separately.
- [ ] Move the private protocol/native adapter out of `AudioRoutingService.swift`, inject it through the initializer, and let `AudioRouteController` serialize native calls off MainActor.
- [ ] Add monotonic reconcile generation. A late result may publish diagnostics but cannot replace a newer desired state.
- [ ] Canonicalize loaded rules by exact bundle ID with deterministic “latest document entry wins”; never feed duplicate keys to `Dictionary(uniqueKeysWithValues:)`.
- [ ] Keep a direct atomic parameter path for slider changes; route topology remains unchanged when only gain changes.
- [ ] Run focused tests:

```bash
xcodegen generate
xcodebuild test -project ToolBox.xcodeproj -scheme ToolBox -destination 'platform=macOS' \
  -only-testing:ToolBoxTests/AudioRoutingServiceTests \
  -only-testing:ToolBoxTests/RoutePlanCompilerTests \
  -only-testing:ToolBoxTests/AudioRuleStoreTests
```

- [ ] Commit only this slice: `refactor(audio): add testable route controller seam`.

**Gate A1:** failure injection proves a failed/stale reconcile cannot be reported as active and cannot mutate a newer plan.

### Task 2: 暴露实时诊断并增加 fail-safe watchdog [P0]

**Files:**
- Modify: `Sources/ToolBox/AudioRouting/AudioRouteEngine.h`
- Modify: `Sources/ToolBox/AudioRouting/AudioRouteEngine.mm`
- Modify: `Sources/ToolBox/AudioRouting/AudioRoutingModels.swift`
- Modify: `Sources/ToolBox/AudioRouting/AudioRouteController.swift`
- Modify: `Sources/ToolBox/AudioRouting/AudioRoutingService.swift`
- Create: `Tests/ToolBoxTests/AudioRouteDiagnosticsTests.swift`

**Interfaces:**
- Native engine returns immutable control-thread snapshots; callbacks only mutate atomic counters/flags.
- `AudioRouteState.active` requires both capture and output frame progress in the current generation.

- [ ] Add counters for capture/output callbacks and frames, last host time, ring occupancy/high-water mark, warmup, underrun, overrun, forced resync, format mismatch, non-finite input, limited/clipped samples and callback-in-flight count.
- [ ] Treat callback buffer/layout mismatch as a fatal atomic flag rather than silently returning `noErr` forever.
- [ ] Poll snapshots every 250 ms only while a non-native rule exists; suspend the timer when no route is desired.
- [ ] State transitions are `starting -> active`, `starting -> awaitingAudio`, or `active -> degraded/failed`. API creation success alone stays `starting`.
- [ ] If a process reports running output but capture has no frames after a bounded startup window, show the honest combined reason “权限、受保护内容或当前无可捕获音频”; do not claim a definitive TCC denial.
- [ ] On fatal format/callback flags, immediately stop capture for the affected app, then clean the sink and publish the exact typed error.
- [ ] Add tests for no-callback, capture-only, output-only, fatal mismatch, stalled callback, counter wrap and recovery to active.
- [ ] Run:

```bash
xcodebuild test -project ToolBox.xcodeproj -scheme ToolBox -destination 'platform=macOS' \
  -only-testing:ToolBoxTests/AudioRouteDiagnosticsTests \
  -only-testing:ToolBoxTests/AudioRoutingServiceTests
```

- [ ] Commit: `feat(audio): add route diagnostics and fail-safe watchdog`.

**Gate A2:** no route is shown as active before real frame flow, and simulated fatal callback state stops Tap reads within one watchdog interval.

### Task 3: 事务化 route diff、generation retirement 和事件合并 [P0]

**Files:**
- Modify: `Sources/ToolBox/AudioRouting/AudioRouteController.swift`
- Modify: `Sources/ToolBox/AudioRouting/AudioRouteEngine.h`
- Modify: `Sources/ToolBox/AudioRouting/AudioRouteEngine.mm`
- Modify: `Sources/ToolBox/AudioRouting/AudioDeviceRegistry.swift`
- Modify: `Sources/ToolBox/AudioRouting/AudioProcessRegistry.swift`
- Create: `Tests/ToolBoxTests/AudioRouteLifecycleTests.swift`
- Modify: `Tests/ToolBoxTests/AudioRoutingServiceTests.swift`

**Interfaces:**
- `reconcile` returns per-route `kept/started/stopped/failed` outcomes instead of a single all-or-nothing Bool.
- Retired native contexts remain owned until their callback-in-flight count is zero.

- [x] Replace full `stopAll -> start all` with route-level diff. Unchanged physical output routes and app sources remain running.
- [x] Apply one Core Audio lifecycle operation at a time on the controller actor; MainActor only submits desired state and consumes results.
- [x] Coalesce registry events for 100 ms and collapse device/process/service notifications into one reconcile generation.
- [x] Filter stream-format listeners so an unrelated HDMI/USB device cannot tear down a route that does not reference it.
- [x] On `coreaudiod` restart, freeze reconcile, advance service generation, refresh both registries, retire old contexts, then compile/apply once using fresh AudioObjectIDs.
- [x] Do not directly delete route pointers on service restart. Callback leases use an immutable context plus single atomic detached/readers state and are never reused.
- [x] For normal teardown, ramp routed sources to zero, wait 12 ms, stop capture so `mutedWhenTapped` releases the original path, then stop/destroy the silent sink. Fatal paths skip the wait and release capture immediately.
- [x] Add lifecycle tests for partial start failure, IOProc destroy failure/quarantine, unrelated device change, repeated restart generations, late callback retirement and resource balance.
- [ ] Run Address Sanitizer for the lifecycle suite:

```bash
xcodebuild test -project ToolBox.xcodeproj -scheme ToolBox -destination 'platform=macOS' \
  -enableAddressSanitizer YES \
  -only-testing:ToolBoxTests/AudioRouteLifecycleTests
```

- [ ] Commit: `fix(audio): isolate route rebuilds and retire stale generations safely`.

**Gate A3:** one route can fail/rebuild without interrupting an unrelated route, and the 100-cycle/ASan suite has no leaks or use-after-free.

### Task 4: 重构实时 ring，降低固定延迟并快速恢复过载 [P0]

**Files:**
- Create: `Sources/ToolBox/AudioRouting/AudioRouteRealtime.hpp`
- Create: `Sources/ToolBox/AudioRouting/AudioRouteRealtime.cpp`
- Modify: `Sources/ToolBox/AudioRouting/AudioRouteEngine.mm`
- Modify: `Sources/ToolBox/DisplayControl/Darwin/DisplayControlBridgingHeader.h`
- Create: `Tests/ToolBoxTests/AudioRouteRealtimeTests.swift`

**Interfaces:**
- Realtime primitives are internal C++ implementation details with a narrow C test bridge.
- Watermarks are computed from capture/output buffer sizes, safety offsets and latency, then frozen for the running generation.

- [x] Move `StereoRingBuffer`, drift controller and resync logic out of the Objective-C lifecycle file without exposing them to Swift product code.
- [x] Replace fixed 4096-frame target with a bounded target derived from queried device periods and limited to `256...2048` frames. The p95 hardware Gate remains open.
- [x] Add low/target/high watermarks. At high-water breach, advance to recent audio and use a short fade-in; do not spend minutes replaying stale frames at +0.1%.
- [x] Keep bounded drift correction for equal nominal rates, but reset its integrator on generation change, underrun and forced resync.
- [x] Distinguish initial warmup from underrun metrics. Underrun output is deterministic zero plus fade-in when valid data returns.
- [x] Test wraparound, full/empty boundaries, producer/consumer ordering, overrun resync, underrun recovery, non-finite sanitization and no out-of-bounds access.
- [ ] Add a deterministic simulated 24-hour-equivalent test using random callback sizes `32...4096` and clock drift `+/-50/100/500/1000 ppm`, rather than wall-clock sleep.
- [ ] Run:

```bash
xcodebuild test -project ToolBox.xcodeproj -scheme ToolBox -destination 'platform=macOS' \
  -only-testing:ToolBoxTests/AudioRouteRealtimeTests
```

- [ ] Commit: `perf(audio): bound route latency and recover ring overruns`.

**Gate A4:** synthetic long-run metrics have no bounds/concurrency failure, and the real 48 kHz built-in/USB path measures p95 <=50 ms additional steady-state latency; <=35 ms remains the optimization target.

### Task 5: gain dezipper、设备切换 envelope 与峰值保护 [P1]

**Files:**
- Modify: `Sources/ToolBox/AudioRouting/AudioRouteDSP.hpp`
- Modify: `Sources/ToolBox/AudioRouting/AudioRouteDSP.cpp`
- Modify: `Sources/ToolBox/AudioRouting/AudioRouteRealtime.hpp`
- Modify: `Sources/ToolBox/AudioRouting/AudioRouteRealtime.cpp`
- Modify: `Sources/ToolBox/AudioRouting/AudioRouteEngine.mm`
- Modify: `Tests/ToolBoxTests/AudioRouteDSPTests.swift`
- Create: `Tests/ToolBoxTests/AudioRouteQualityTests.swift`

**Interfaces:**
- UI writes atomic target gain; callback-owned current gain reaches it over exactly 10 ms at the route sample rate.
- A route-level output envelope handles switch/start/stop independently from per-source volume.

- [x] Add finite-value sanitization before mixing; replace NaN/Inf with zero and count it.
- [x] Add a sample-counted 10 ms linear gain ramp for mute and `0...300%` updates.
- [ ] Add a 20 ms fade-out and 30 ms fade-in output envelope for device/rebuild transitions. Do not use `DispatchQueue.sync`, locks or a delayed Bool inside IOProc.
- [x] Keep final hard clamp as a safety backstop, replacing non-finite output with zero.
- [ ] Implement and benchmark one preallocated short-lookahead peak limiter candidate against the existing hard clamp using speech, sine, impulse and multi-source fixtures. It may become the default boosted/mixed path only if total latency remains within Gate, CPU regression is <10% for the same route count, and the <=100% unity path meets amplitude tolerance.
- [ ] If the limiter candidate misses any Gate, retain hard clamp, expose sustained-clipping diagnostics, and document that 300% can distort. Do not silently change the saved percentage.
- [ ] Test ramp duration, no parameter step, non-finite sanitization, limiter ceiling/release, bypass/unity behavior and deterministic output. Ramp/non-finite/hard-clamp cases are covered; limiter cases remain blocked on the candidate implementation.
- [ ] Run:

```bash
xcodebuild test -project ToolBox.xcodeproj -scheme ToolBox -destination 'platform=macOS' \
  -only-testing:ToolBoxTests/AudioRouteDSPTests \
  -only-testing:ToolBoxTests/AudioRouteQualityTests
```

- [ ] Commit: `feat(audio): smooth route transitions and harden peak handling`.

**Gate B1:** rapid slider movement and device switching produce no control-induced click in fixtures or hardware capture; limiter inclusion follows measured criteria rather than preference.

### Task 6: 设备能力快照、预检和 Float32 layout 兼容 [P1]

**Files:**
- Modify: `Sources/ToolBox/AudioRouting/AudioRoutingModels.swift`
- Modify: `Sources/ToolBox/AudioRouting/AudioDeviceRegistry.swift`
- Modify: `Sources/ToolBox/AudioRouting/CoreAudioPropertyReader.swift`
- Create: `Sources/ToolBox/AudioRouting/AudioDeviceCompatibility.swift`
- Modify: `Sources/ToolBox/AudioRouting/RoutePlanCompiler.swift`
- Modify: `Sources/ToolBox/AudioRouting/AudioRouteEngine.mm`
- Modify: `Sources/ToolBox/AudioRouting/AudioRoutingSettingsView.swift`
- Create: `Tests/ToolBoxTests/AudioDeviceCompatibilityTests.swift`
- Modify: `Tests/ToolBoxTests/AudioRegistryProjectionTests.swift`

**Interfaces:**
- Device snapshots include stable identity plus transient input/output scope capabilities.
- `AudioDeviceCompatibility.evaluate(source:target:)` is pure and returns supported, experimental or rejected with exact reason.

- [ ] Read alive state, transport type, input/output streams and ASBDs, nominal/available rates, channel layout/preferred stereo channels, buffer frame size/range, latency, safety offset and hog mode. The current slice reads alive, output streams/ASBD, nominal rate, buffer size, latency and safety offset; the remaining fields stay open.
- [x] Do not mutate a physical device's nominal rate or virtual format merely to make ToolBox compatible.
- [ ] Support Float32 interleaved and non-interleaved layouts with precomputed buffer descriptors.
- [ ] Support mono -> stereo duplication, stereo -> mono average, and stereo -> multichannel preferred stereo pair; zero all unmapped channels.
- [ ] Treat multi-stream, aggregate/multi-output, AirPlay/remote and unknown virtual devices as experimental until their hardware rows pass. Prevent selecting ToolBox-owned devices as output targets.
- [x] Disable incompatible picker entries and display the typed reason before a route attempts to start.
- [x] On alive/format/rate/profile changes, advance device configuration generation and rebuild plans using that device from fresh properties.
- [ ] Add table-driven device capability tests for built-in stereo, mono USB, non-interleaved USB, HDMI 8-channel, Bluetooth profile change, AirPlay, aggregate and input-only devices.
- [ ] Commit: `feat(audio): preflight output device formats and channel layouts`.

**Gate B2:** every device shown as selectable has a format adapter or a hardware acceptance record; unsupported devices fail before creating a muted Tap.

### Task 7: 跨采样率 SRC 门控 [P1/P2]

**Files:**
- Create: `Sources/ToolBox/AudioRouting/AudioRouteSampleRateConverter.hpp`
- Create: `Sources/ToolBox/AudioRouting/AudioRouteSampleRateConverter.cpp`
- Modify: `Sources/ToolBox/AudioRouting/AudioRouteEngine.mm`
- Modify: `Sources/ToolBox/AudioRouting/AudioDeviceCompatibility.swift`
- Create: `Tests/ToolBoxTests/AudioRouteSampleRateConverterTests.swift`

**Interfaces:**
- Converter is created, configured, primed and allocated on the control actor before IO starts.
- Running callbacks only use preallocated converter state and scratch buffers.

- [ ] Prototype Apple's `AudioConverter` for 44.1/48/96 kHz Float32 paths and profile allocations, locks, callback duration and quality with Instruments.
- [ ] Keep equal-rate paths on the smaller native realtime adapter; do not pay SRC cost when it is unnecessary.
- [ ] Combine nominal conversion ratio with bounded ring-occupancy drift correction. Reset on discontinuity/profile change.
- [ ] Reject converter creation/prime failure before starting capture.
- [ ] Add impulse, sweep, sine, silence, channel-map and long-run drift fixtures; assert the SNR/THD+N Gate.
- [ ] Run the focused tests under Address Sanitizer and profile one hardware path under Allocations/Time Profiler.
- [ ] Run the realtime producer/consumer suite separately under Thread Sanitizer and Undefined Behavior Sanitizer; sanitizer-only timing is not used for latency claims.
- [ ] If realtime allocation/lock or quality Gate fails, leave cross-rate devices disabled and record the measured rejection; do not weaken realtime constraints.
- [ ] Commit only if the Gate passes: `feat(audio): add prewarmed cross-rate conversion`.

**Gate B3:** 44.1 <-> 48 kHz passes objective quality, realtime and long-run drift criteria. Until then, same-rate support remains the documented compatibility boundary.

### Task 8: CapturePolicy、逻辑应用分组和 macOS 26 恢复 [P1]

**Files:**
- Create: `Sources/ToolBox/AudioRouting/AudioCapturePolicy.swift`
- Create: `Resources/AudioCapturePolicy.plist`
- Modify: `Sources/ToolBox/AudioRouting/AudioRoutingModels.swift`
- Modify: `Sources/ToolBox/AudioRouting/AudioProcessRegistry.swift`
- Modify: `Sources/ToolBox/AudioRouting/RoutePlanCompiler.swift`
- Modify: `Sources/ToolBox/AudioRouting/AudioRouteEngine.mm`
- Create: `Tests/ToolBoxTests/AudioCapturePolicyTests.swift`
- Modify: `Tests/ToolBoxTests/RoutePlanCompilerTests.swift`

**Interfaces:**
- One `AudioRouteSource` represents one logical app and contains an exact process-object set, not one source per helper PID.
- Policy mappings are versioned exact bundle IDs; no generic prefix ownership guesses.

- [ ] Exclude ToolBox, ToolBox-owned virtual devices/helpers, known unsafe system processes and protected/unsupported categories by default.
- [ ] Add explicit, test-backed groups for Zoom, Teams, Chrome and other confirmed helpers. Unknown helpers remain independent rows.
- [ ] Build one Tap from all process ObjectIDs in a logical app group, reducing Aggregate/ring count and avoiding duplicate per-helper gain.
- [ ] Keep a configured session while its Process Object exists; use `isRunningOutput` for activity/status and apply a 5-second membership debounce before destructive rebuild.
- [ ] On macOS 26+, prefer `CATapDescription.bundleIDs` plus `processRestoreEnabled`; on 14.2-15 keep exact ObjectID enumeration.
- [ ] Enforce global/app/output capacity limits through typed compilation rejection instead of native `kAudio_ParamError` alone.
- [ ] Test no self-capture, exact helper grouping, unknown helper isolation, process restart, pause/resume without churn, macOS adapter selection and capacity reasons.
- [ ] Commit: `feat(audio): group app processes and enforce capture policy`.

**Gate B4:** Zoom/Chrome helper restarts do not multiply Tap count or lose the saved rule, and no ToolBox-owned audio is recaptured.

### Task 9: 控制面写入、状态和诊断 UI [P1]

**Files:**
- Modify: `Sources/ToolBox/AudioRouting/AudioRoutingService.swift`
- Modify: `Sources/ToolBox/AudioRouting/AudioRoutingPanel.swift`
- Modify: `Sources/ToolBox/AudioRouting/AudioRoutingSettingsView.swift`
- Modify: `Sources/ToolBox/AudioRouting/AudioRuleStore.swift`
- Create: `Tests/ToolBoxTests/AudioRoutingViewStateTests.swift`

**Interfaces:**
- UI consumes typed row/view state; native OSStatus strings do not leak directly into layout logic.
- Runtime parameter update is immediate; persistence is independently debounced and flushed on stop.

- [x] Apply gain target immediately, debounce continuous slider persistence, and flush the final value on app stop/shutdown.
- [x] Refresh remembered device projection only when the set of output UIDs actually changes.
- [ ] Show `starting`, `active`, `waiting`, `permission-or-no-audio`, `unsupported-format`, `device-missing`, `recovering`, `cleanup-blocked` and sustained clipping as distinct localized states.
- [ ] Show current compatibility/transport information and disable unsupported output devices in Settings.
- [ ] Keep the popover compact: percentage controls and one small state indicator only. Detailed diagnostics live in Settings and can be copied as a privacy-safe snapshot.
- [x] Do not add an input picker; input remains managed by the target application.
- [ ] Test debounce/flush, typed status text, long device names, unavailable/experimental device options and clipping warning thresholds.
- [ ] Commit: `feat(audio): surface truthful route status and diagnostics`.

**Gate B5:** UI never reports a saved preference as applied unless diagnostics confirm it, and continuous slider use does not trigger HAL registry reload storms.

### Task 10: 自动化、真机矩阵和输出版本发布门 [P0-P2]

**Files:**
- Create: `docs/testing/per-app-audio-acceptance.md`
- Create: `scripts/verify-audio-routing-build.sh`
- Modify: `.github/workflows/release.yml`
- Modify: `README.md`

- [x] Add all audio unit/lifecycle tests to a required CI test step before packaging.
- [x] Make the verification script run XcodeGen, full tests, Debug/Release builds, plist lint, framework checks, strict codesign and `git diff --check` without launching the app.
- [x] Define manual rows with OS build, CPU architecture, app/version, device UID redacted label, transport, sample rate, channels, buffer size, duration, latency, CPU and diagnostic counters.
- [ ] Minimum OS matrix: macOS 14.2/14.4, latest macOS 15, and macOS 26; Apple Silicon is required, Intel is required if the release continues to claim Intel support.
- [ ] Minimum app matrix: Zoom, Teams, Music, Chrome helper, Safari and one protected-content case whose limitation is documented rather than bypassed.
- [ ] Minimum output matrix: built-in, 3.5 mm, USB headset/DAC, Bluetooth A2DP plus HFP profile transition, HDMI/DisplayPort, AirPlay, aggregate/multi-output and a common virtual device.
- [ ] Scenarios: 100/300%, two apps same/different outputs, start/quit/pause/helper restart, target unplug/replug, sleep/wake, profile/rate change, permission first grant/refusal/regrant, ToolBox normal quit/forced termination and `coreaudiod` restart.
- [ ] Stress rows: 100 target-device hotplug cycles, 100 target-app start/quit cycles, 20 sleep/wake cycles and an 8-hour Zoom + media playback soak. Wired/USB recovery must complete within 1 second; Bluetooth/AirPlay recovery or explicit degradation within 5 seconds.
- [ ] On a dedicated QA machine, deliberately restart `coreaudiod` and verify fresh enumeration, no stale AudioObjectID reuse, original app audio recovery and exactly one rebuilt route. Never automate this destructive step in normal app behavior or CI.
- [ ] TCC rows include clean first allow, first deny, System Settings re-allow, runtime revoke, Developer ID install, same-identity upgrade and changed ad-hoc path.
- [ ] Treat permanent mute, false active, source leakage, unrelated-route interruption, monotonic resource growth or missing recovery as release blockers.
- [ ] Make the architecture claim explicit: either publish Apple Silicon-only, or build a universal archive and require `lipo -archs` to report both `arm64 x86_64`. Do not inherit architecture from the CI runner accidentally.
- [ ] Developer ID signing, notarization and TCC persistence on an installed build are separate manual release gates; ad-hoc `codesign --verify` only proves bundle consistency.
- [ ] Run final local gate:

```bash
xcodegen generate
xcodebuild test -project ToolBox.xcodeproj -scheme ToolBox -destination 'platform=macOS'
CONFIG=Debug OPEN=0 ./build.sh
OPEN=0 ./build.sh
plutil -lint Resources/Info.plist Resources/ToolBox.entitlements
codesign --verify --deep --strict build/Build/Products/Debug/ToolBox.app
codesign --verify --deep --strict build/Build/Products/Release/ToolBox.app
git diff --check
```

- [ ] Commit: `test(audio): gate routing releases on recovery and compatibility`.

**Gate C:** Tasks 1-10 and the required hardware rows pass before claiming stable per-app output volume/device support.

## 6. 执行顺序和并行边界

```text
Task 1 -> Task 2 -> Task 3 -> Task 4 -> hardware smoke
                              -> Task 5 -> Task 6 -> Task 7 -> Task 8 -> Task 9 -> Task 10
```

- Task 1-4 修改共享 engine interface 和生命周期，必须串行。
- Task 5 的 DSP fixture、Task 6 的设备能力 fixture、Task 10 的矩阵文档可在 interface 稳定后并行准备，但由主代理依次集成。
- 每个 Gate 后执行一次代码质量复查：实时线程违规、悬空 context、静默 catch、资源泄漏、错误状态真实性和文档漂移。

## 7. 明确延期或不支持

- 不提供分应用输入，不增加虚拟麦克风、输入 broker 或输入规则 schema。
- 不改变系统默认输出作为“分应用路由”的替代实现。
- 不承诺 DRM/受保护内容可以被捕获。
- AirPlay、aggregate/multi-output、专业 DAW hog mode 在通过矩阵前标记为 experimental 或 unsupported。
- 不加入 EQ、混响、媒体键/OSD、设备 master volume 或完整效果链；它们不服务于本计划的稳定性、音质和兼容性目标。
- 不因追求支持率而在 IOProc 中加入锁、动态分配或未经测量的转换器。

## 8. 参考依据

- 当前正式设计：`docs/superpowers/specs/2026-07-21-per-app-audio-routing-design.md`
- 当前实现计划：`docs/superpowers/plans/2026-07-21-per-app-audio-routing.md`
- 外部架构参考：`/Users/youtonghy/Downloads/break/docs/PER-APP-AUDIO-DESIGN.md`
- Apple sample: `Capturing system audio with Core Audio taps`
- 本机 SDK 26.5：`CoreAudio.framework/Headers/AudioHardwareTapping.h`、`CATapDescription.h`、`AudioHardware.h`
