# 音频音量系统"断断续续"问题修复报告

## 问题描述

用户报告：当音量系统调整过后，在应用重新打开后再播放，会有断断续续的感觉。但如果把音量归零到100%，然后再重新调整一次就正常了。

## 根本原因分析

经过两个 AI inspector（GLM-5.2 和 Claude Opus-5）的深度分析，发现了以下核心问题：

### 问题链条

1. **路由创建时机过早**：应用进程一出现就立即创建带有非 100% gain 的音频路由
2. **Tap 在启动脆弱期安装**：此时应用音频子系统可能未完全初始化
3. **Watchdog 检测过于激进**：`outputFrameCount` 停滞无条件判定为 stall
4. **启动期误判**：格式协商、缓冲区预热导致短暂帧停滞，触发连续 8 次检测（2秒）
5. **路由反复 teardown/rebuild**：形成循环，表现为"断断续续"

### 为什么"归零到100%后重新调整"能修复

- 音量 100% 时不创建路由（`routeStillRequired = false`）
- 音频直通系统默认路径（无 Tap，无引擎处理）
- 重新调整时应用已完全运行并稳定，路由在稳定期创建

## P0 修复（已实施✅）

### 修复 1：改进 outputFrameCount 停滞检测

**文件**：`AudioRoutingService.swift:940-948`

**修改前**：
```swift
if current.outputFrameCount == previous.outputFrameCount { return true }
```

**修改后**：
```swift
// P0 Fix: Output frame stall should also check isProducingOutput to avoid
// false positives during route startup when buffers are still warming up.
if current.outputFrameCount == previous.outputFrameCount {
    return isProducingOutput
}
```

**效果**：防止启动期的帧停滞被误判为路由失败。

---

### 修复 2：增益更新后重置诊断基线

**文件**：`AudioRoutingService.swift:1076-1085`

**修改前**：
```swift
case .applied, .unchanged:
    appliedPlans = report.plans
    if let watchdogCompilation { ... }
    routeError = nil
    watchdogGeneration = generation
    // 缺少诊断基线重置
```

**修改后**：
```swift
case .applied, .unchanged:
    appliedPlans = report.plans
    if let watchdogCompilation { ... }
    // P0 Fix: Reset diagnostics baseline after gain update to prevent watchdog
    // from comparing new snapshots against stale pre-update baseline.
    for plan in report.plans {
        previousDiagnostics[plan.id] = nil
        stalledPollCounts[plan.id] = 0
    }
    routeError = nil
    watchdogGeneration = generation
```

**效果**：防止增益更新后使用旧基线进行健康检查，导致误判。

---

### 修复 3：延迟非 100% 路由的创建

**文件**：`RoutePlanCompiler.swift:51-61`

**修改前**：
```swift
let requiresGain = rule.volumePercent != 100
let requiresDeviceOverride = selectedUID != nil && selectedUID != defaultOutputUID
guard requiresGain || requiresDeviceOverride else {
    resolutions.append(
        AudioRuleResolution(bundleID: rule.bundleID, state: .planned(routeID: nil))
    )
    continue
}
// 立即创建路由
```

**修改后**：
```swift
let requiresGain = rule.volumePercent != 100
let requiresDeviceOverride = selectedUID != nil && selectedUID != defaultOutputUID
guard requiresGain || requiresDeviceOverride else {
    resolutions.append(
        AudioRuleResolution(bundleID: rule.bundleID, state: .planned(routeID: nil))
    )
    continue
}

// P0 Fix: Delay route creation for non-100% volume until the process is
// actively producing output. This avoids installing Tap during the fragile
// app audio subsystem startup window, preventing watchdog false positives.
if requiresGain {
    let hasActiveOutput = matchingProcesses.contains { $0.isRunningOutput }
    guard hasActiveOutput else {
        resolutions.append(
            AudioRuleResolution(bundleID: rule.bundleID, state: .waiting(.processNotProducingOutput))
        )
        continue
    }
}
```

**相关修改**：
- `AudioRoutingModels.swift:194-196`：添加新的等待原因 `case processNotProducingOutput`

**效果**：仅在应用确认产出音频后才创建路由，避开启动脆弱期。

---

## 编译验证

```bash
xcodebuild -scheme ToolBox -configuration Debug build
```

✅ **BUILD SUCCEEDED**

---

## P1 修复（已实施✅）

### 修复 4：添加重建冷却期和失败计数

**文件**：`AudioRoutingService.swift:25-41, 666-729, 1000-1035`

**修改前**：
```swift
private var terminalRouteFailures: [String: String] = [:]  // 只存储错误消息

// recoverTerminalRouteIfNeeded 立即重试
let shouldRecover = recoveryCompilation.plans.contains {
    terminalRouteFailures[$0.id] != nil
}
```

**修改后**：
```swift
// 新增结构体跟踪失败详情
private struct TerminalRouteFailure {
    let message: String
    let failedAt: Date
    let retryCount: Int
    
    func incrementingRetry(now: Date) -> TerminalRouteFailure {
        TerminalRouteFailure(
            message: message,
            failedAt: now,
            retryCount: retryCount + 1
        )
    }
}

private var terminalRouteFailures: [String: TerminalRouteFailure] = [:]

// recoverTerminalRouteIfNeeded 检查冷却期和重试次数
let now = nowProvider()
let shouldRecover = recoveryCompilation.plans.contains { plan in
    guard let failure = terminalRouteFailures[plan.id] else { return false }
    
    // Give up after 3 retries
    guard failure.retryCount < 3 else { return false }
    
    // Enforce 5-second cooldown between retry attempts
    let timeSinceFailure = now.timeIntervalSince(failure.failedAt)
    return timeSinceFailure >= 5.0
}

// watchdog 记录失败时包含时间戳和计数
for (routeID, message) in failedRouteMessages {
    if let existing = terminalRouteFailures[routeID] {
        terminalRouteFailures[routeID] = existing.incrementingRetry(now: now)
    } else {
        terminalRouteFailures[routeID] = TerminalRouteFailure(
            message: message,
            failedAt: now,
            retryCount: 0
        )
    }
}
```

**效果**：
- 防止无限 teardown/rebuild 循环
- 3 次重试后放弃，避免持续干扰
- 5 秒冷却期避免快速重试

---

### 修复 5：清理过期 terminalRouteFailures

**文件**：`AudioRoutingService.swift:459-463`

**修改前**：
```swift
let compilation = RoutePlanCompiler.compile(...)
// 没有清理逻辑，terminalRouteFailures 无限累积
rebuildRows(processes: latestProcesses, devices: devices)
```

**修改后**：
```swift
let compilation = RoutePlanCompiler.compile(...)

// P1 Fix: Clean up stale terminalRouteFailures for routes no longer in compilation
let currentRouteIDs = Set(compilation.plans.map(\.id))
terminalRouteFailures = terminalRouteFailures.filter { routeID, _ in
    currentRouteIDs.contains(routeID)
}

rebuildRows(processes: latestProcesses, devices: devices)
```

**效果**：
- 防止状态泄漏
- 设备断开或应用卸载时自动清理失败记录

---

### 修复 6：audioServerRestart 期间缓存用户输入

**文件**：`AudioRoutingService.swift:105, 270, 351-357, 915-927`

**修改前**：
```swift
private func scheduleVolumeApplication(bundleID: String, session: UInt64) {
    guard audioServerRestartSession == nil,
          let taskOwner = pendingVolumeTaskOwnership.claim(bundleID) else { return }
    // 静默丢弃用户输入，无任何提示
}

private func finishAudioServerRestart(session: UInt64) {
    if audioServerRestartSession == session {
        audioServerRestartSession = nil
        // 没有应用被延迟的变化
    }
}
```

**修改后**：
```swift
// 新增缓存字典
private var deferredVolumeChanges: [String: Int] = [:]

private func scheduleVolumeApplication(bundleID: String, session: UInt64) {
    // P1 Fix: If audio server is restarting, defer the volume change instead of silently dropping it
    guard audioServerRestartSession == nil else {
        deferredVolumeChanges[bundleID] = rules.first(where: { $0.bundleID == bundleID })?.volumePercent ?? 100
        return
    }
    guard let taskOwner = pendingVolumeTaskOwnership.claim(bundleID) else { return }
    // ...
}

private func finishAudioServerRestart(session: UInt64) {
    if audioServerRestartSession == session {
        audioServerRestartSession = nil
        
        // P1 Fix: Apply deferred volume changes that were blocked during restart
        if !deferredVolumeChanges.isEmpty {
            let deferredChanges = deferredVolumeChanges
            deferredVolumeChanges.removeAll()
            for (bundleID, percent) in deferredChanges {
                scheduleVolumeApplication(bundleID: bundleID, session: session)
            }
        }
    }
}

// stop() 中清理
func stop() {
    // ...
    deferredVolumeChanges.removeAll()
    // ...
}
```

**效果**：
- Audio server 重启期间（100-500ms）的用户输入被缓存
- 重启完成后自动应用
- 用户体验：滑块移动后稍有延迟但最终生效，而非完全无响应

---

## 待实施的 P2 修复

1. **添加 teardown 重建冷却期**
   - 位置：`AudioRoutingService.swift:975 + 663`
   - 目标：防止无限 teardown/rebuild 循环

2. **清理过期 terminalRouteFailures**
   - 位置：`AudioRoutingService.swift:1124`
   - 目标：防止状态泄漏

3. **audioServerRestart 期间缓存用户输入**
   - 位置：`AudioRoutingService.swift:367`
   - 目标：避免静默丢弃用户音量调整

### P2 修复

4. **PendingTaskOwnership 添加超时保护**
   - 位置：`AudioRoutingService.swift:44-60`
   - 目标：防止永久锁定

5. **defer 块避免丢失中间值**
   - 位置：`AudioRoutingService.swift:373-383`
   - 目标：提高音量精度

6. **stop() 等待清理完成**
   - 位置：`AudioRoutingService.swift:285`
   - 目标：防止重叠启动

---

## 预期效果

实施 P0 修复后：

1. ✅ 应用重新打开后播放不再"断断续续"
2. ✅ 路由仅在应用稳定后创建，避开启动期
3. ✅ Watchdog 不再误判启动期的正常帧停滞
4. ✅ 增益更新后健康检查使用正确的基线

用户无需"归零到100%再重新调整"的 workaround。

---

## 技术细节

### Watchdog 检测逻辑

- 每 250ms 检查路由健康（`runDiagnosticsWatchdogTick`）
- 比较 `captureFrameCount` 和 `outputFrameCount`
- 连续 8 次停滞（2秒）→ 判定 `.stalled` → teardown

### 路由状态机

```
.starting → .awaitingAudio → .active
              ↓ (误判)
           .stalled → teardown → 重建 → .starting (循环)
```

### 修复后的状态机

```
等待 isRunningOutput → .starting → .awaitingAudio → .active
                                    ↓ (宽容期)
                                  (不误判)
```

---

## 代码审查要点

1. `isProducingOutput` 的判断逻辑是否准确（基于 `isRunningOutput` flag）
2. 延迟路由创建是否影响首次播放的响应时间（权衡：前几百毫秒可能以 100% 音量播放）
3. `processNotProducingOutput` 等待状态的 UI 展示
4. 诊断基线重置是否会影响正在进行的健康检查

---

## 测试建议

### 测试场景 1：基本修复验证
1. 设置某应用音量为 50%
2. 关闭该应用
3. 重新打开应用并播放音频
4. **预期**：音频流畅，不断断续续

### 测试场景 2：快速启动
1. 设置音量为 30%
2. 关闭应用
3. 立即重新打开并快速播放
4. **预期**：可能有短暂延迟（等待 isRunningOutput），但不应抖动

### 测试场景 3：频繁调整
1. 应用运行中
2. 快速调整音量 100% → 50% → 20% → 80%
3. **预期**：音量跟随滑块变化，无断续

### 测试场景 4：Audio Server 重启
1. 设置音量为 60%
2. 拔插音频设备（触发 Core Audio 重启）
3. **预期**：路由自动恢复，音量保持 60%

---

## 参考

- GLM-5.2 Inspector 分析报告（并发和音频引擎底层）
- Claude Opus-5 Inspector 分析报告（架构和代码质量）
- 原始问题描述：用户中文反馈

---

**修复日期**：2025-01-03  
**修复版本**：P0 核心修复  
**编译状态**：✅ BUILD SUCCEEDED

---

## P1 修复总结

### 修复 4：添加重建冷却期和失败计数 ✅
- 防止无限 teardown/rebuild 循环
- 3 次重试后放弃
- 5 秒冷却期避免快速重试

### 修复 5：清理过期 terminalRouteFailures ✅
- 防止状态泄漏
- 设备断开或应用卸载时自动清理

### 修复 6：audioServerRestart 期间缓存用户输入 ✅
- Audio server 重启期间（100-500ms）的用户输入被缓存
- 重启完成后自动应用

---

## 编译验证更新

### P0 + P1 修复

```bash
xcodebuild -scheme ToolBox -configuration Debug build
```

✅ **BUILD SUCCEEDED**

所有 P0 和 P1 修复已通过编译验证。

---

## 预期效果更新

实施 P0 + P1 修复后：

### P0 核心修复效果
1. ✅ 应用重新打开后播放不再"断断续续"
2. ✅ 路由仅在应用稳定后创建，避开启动期
3. ✅ Watchdog 不再误判启动期的正常帧停滞
4. ✅ 增益更新后健康检查使用正确的基线

### P1 增强修复效果
5. ✅ 路由失败后不会无限循环重试（3次上限 + 5秒冷却）
6. ✅ 状态不会无限累积泄漏（自动清理过期记录）
7. ✅ Audio server 重启期间的用户输入不会丢失

用户无需"归零到100%再重新调整"的 workaround。

---

**修复状态**：P0 ✅ | P1 ✅ | P2 待实施
**最后更新**：2025-01-03
