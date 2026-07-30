# SoundSource vs ToolBox：分应用音量与识别故障诊断

调研日期：2026-07-22  
IDA 会话：`SoundSource.i64`、`SSAudio.framework`、`ACP.framework`（headless/GUI 已打开并分析）  
对照代码：`Sources/ToolBox/AudioRouting/*`

## 修复状态（2026-07-23）

已落地：

1. **Aggregate 构图**：创建时写入正确的 `taps: [{uid, drift}]`，并用输出设备 UID 作 `clock`（不把物理设备当 subdevice，避免多 source 抢占同一设备）；删除错误的 post-create `TapList` 字符串赋值。
2. **进程列表**：不再只展示 `IsRunningOutput`；HAL 空 `bundleID` 用 NSWorkspace 回填；显示名优先 `CFBundleDisplayName`（小红书）；过滤 SoundSource 同类 daemon 噪声。
3. **面板**：列表可滚动；顺序只依赖稳定显示名和 bundle ID，不再因活跃位变化重排。
4. **可见性（Spotify 回归）**：`playingRows` = HAL 播放中 ∪ 路由 PCM active ∪ **已保存规则**。
5. **P0 对齐 SoundSource**：双读 `IsRunning`（`pir?`）+ `IsRunningOutput`（`piro`）；`recentlyActive` 12s 滞回；监听两种 HAL 属性变化。
6. **响应性能**：活动位回调只更新对应对象，不再全量枚举 HAL 或重挂所有 listener；活动变化不触发 route reconcile；相同 rows/devices/error 不重复发布；滑块 engine update 以约 60Hz 合并到最新值；`recentlyActive` 用独立到期刷新而非等待下一次 HAL 事件。

相关文件：`AudioRouteEngine.mm`、`AudioProcessRegistry.swift`、`AudioRoutingService.swift`、`AudioRoutingPanel.swift`。

## 修复状态（2026-07-25）— 多应用 mute 无声

复现：先启用 Zoom 并调音量（route 生效），再启用小红书 → 目标应用/整路无声。

根因（对照 ACP / SoundSource）：

1. **`TBAudioSelectTapDeviceAfterMigrationWait` 在 target==default 时无条件 pin 到默认输出**。进程设备列表为空（iOS-on-Mac `com.xingin.discover` 常见）或不在目标设备时，仍走 `initWithProcesses:andDeviceUID:withStream:0`，再叠加 `CATapMutedWhenTapped` → **原声被 mute，capture 零帧**。
2. SoundSource 对 mixdown/设备不确定源走 `initStereoMixdownOfProcesses:`；ToolBox 本应在无法确认 process device 时落到 mixdown，却被上面的 force-pin 短路。
3. 多应用共享同一 route 时，**任一 source 的 capture format mismatch 会把整条 route 标 fatal**（`formatMismatchCount > 0` 或 OR 源级 fatal），watchdog 拆掉 Zoom+小红书整图。

已改：

1. migration 超时后只 pin「进程真实所在设备」或唯一设备；空/歧义列表 → `kAudioObjectUnknown` → **stereo mixdown**。
2. capture 侧 format mismatch 只计数、不标 route fatal；fatal 仅来自 output IOProc。
3. diagnostics evaluator 不再因 source 侧 `formatMismatchCount` 拆整路。

相关文件：`AudioRouteEngine.mm`、`AudioRoutingModels.swift`、对应 lifecycle/diagnostics 测试。

---

## IDA 复核（2026-07-23，SSAudio / ACP / SoundSource）

### SoundSource 怎么处理「识别 / 列表 / 活跃态」

**1. 活跃态不是 `IsRunningOutput`**

ACP `+[ACPPropertyAddress processIsRunning]` 使用 selector `0x7069723f` = **`pir?`** = `kAudioProcessPropertyIsRunning`，**不是** `piro`（`IsRunningOutput`）。

`-[ACPProcessSource _updateProcessStateLocal:]` 还会：

- 读 `processDevices:` scope **`inpt`** / **`outp`**
- 建立 `activeDevices` / `hoggingDevices`
- 用 `setActive:` 写入进程状态（与设备关联一起差分更新）

**2. 逻辑应用层有「最近活跃」滞回**

`SSAudioProcess` 维护：

| 字段 | 作用 |
| --- | --- |
| `isRunning` | ACP 进程运行态 |
| `isActive` | 设备/会话活跃 |
| `recentlyActive` | 短时滞回 |
| `timeSinceLastActive` / `timeSinceActive` | 距上次活跃时间 |
| **`isRunningOrRecentlyActive`** | `isRunning OR recentlyActive`（UI 主信号） |
| `isBackgroundLike` | 后台型进程标记 |

**3. 进程目录是多表合并，不是「只读 HAL 再 filter 播放位」**

`SSAudioProcessManager`：

- `runningApplicationSnapshotsByPID` / `ByIdentity` / `ByBundleID`
- `runningApplicationIdentityByPID`
- **`parentPIDMap`**（helper → 父应用）
- `PIDToSSAudioProcessMap` / `SSAudioProcessMap`
- `lastRunningProcesses` + snapshot cache + update queue

ACP 侧还做：

- 全量 `hardwareProcessObjectList` 枚举（`_updateProcessListLocal:`）
- 同名多 PID 显示为 `Name (pid)`（`_updateProcessDisplayNames`）
- `isProcessExcludedWithBundleID:` / `Name:` + `exemptProcesses`

**4. 策略文件 `SSAudioPolicy.plist`**

| 键 | 用途 |
| --- | --- |
| `ignored` | ~50 条 daemon/自身/WebKit.GPU 等不进列表 |
| `groups` | Teams/Steam/Firefox/Music+AirPlayHelper 等合并为一个逻辑源 |
| `neverCapture` | 禁止 tap |
| `deferred` | 特殊延后处理（Pro Tools） |

**5. UI 产品模型：Favorites 常驻**

主程序字符串明确：

> Favorites are shown at all times, so settings are always adjustable.

即：**收藏/常驻项永远可见**；活跃项另算。这和 ToolBox「已保存规则始终显示」是同一产品形态。

### 对 ToolBox 的可参考改进（按优先级）

1. **P0 — 活跃位改读 `IsRunning`（`pir?`），不要只信 `IsRunningOutput`（`piro`）**  
   Spotify 本机探针两者都可能是 0，但 Chrome helper 等会只有 `piro=1`；双读更稳。
2. **P0 — 可见性 = 活跃 ∪ 最近活跃 ∪ 已保存规则（Favorites 等价）**  
   已部分落地「已保存规则」；补 `recentlyActive`（例如 5–15s 滞回）可减少 Spotify 闪隐。
3. **P1 — 读 `kAudioProcessPropertyDevices`（in/out scope）作辅助活跃信号**  
   SoundSource 即使 `isRunning` 抖动，仍用设备关联差分。
4. **P1 — `parentPIDMap` + `groups` 最小实现**  
   把 helper 合并到主 app，避免列表碎裂/识别错身份。
5. **P2 — 策略 plist 化**  
   把 ignored/groups/neverCapture 从硬编码迁到资源文件，对齐 `SSAudioPolicy.plist`。
6. **P2 — 显式 Favorites / Pin**  
   比「改过一次音量就永久规则」更清晰；可清除、可排序。

### 与 Spotify 空列表的对应关系

本机：`com.spotify.client` 在 HAL 中，但 `isRunning=isRunningInput=isRunningOutput=0` 且 `devices=[]`。  
SoundSource 仍能控它，靠的是：**完整进程目录 + Favorites/配置常驻 + recentlyActive 滞回 + 多信号活跃**，而不是「等 piro=1 才出现」。

---

## 结论（先读）

当前故障是**两条独立链路**叠加，不是单一 bug：

| 现象 | 根因级别 | 结论 |
| --- | --- | --- |
| 音量怎么调都没反应 | **管线 / 生命周期** | UI 数字会变，但要么**根本没建 route**，要么 route 建了但 **capture→gain→output 没有有效音频**；`applyRuntimeGain` 只在已有 active plan 时生效 |
| 小红书识别不到 / 很怪 | **进程目录 / UI 投影** | HAL 里其实有 `com.xingin.discover`，但列表**只展示 `IsRunningOutput==true` 的进程**；未播放时不出现，且无 SoundSource 的 helper/分组/父进程映射 |

小红书本机实测（调研时）：

```
HAL pid=51749 bid=com.xingin.discover name=rednote IsRunningOutput=0
路径：…/Wrapper/discover.app/discover  （iOS-on-Mac / 包装壳）
```

---

## 1. SoundSource 真实架构（IDA 事实）

主二进制 `SoundSource` 几乎不做音频图，核心在两个框架：

```
UI / VolumeController / SourceView
        │
        ▼
SSAudio.framework          产品策略层
  SSAudioProcessManager    进程目录 + 身份映射
  SSAudioTap / TapConfig   per-app tap 规格
  SSAudioTapModel          volume / boost / effects
  SSAudioExclusions        用户排除
  SSAudioPolicy.plist      ignored / groups / neverCapture
        │
        ▼
ACP.framework              HAL 控制平面
  ACPProcessManager        runningProcesses / exclude
  ACPCATapNode             AudioHardwareCreateProcessTap
  ACPAudioAggregateContext 真实 subdevice + taps 构图
  ACPSource.setVolume:     用户态 gain（clamp 0…1）
  ACPPlayer / SessionRunner IO 图
        │
        ▼（可选，我们不做）
ECAudiod / ARK 驱动        旧系统 / 虚拟设备路径
```

### 1.1 音量分层（为什么「有反应」）

SoundSource 不是改 `kAudioDevicePropertyVolumeScalar` 当 per-app 音量。

| 层 | 类 / 字段 | 作用 |
| --- | --- | --- |
| per-app gain | `ACPSource.setVolume:` / `SSAudioTapModel.volume` | 捕获流上软件增益 |
| 设备虚拟键 SVK | `ACPDevice.SVKVolume` | 无硬件音量设备 + 媒体键 |
| 切换静音 | `beginDeviceChangeMuting` | 防爆音 |
| mute 原路径 | `CATapMuteBehavior` / `ACPMutingMode*` | 避免原声 + 处理后声叠音 |

`-[ACPSource setVolume:]` 反编译结果：简单 clamp 到 `[0, 1]` 写 `_volume`，**真正起作用的是下游 DSP/IO 已在跑**。

### 1.2 Aggregate 构图（关键差异）

`ACPAudioAggregateContext._createAggregateDevice`：

- 枚举 **真实设备 UID 列表** 填 `subdevices`
- `_clockSourceUID` → `"master"`
- tap UID 列表进 `taps`
- `private` + `tapautostart`

即：**真实输出作时钟源 + tap 作 sub-tap**。

### 1.3 进程识别（为什么 SoundSource「看得到」更多应用）

`SSAudioProcessManager` 维护多张表，而不是只读 HAL 再 filter `IsRunningOutput`：

| 表 | 用途 |
| --- | --- |
| `runningApplicationSnapshotsByPID` | `NSRunningApplication` 快照 |
| `runningApplicationByBundleID` | 主应用身份 |
| `runningApplicationIdentityByPID` | PID → `ProcessIdentity` |
| `parentPIDMap` | **helper → 父应用** 映射 |
| `PIDToSSAudioProcessMap` / `SSAudioProcessMap` | 多进程合并到同一逻辑应用 |
| `processesSnapshotCache` | 对外查询缓存 |
| `lastRunningProcesses` | 差分更新 |

另有 `SSAudioPolicy.plist`：

- `ignored`：系统 daemon / 自身 / WebKit.GPU 等不展示
- `groups`：Teams helper、Steam helper、Firefox plugincontainer 等合并
- `neverCapture`：禁止 tap 的名单

`ACPProcessManager` 侧还有 `isProcessExcludedWithBundleID:` / `Name:` 与 `exemptProcesses`。

---

## 2. ToolBox 当前实现对照

### 2.1 音量路径

```
UI stepVolume / setVolume
  → AudioRoutingService.mutateRule (写 volumePercent)
  → applyRuntimeGainIfPossible?   // 仅当 appliedPlans 已有该 bundle 的 source
       成功 → engine.update(gain)  // 原子改 gain，不重建
       失败 → reconcile()          // RoutePlanCompiler → 建/毁 tap+aggregate+IOProc
```

`RoutePlanCompiler` 关键门闩：

```swift
let requiresGain = rule.volumePercent != 100
let requiresDeviceOverride = selectedUID != nil && selectedUID != defaultOutputUID
guard requiresGain || requiresDeviceOverride else {
    // planned(routeID: nil) —— 不建任何 tap
}
```

因此：

1. **默认 100%**：列表上有应用时只是「原生输出」，滑条若仍显示 100，**预期就是无声变化**。
2. 改到 ≠100% 时必须 **成功 startRoute**，否则只有规则持久化，听感无变化。
3. `applyRuntimeGainIfPossible` 在 **还没有 appliedPlans** 时恒返回 false，完全依赖 `reconcile`。

### 2.2 Engine 构图（与 SoundSource / 设计文档冲突）

`AudioRouteEngine.mm` 当前 composition：

```objc
NSDictionary* composition = @{
    name, uid,
    kAudioAggregateDeviceIsPrivateKey: @YES,
    kAudioAggregateDeviceTapAutoStartKey: @YES
    // 无 subdevices / master / taps 在创建字典里
};
AudioHardwareCreateAggregateDevice(...);
// 事后 SetStringList(..., kAudioAggregateDevicePropertyTapList, @[tapUUID]);
// 输出走「物理设备独立 OutputIOProc」，capture 走 aggregate 的 CaptureIOProc
```

仓库内 **两份设计文档互相矛盾**：

| 文档 | Aggregate 策略 |
| --- | --- |
| `docs/research` 旁的 break 设计 / `PER-APP-AUDIO-DESIGN.md` | 必须有真实 subdevice 作 master + taps |
| `docs/superpowers/specs/2026-07-21-per-app-audio-routing-design.md` | 刻意 **tap-only capture Aggregate** + 独立物理 output IOProc |

ToolBox 实现跟了后者。若 tap-only 在当前 macOS 版本上：

- `ValidateCaptureDevice` 过了但 **capture 回调零帧**，或
- `tapautostart` 一直等不到音频，或
- 采样率/格式与 output 不匹配触发 `fatalCallbackMismatch`

则用户体感就是：**UI 百分比变了，声音完全不变**（或静音后无恢复，取决于 mute 是否已生效）。

`CATapMutedWhenTapped` 只有在 tap **真正被读取** 时才 mute 原路径；若 capture 从未回调，原声继续，gain 也无从施加 → 「怎么调都没反应」。

### 2.3 识别路径（小红书）

`AudioProcessRegistry`：

1. `kAudioHardwarePropertyProcessObjectList`
2. 读 `PID` / `BundleID` / `IsRunningOutput`
3. **`bundleID.isEmpty` → 丢弃**
4. 显示名：`NSWorkspace.runningApplications[pid]`，否则回落 bundleID

`AudioRoutingService.rebuildRows`：

```swift
// 只有「已有规则」∪「当前 IsRunningOutput==true」才进列表
let bundleIDs = Set(rules.map(\.bundleID))
    .union(processes.filter(\.isRunningOutput).map(\.bundleID))
```

菜单面板再 `rows.prefix(4)`，最多 4 行。

本机 HAL 快照：

- `com.xingin.discover` **在列表中**，`IsRunningOutput=0`（未在播时）
- 同时 `runningOutput count = 0`（当时无任何应用被 HAL 标为正在输出）
- NSWorkspace 侧显示名是 **`rednote`**，不是「小红书」
- 路径是 iOS Wrapper：`…/Wrapper/discover.app`，`CFBundleIdentifier = com.xingin.discover`

所以「打开小红书也认不出」在当前逻辑下是 **预期行为**：  
打开 ≠ `IsRunningOutput`；只有真正出声且 HAL 置位后才进 UI。  
即便出声，显示名也可能是 `rednote` / bundle 字符串，用户以为「没识别」。

对比 SoundSource：

- 用 `runningApplications` + ACP 进程列表交叉，不只靠 `piro`
- `parentPIDMap` / groups 处理 helper
- 策略过滤噪声进程，而不是「空 bundle 一律扔 + 仅 running 才显示」

---

## 3. 因果链（对应两个用户症状）

### 3.1 「音量怎么设都没反应」

最可能顺序：

```
用户点 +/- 
  → volumePercent 更新（UI 有反馈）
  → appliedPlans 为空 → 跳过 runtime gain
  → reconcile：volume≠100 → 尝试 startRoute
       A. start 失败（权限 / ValidateCapture / CreateAggregate / Start）
          → state=failed，原声继续 → 听感无变化
       B. start 成功但 capture 零帧（tap-only 时钟/格式问题）
          → MutedWhenTapped 不生效 + ring 空 → output 静音或原声
          → gain 改了也听不到差
       C. 应用根本不在 rows / 无 process 匹配
          → 只写了规则，waitingForProcess → 无 tap
```

次要因素：

- 未授予 **系统音频捕获**（`NSAudioCaptureUsageDescription` 已有，但 UI 未必强提示）
- `prefix(4)` 把目标应用挤出可见区，用户调的不是以为的那个应用
- 多进程同一 bundle 时 `Dictionary(uniquingKeysWith:)` 只留一条 process 快照，tap 绑错 objectID

### 3.2 「小红书无法识别 / 很奇怪」

```
小红书在 HAL：bid=com.xingin.discover ✓
显示名：rednote（不是「小红书」）
IsRunningOutput：未播放时为 0
rebuildRows：过滤掉 → 列表不出现
SoundSource：仍可通过 runningApplications / 进程表看到并可 pin
```

iOS-on-Mac 包装还会带来：

- 音频可能经 helper / 系统中介（需在播放时再采一次 `piro` 与 `pdv#`）
- 无 `SSAudioPolicy.groups` 时无法把 helper 并到主 app

---

## 4. 修复优先级（建议实现顺序）

### P0 — 让「调音量」真的动音频

1. **启动 route 时打诊断日志 / UI 状态**：`CreateProcessTap` / `CreateAggregate` / `AudioDeviceStart` / capture&output callback 计数；失败文案进 `globalError`，禁止 silent fail。
2. **校验 tap-only Aggregate 在本机是否出 PCM**  
   - 若 capture 恒为 0：按 SoundSource/`PER-APP-AUDIO-DESIGN` 改回  
     `subdevices=[defaultOutputUID] + master + taps=[tapUUID]` 构图，或  
     采用单全双工 Aggregate + 单 IOProc（设计 B）。  
   - 接受测试：Spotify / Music / 小红书播放时 `captureFrameCount` 增长，`gain=0` 应静音，`gain=0.5` 明显变小。
3. **权限**：首次 `volume≠100` 时检查系统音频录制授权；拒绝则固定 degraded 并链到设置，而不是假「已生效」。

### P1 — 识别与列表

1. **列表策略改为 SoundSource 风格子集**：  
   - 展示：`HAL 全量（过滤 ignored）` ∪ `NSRunningApplication` 前台/最近活跃  
   - `IsRunningOutput` 只作「正在播放」角标，**不作入表条件**
2. **显示名**：`NSWorkspace.localizedName` → `CFBundleDisplayName`（从 bundle path）→ bid；小红书应显示 Info.plist 的「小红书」而不是 `rednote`。
3. **空 bundleID**：用 PID → `NSRunningApplication.bundleIdentifier` / 可执行路径回填，不要直接丢。
4. **helper 合并（最小版）**：同 team / 父 PID / 已知后缀 `.helper` 归并到主 bundle（对照 `SSAudioPolicy.groups`）。
5. 面板 `prefix(4)`：保留最近播放 + 有自定义规则的优先，避免挤掉正在调的应用。

### P2 — 对齐 SoundSource 但不引入 ARK

| 做 | 不做 |
| --- | --- |
| Process catalog + policy ignored/groups | ECAudiod / ARK 驱动 |
| per-app gain + MutedWhenTapped | 设备 SVK（可后续） |
| Aggregate 时钟正确 + 失败恢复原声 | 完整 AU 效果链 |

---

## 5. 建议的最小复现实验

1. 打开 Spotify，播放中；看 ToolBox 是否出现 Spotify，`IsRunningOutput` 是否 1。  
2. 将 Spotify 调到 50%：  
   - 若 UI 变、声音不变 → 查 `globalError` / diagnostics `captureFrameCount`。  
   - `captureFrameCount==0` → Aggregate/构图问题。  
   - `captureFrameCount>0` 且 gain 不生效 → `updateGain` / 混音路径问题。  
3. 打开小红书但不播放：当前实现**不应**出现；播放 3 秒后再看 HAL `piro` 与 UI。  
4. 对照 SoundSource 同场景是否始终列出 `rednote`/小红书。

---

## 6. 代码锚点

| 区域 | 路径 |
| --- | --- |
| 列表过滤 | `AudioRoutingService.rebuildRows` |
| 空 bid 丢弃 | `AudioProcessRegistry.project` |
| 仅 ≠100% 建 route | `RoutePlanCompiler.compile` |
| runtime gain 捷径 | `AudioRoutingService.applyRuntimeGainIfPossible` |
| Aggregate 构图 | `AudioRouteEngine.mm` `startRouteWithIdentifier:…` |
| UI 只显示 4 行 | `AudioRoutingPanel` `prefix(4)` |
| SoundSource 策略 | `SSAudio.framework/.../SSAudioPolicy.plist` |
| SoundSource 进程表 | `SSAudioProcessManager`（parentPIDMap 等） |
| SoundSource Aggregate | `ACPAudioAggregateContext._createAggregateDevice` |

---

## 7. IDA 会话备忘

分析时打开过：

- `/…/SoundSource.app/Contents/MacOS/SoundSource.i64`
- `/…/SSAudio.framework/Versions/A/SSAudio` → 生成 `SSAudio.i64`
- `/…/ACP.framework/Versions/A/ACP` → 生成 `ACP.i64`

会话可能在空闲后回收；需要时用 `idb_open` 重新挂载上述路径即可。
