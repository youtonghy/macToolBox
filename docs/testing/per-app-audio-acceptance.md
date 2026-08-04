# 分应用输出音频验收矩阵

## 自动发布门

运行：

```bash
./scripts/verify-audio-routing-build.sh
```

脚本必须通过全量 XCTest、Debug/Release 构建、plist 检查、CoreAudio 链接检查、严格 codesign 校验和 `git diff --check`。自动化测试覆盖规则、route diff、单原子 callback lease 与固定 arena、generation retirement、部分 HAL 枚举失败、事件合并、alive/格式/采样率预检、实时 ring、gain ramp、非有限样本和诊断 watchdog。

设备拓扑或默认输出变化后，路由重建必须重新读取 `kAudioProcessPropertyDevices`。用户选择输出设备后必须立即提交新意图，不等待进程列表的 5 秒稳定窗口；仅重建输出、源进程或捕获格式实际变化的 route，其他 route 的 Tap、Aggregate Device、实时 kernel 和 IOProc 必须保持运行。当目标是系统默认输出但进程仍报告旧设备时，最多等待 225 ms 让输出设备迁移，超时后固定绑定新的默认设备；仅当源设备是单一、双声道且采样率兼容时，Process Tap 才绑定其 output stream，否则保留 stereo mixdown。`kAudioHardwareNotReadyError` 仅对无副作用的 HAL 查询和格式校验最多重试 10 次、每次间隔 25 ms，资源创建和设备启动不原地重试。启动失败必须包含具体阶段与 OSStatus/FourCC，不能统一折叠为 `Start audio route`；若失败启动留下待清理资源，后续 route 创建必须保持阻塞，直到清理完成。

应用停止输出导致 watchdog 释放停滞路由后，如果同一个 HAL 进程对象再次活跃，ToolBox 必须自动重建路由并恢复已保存的音量和输出设备；不得要求用户再次拖动音量滑杆。

首次启动有效的 Process Tap 路由时，macOS 可以弹出“系统音频录制”授权。该流程依赖
`NSAudioCaptureUsageDescription` 和实际的 `AudioDeviceStart`，不得用麦克风权限替代。
授权窗口内新建聚合设备可能暂时没有输入 stream；此时使用 Tap 的真实 ASBD 准备内核与
IOProc，继续走到设备启动，而不是提前报告 `kAudioDeviceUnsupportedFormatError / '!dat'`。
允许、拒绝和在系统设置中重新授权三种结果都必须进入真机矩阵。

蓝牙输出收到 alive/stream/nominal-rate/virtual-format 变化时，必须立即把引用该设备的路由置为暂停；连续 HAL 通知不能重复停止或重建。完整设备配置稳定 1 秒后才允许恢复，HFP 不兼容状态继续暂停，A2DP 兼容状态只恢复一次。设备和进程 HAL 枚举必须在非主线程串行执行，部分读取失败时保留上一份完整快照。USB、HDMI/DP、内建和 3.5 mm 输出不得进入蓝牙即时暂停路径。

2026-07-22 本机基线（macOS 26.5.2、arm64）：全量 XCTest `151 passed / 0 failed / 0 skipped`；AudioRoute lifecycle/realtime/DSP 的 ASan 子集 `16 passed`；lifecycle/realtime 的 TSan 子集 `12 passed`。这些结果证明当前自动化边界，不替代下方设备和真实应用矩阵。

Sanitizer 复核命令：

```bash
xcodebuild test -project ToolBox.xcodeproj -scheme ToolBox -destination 'platform=macOS' \
  -derivedDataPath /private/tmp/mactoolbox-audio-asan CODE_SIGNING_ALLOWED=NO \
  -enableAddressSanitizer YES \
  -only-testing:ToolBoxTests/AudioRouteLifecycleTests \
  -only-testing:ToolBoxTests/AudioRouteRealtimeTests \
  -only-testing:ToolBoxTests/AudioRouteDSPTests

xcodebuild test -project ToolBox.xcodeproj -scheme ToolBox -destination 'platform=macOS' \
  -derivedDataPath /private/tmp/mactoolbox-audio-tsan CODE_SIGNING_ALLOWED=NO \
  -enableThreadSanitizer YES \
  -only-testing:ToolBoxTests/AudioRouteLifecycleTests \
  -only-testing:ToolBoxTests/AudioRouteRealtimeTests
```

## 真机记录字段

每一行记录：日期、macOS build、CPU 架构、应用及版本、脱敏设备标签、transport、采样率、声道、buffer frames、持续时间、额外延迟 p50/p95、CPU、underrun/overrun/resync/non-finite/clipped 计数、结果和备注。

## 必测矩阵

| 维度 | 最低覆盖 |
|---|---|
| 系统 | macOS 14.2/14.4、最新 macOS 15、macOS 26 |
| 应用 | Zoom、Teams、Music、Chrome helper、Safari、一个受保护内容案例 |
| 输出 | 内建、3.5 mm、USB 耳机或 DAC、Bluetooth A2DP/HFP 切换、HDMI/DP、AirPlay、Aggregate/Multi-Output、常见虚拟设备 |
| 场景 | 100%/300%、同设备双应用、不同设备双应用、启动/退出/暂停、设备插拔、睡眠唤醒、profile/采样率变化、权限允许/拒绝/重授、正常退出/强制终止 |

## 压力与发布阻断

- 100 次目标设备插拔、100 次目标应用启动/退出、20 次睡眠/唤醒和 8 小时 Zoom + 媒体播放 soak。
- 有线/USB 在 1 秒内恢复；Bluetooth/AirPlay 在 5 秒内恢复或明确降级。
- 让目标应用持续播放并经蓝牙耳机路由，连续 20 次启动/停止麦克风；每次 HFP 切换期间目标应用和 ToolBox 均可交互，路由只暂停一次，恢复 A2DP 后只重建一次，`coreaudiod` 不出现持续高 CPU。
- 专用 QA 机器手动重启 `coreaudiod`，确认重新枚举、不复用旧 ObjectID、原始应用音频恢复且只重建一套路由。该操作不进入 CI 或产品逻辑。
- 永久静音、虚假 active、跨应用串音、无关 route 被中断、资源单调增长或无法恢复均阻断发布。
- Developer ID、notarization、安装后 TCC 持久性和 Intel 架构需要独立证明；ad-hoc 签名及本机 arm64 构建不能替代这些结果。
