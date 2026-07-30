# 音频音量持久化修复（2026-07-28）

## 用户报告的问题

> 即使我已经预设并记忆了该音量调节的特定值，但在软件重启后，该设置未能自动应用。因此，每次全新接入播放时，都需要重新应用该设置，以避免它以百分之百的音量播放。

## 根因分析

### 问题 1：暂停播放被误判为路由损坏（主因）

**现象**：应用暂停 2 秒后，保存的音量规则失效，恢复播放时以 100% 音量输出。

**技术细节**：

`AudioRouteDiagnosticsEvaluator.evaluate` 中的失速检测逻辑存在缺陷：

```swift
// 修复前
let didStall = snapshot.map { current in
    previous.map {
        current.captureFrameCount == $0.captureFrameCount
            || current.outputFrameCount == $0.outputFrameCount  // ← 问题：OR 逻辑
    } ?? false
} ?? false
```

- `captureFrameCount` 使用累计值，一旦捕获过音频就永久 `> 0`，所以 `hasCapture` 永久为真
- 应用暂停时，tap 的 capture 回调停止，`captureFrameCount` 不再前进
- 但 aggregate device 的 output IOProc 持续运行（向扬声器/耳机输出），`outputFrameCount` 继续增长
- 原逻辑用 `||`，只要 capture **或** output 之一不前进就计入失速
- 连续 8 次轮询（250ms × 8 = 2s）后判定 `.stalled`
- `runDiagnosticsWatchdogTick` 拆掉 route 并记入 `terminalRouteFailures`
- `CATapMutedWhenTapped` 失效，原音频路径恢复，音量回到系统默认 100%

**恢复机制的局限**：

`recoverTerminalRouteIfNeeded` 要求：
1. `haveSameRoutingProcesses` — 进程对象 ID 和 bundle ID 不变 ✓
2. `isHALActive` 从 false → true 跳变

某些应用（如 Music、某些播放器）暂停时保持 `isRunning=1` 或 `isRunningOutput=1`，恢复时没有跳变 → 无法自动恢复 → 用户必须手动调节滑块触发 `reconcile()`。

### 问题 2：新音频客户端发现延迟（次因）

**现象**：应用首次播放音频时，有 5–6 秒以 100% 音量播放的窗口。

**技术细节**：

```swift
// AudioProcessRegistry.swift
nonisolated static let processListSettleDelay: Duration = .seconds(5)

private let reloadCoalescer = AudioRegistryEventCoalescer(
    delay: AudioProcessRegistry.processListSettleDelay
)
```

- `AudioRegistryEventCoalescer` 是 **debounce** 语义：每次 HAL 进程列表变化都重置计时器
- 当应用首次创建音频客户端时，HAL 发出 `kAudioHardwarePropertyProcessObjectList` 变化通知
- 但在活跃系统上，进程列表持续变化（浏览器 helper、通知音、系统 daemon）
- 每次变化都重置 5s 倒计时 → reload 被无限推迟 → 规则无法应用

**5 秒延迟的来源**：

commit `748c18d`「修复音频进程刷新导致的 WebKit 白屏」将延迟从 40ms 提升到 5s：

> HAL publishes process-list changes before new clients always finish registering.
> Avoid synchronous enumeration while WebKit GPU/audio clients are still initializing.

同步读取 HAL 属性（`kAudioProcessPropertyBundleID` 等）会阻塞正在注册的 WebKit GPU 进程，导致白屏。5s 延迟避开了这个敏感窗口。

## 修复方案

### 修复 1：区分「应用暂停」与「路由损坏」

**核心思路**：只有在 HAL 确认应用正在输出音频（`isRunningOutput=1`）时，capture 停止才是真正的故障；否则是应用暂停，应保持 route。

#### 修改 `AudioRouteDiagnosticsEvaluator`

新增参数 `sourceIsProducingOutput`，传入 HAL `isRunningOutput` 状态：

```swift
static func evaluate(
    snapshot: AudioRouteDiagnosticsSnapshot?,
    previous: AudioRouteDiagnosticsSnapshot?,
    startupPollCount: Int,
    consecutiveStalledPollCount: Int,
    sourceIsProducingOutput: Bool = true  // ← 新增
) -> AudioRouteDiagnosticsHealth
```

逻辑调整：

```swift
if let previous {
    let captureAdvanced = snapshot.captureFrameCount != previous.captureFrameCount
    let outputAdvanced = snapshot.outputFrameCount != previous.outputFrameCount
    
    // Output IOProc 停止是真正的 fatal：无法再听到声音
    if !outputAdvanced, consecutiveStalledPollCount >= stallPollCount {
        return .stalled
    }
    
    // Capture 停止只在源正在输出时才是故障
    if !captureAdvanced {
        guard sourceIsProducingOutput else { return .awaitingAudio }
        if consecutiveStalledPollCount >= stallPollCount { return .stalled }
    }
}
return .active
```

#### 修改 `AudioRoutingService.runDiagnosticsWatchdogTick`

计算哪些 bundle 正在输出：

```swift
let producingOutputBundleIDs = Set(
    latestProcesses.filter(\.isRunningOutput).map(\.bundleID)
)

for plan in compilation.plans {
    let isProducingOutput = plan.sources.contains {
        producingOutputBundleIDs.contains($0.bundleID)
    }
    
    // 只在有意义的失速时递增计数器
    let didStall = snapshot.map { current in
        previous.map { previous in
            if current.outputFrameCount == previous.outputFrameCount { return true }
            return isProducingOutput
                && current.captureFrameCount == previous.captureFrameCount
        } ?? false
    } ?? false
    
    stalledPollCounts[plan.id] = didStall ? (stalledPollCounts[plan.id, default: 0] + 1) : 0
    
    healthByRouteID[plan.id] = AudioRouteDiagnosticsEvaluator.evaluate(
        snapshot: snapshot,
        previous: previous,
        startupPollCount: watchdogPollCount,
        consecutiveStalledPollCount: stalledPollCounts[plan.id, default: 0],
        sourceIsProducingOutput: isProducingOutput
    )
}
```

**效果**：
- 应用暂停时，route 保持在 `.awaitingAudio` 状态，不释放
- 保存的音量规则保留，恢复播放时立即生效
- 真正的 output IOProc 死亡仍会被检测并拆除

### 修复 2：防止 coalescer 饿死

**核心思路**：debounce 保留「等待安静期」语义，但添加最大延迟上限，防止持续事件流无限推迟。

#### 修改 `AudioRegistryEventCoalescer`

```swift
@MainActor
final class AudioRegistryEventCoalescer {
    private let delay: Duration
    private let maximumDelay: Duration  // ← 新增
    private var pendingTask: Task<Void, Never>?
    private var burstDeadline: ContinuousClock.Instant?  // ← 新增

    init(delay: Duration = .milliseconds(100), maximumDelay: Duration? = nil) {
        self.delay = delay
        self.maximumDelay = maximumDelay ?? delay * 3
    }

    func schedule(_ action: @escaping @MainActor () -> Void) {
        let now = ContinuousClock.now
        let deadline = burstDeadline ?? now.advanced(by: maximumDelay)
        burstDeadline = deadline
        pendingTask?.cancel()
        let sleepDuration = min(delay, max(.zero, now.duration(to: deadline)))
        pendingTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: sleepDuration)
            } catch { return }
            guard !Task.isCancelled, let self else { return }
            pendingTask = nil
            burstDeadline = nil  // ← 重置
            action()
        }
    }

    func cancel() {
        pendingTask?.cancel()
        pendingTask = nil
        burstDeadline = nil  // ← 重置
    }
}
```

#### 应用到 `AudioProcessRegistry`

```swift
nonisolated static let processListSettleDelay: Duration = .seconds(5)
nonisolated static let processListMaximumSettleDelay: Duration = .seconds(6)

private let reloadCoalescer = AudioRegistryEventCoalescer(
    delay: AudioProcessRegistry.processListSettleDelay,
    maximumDelay: AudioProcessRegistry.processListMaximumSettleDelay
)
```

**效果**：
- 安静时仍等待 5s settle（保护 WebKit 白屏修复）
- 持续变化时最多延迟 6s（而非无限期）
- 新音频客户端的 100% 音量窗口从「可能 ∞」降至「≤6s」

## 测试覆盖

### 新增测试

1. **`testPausedSourceKeepsRouteInsteadOfStalling`**  
   验证 `isRunningOutput=0` 时 capture 停止不触发 `.stalled`

2. **`testDeadOutputIOProcStallsEvenWhileSourceIsIdle`**  
   验证 output 停止即使在源空闲时也触发 `.stalled`

3. **`testPausedPlaybackKeepsRouteAndSavedGain`**  
   端到端验证：暂停 2s+ 后 route 和增益保留

4. **`testRegistryEventCoalescerRunsWithinMaximumDelayDuringSustainedChurn`**  
   验证持续事件流下 coalescer 最终触发

### 已有测试适配

- `testEitherCaptureOrOutputStoppingBecomesStalled` → 重命名并加 `sourceIsProducingOutput: true`
- 其他 evaluator 测试：默认参数 `true` 保持兼容

## 验证步骤

1. **暂停场景**：  
   播放音频 → 设置音量 50% → 暂停 5 秒 → 恢复播放 → 音量仍为 50%

2. **重启场景**：  
   设置音量 50% → 关闭 ToolBox → 重启 ToolBox → 播放 → 音量为 50%（延迟 ≤6s）

3. **新客户端场景**：  
   关闭 Chrome → 设置 Chrome 音量 30% → 打开 Chrome 并播放视频 → 延迟 ≤6s 后音量降至 30%

## 后续优化建议

### 选项 A：降低 settle 延迟

**当前**：5s settle + 6s 上限  
**风险**：可能重现 WebKit 白屏（commit `748c18d` 修复的问题）

**建议**：
- 降至 1s settle + 1.5s 上限
- 在多种浏览器（Safari、Chrome、Edge）打开复杂网页并播放视频
- 监控是否出现白屏或页面卡死

### 选项 B：两阶段 reload

**思路**：
1. 短延迟（300ms）快速 reload，**只读取有保存规则的 bundle ID** 对应的新对象
2. 长延迟（5s）完整 reload 所有对象

**实现**：
- 维护 `Set<String>` 缓存所有有规则的 bundle ID
- HAL 事件触发时，先读新对象的 `PID`（1 次 HAL read）
- 查 `NSRunningApplication` 映射得到 bundle ID
- 只对匹配规则的对象读取完整属性

**优势**：
- 有规则的应用延迟 ~300ms
- 无规则的应用仍等 5s（保护 WebKit）

**风险**：
- 读取新对象的 `PID` 仍是 HAL read，可能影响 WebKit 注册
- 实现复杂度中等

### 选项 C：后台线程枚举

**思路**：将 `CoreAudioPropertyReader.readAvailableObjects` 移至后台 DispatchQueue

**风险**：
- WebKit 白屏可能不是主线程阻塞导致，而是 HAL read 本身干扰注册
- `AudioObject` API 虽线程安全，但并发读取可能有其他副作用

**不推荐**：风险 > 收益

## 相关文件

- `Sources/ToolBox/AudioRouting/AudioRoutingModels.swift` — evaluator 逻辑
- `Sources/ToolBox/AudioRouting/AudioRoutingService.swift` — watchdog 计数
- `Sources/ToolBox/AudioRouting/AudioRegistryEventCoalescer.swift` — 防饿死
- `Sources/ToolBox/AudioRouting/AudioProcessRegistry.swift` — 应用新 coalescer
- `Tests/ToolBoxTests/AudioRouteDiagnosticsTests.swift` — evaluator 测试
- `Tests/ToolBoxTests/AudioRoutingServiceTests.swift` — 端到端测试
- `Tests/ToolBoxTests/AudioRegistryProjectionTests.swift` — coalescer 测试

## 参考

- commit `748c18d`「修复音频进程刷新导致的 WebKit 白屏」
- `docs/research/soundsource-vs-toolbox-audio-diagnosis.md` — SoundSource 对照分析
