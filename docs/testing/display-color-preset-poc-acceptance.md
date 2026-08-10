# 显示器 Capability String 与色彩预设 POC 验收记录

## 1. 适用范围

本记录对应 `11-authoritative-spec.md` §12.2 的 Q1-Q10 和 Q20。它用于验证：

- Intel I2C 与 Apple Silicon AVService 的 DDC/CI 读写行为；
- Capability String 分块读取和严格解析；
- 按 Capability String 广告值（Dell `0xE2` 优先，MCCS `0x14` 次之）的通用发现、写入与读回；
- preset 切换对亮度、对比度和 RGB Gain 的可观察副作用。

它不证明 ICC、ColorSync、HDR 状态、RGB Gain 写入、Dell USB SDK 或远程 ICC 下载可用于正式产品。Q11-Q19 需使用各自独立的证据和验收流程。

所有未执行项必须写 `NOT RUN`，不能留空、推断为通过或引用 DDPM 反编译结果代替 macToolBox 实机结果。

## 2. 当前发布门

- 色彩预设按 DDPM 主程序的通用发现方式实现，不再依赖 identity allowlist。
- 凡是 Capability String 广告了 `0xE2(...)`（Dell）或 `0x14(...)`（MCCS）枚举子集，即生成可写选项。
- 名称来自 `DisplayColorPresetDDPMTable`（已用 IDA 逐项核对 DDPM v2.2.0.0024）；查不到的值显示 `Preset 0xXX`。
- 写入目标必须是广告值之一，写后必须读回确认；读回失败或 mismatch 不得报告完整成功。
- 无实验开关；行为直接生效，但仍受第 8 节发布阻断约束。
- 实时 `0xF3` capability 读取失败时，若显示器型号命中已验证回退表，使用该表；当前只包含从 DDPM 自身加密缓存解出的 Dell U2723QE（固件 M2T105）真实广告值。回退仅用于实时 DDC 不可用时，写入仍按广告值校验并读回。

## 3. 诊断采集

使用 Debug 构建：

```bash
CONFIG=Debug OPEN=0 ./build.sh
```

开始测试前启动日志采集：

```bash
log stream --level debug --style compact \
  --predicate 'subsystem == "ToolBox" AND (category == "DisplayControlProvider" OR category == "Arm64DDC" OR category == "IntelDDC")'
```

关键事件：

- `vcp-read`: Get VCP request、原始 reply、解析结果和失败类型；
- `capability-block`: backend、offset、request 和原始 50-byte reply；
- `capability-report`: vendor/model/serial、backend、完整长度和 `0xE2`/`0x14` 广告值；
- `preset-write`: exact identity、backend 和请求值；
- `preset-verify`: 每次读回的 attempt、current、maximum 和 match/mismatch/failure。

日志不得加入用户路径、ICC 内容、用户名、网络标识或无关系统信息。

## 4. 单次观察记录

每完成一个操作新增一行。原始报文使用空格分隔的大写十六进制；超时或无 reply 写明原因。

| Date | Mac/chip | macOS | Connection | Display vendor/model/serial | Firmware | Backend | Operation | Raw request | Raw reply | Result | Spec question |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 2026-07-30 | Apple M5 Pro | 26.5.2 (25F84) | No external display reported | NOT AVAILABLE | NOT AVAILABLE | NOT AVAILABLE | `system_profiler SPDisplaysDataType -json` inventory | N/A | GPU entry only; no display entry | NOT RUN - no eligible hardware | Q1-Q10, Q20 |

## 5. 实测项状态

| Question | Required evidence | Current status |
|---|---|---|
| Q1 | Intel Mac、Dell、非 Dell 的正常、不支持、超时、checksum 错和 write-only 报文 | NOT RUN - 当前无外接显示器，且当前 Mac 非 Intel |
| Q2 | M1/M2/M3/M4 各一次 AVService Capability String | NOT RUN - 当前为 M5 Pro，且无外接显示器 |
| Q3 | Thunderbolt/USB-C hub 与 Daisy-Chain 下的 Capability String | NOT RUN - 当前无目标拓扑 |
| Q4 | 明确不支持 VCP 的 reply result code | NOT RUN - 当前无外接显示器 |
| Q5 | HDR on/off/capable-SDR 下 NSScreen EDR 返回值 | NOT RUN - 不属于当前受控预设 POC，且无外接显示器 |
| Q6 | preset 前后 brightness/contrast/RGB Gain | NOT RUN - 当前无外接显示器 |
| Q7 | `0xE2`/`0x14` 写后 200 ms 与重试次数 | NOT RUN - 当前无外接显示器 |
| Q8 | 0x16/0x18/0x1A 范围和 preset 可写性 | NOT RUN - 第一版禁止 RGB Gain 写入 |
| Q9 | 非 Dell 与畸形 Capability String 实机行为 | NOT RUN - 当前无非 Dell 外接显示器 |
| Q10 | preset/HDR/PiP/输入源切换后的 Capability String 变化 | NOT RUN - 当前无外接显示器 |
| Q20 | 已知支持 VCP 上 `0xFFFF` 的实机语义 | NOT RUN - 当前无外接显示器 |

## 6. 操作步骤

### 6.1 正常 Get VCP

1. 直连一台已知支持 DDC/CI 的显示器并记录线材、端口、固件和 OSD DDC/CI 状态。
2. 在 ToolBox 中读取亮度 `0x10` 或另一个厂商明确支持的 VCP。
3. 保存一条完整 `vcp-read` 日志。
4. 核对 command echo、result code、current、maximum 和 checksum。
5. 在记录表新增一行，结果写 `PASS`、`FAIL` 或具体降级，不写推测。

### 6.2 不支持的 Get VCP 与 result code

1. 从显示器手册或已验证 Capability String 选取明确不支持的 VCP。
2. 只执行 Get VCP，不执行 Set VCP。
3. 保存原始 reply，特别记录 byte `[3]`。
4. 只有实机结果证明非零 result code 对应该显示器的不支持响应后，才可完成 Q4。

### 6.3 超时、checksum 错和 write-only

1. 超时必须来自真实连接故障、测试代理或可控断链，记录是否收到任何 byte。
2. checksum 注错优先使用测试代理或协议分析设备；不能为了造数据修改 production parser。
3. 自动化 checksum fixture 只能证明 parser 分支，不能填写 Q1 的实机 checksum 行。
4. write-only 必须记录 Set 成功后 Get 的真实失败类别，不能把 `nil` 统一解释为不支持。

### 6.4 Capability String 多块读取

1. 清除连接缓存的方法是断开并重新连接显示器，或重启 ToolBox。
2. 从 offset `0x0000` 开始保存所有 `capability-block` 日志，包含重试和零长度终止块。
3. 按 offset 和 payload 长度重组 ASCII 内容。
4. 核对 offset 连续、每块 checksum 正确、总长度不超过 16,384 bytes。
5. 保存对应 `capability-report` 行，把 exact identity 与原始块关联起来。

### 6.5 非 Dell、直连、扩展坞和 Daisy-Chain

对同一台显示器分别执行：

1. Mac 直连；
2. Thunderbolt 扩展坞；
3. USB-C hub；
4. MST/Daisy-Chain（硬件支持时）。

每种拓扑使用独立记录行。连接变化后必须看到新的 connection token 触发重新读取，不能复用上一拓扑的缓存作为证据。

### 6.6 VCP `0xE2`/`0x14` 写入与读回时序

只对 Capability String 明确广告且已枚举的值执行：

1. 记录当前 preset VCP、亮度 `0x10`、对比度 `0x12`，并拍摄 OSD 当前 preset 名称。
2. 使用 raw label 对一个已广告的值执行一次写入。
3. 保存 `preset-write` 和全部 `preset-verify` 行。
4. 记录首次 match 的实际延时和 attempt；分别验证 200 ms、400 ms、600 ms 观察点。
5. 若写入成功但读回失败或不一致，结果必须为失败；不得声称预设已验证，也不得自动回滚硬件。

### 6.7 preset 副作用

每个测试值切换前后记录：

- `0x10` brightness current/maximum；
- `0x12` contrast current/maximum；
- `0x16`/`0x18`/`0x1A` 只读 current/maximum；
- OSD 中控件是否变灰、重置或改变范围；
- Capability String 是否变化。

本步骤禁止写 RGB Gain。不同型号、固件和连接方式分别记录。

### 6.8 `0xFFFF` 哨兵

1. 选择 Capability String 已明确广告的 VCP。
2. 重复读取并保存完整原始 reply。
3. 分别记录 maximum、current 是否为 `0xFFFF`，以及 result code 和 checksum。
4. 只有实机证据可用于判断 sentinel 是暂态异常、write-only 表现还是型号特例；parser 保持 fail-closed。

## 7. 名称来源与未知值展示

### 名称映射

- 名称直接使用 `DisplayColorPresetDDPMTable`，与 DDPM 主程序一致：
  - 基础表来自 `-[AMControl init_ColorPresetDictionary]`；
  - 型号覆盖来自 `-[AMControl CreateColorPresetDictWithE2h:andModelName:]` 和 `-[AMControl updateColorPresetDict:]`（UP32/UP27/standard/U2723QE-family）；
  - 标准家族的 Rec.709 名称按 `GetModelFY:` 的型号年份规则切换。
- 表内没有的值显示 `Preset 0xXX`，并且仍可写入（前提是它来自广告值）。
- 已知名称只表示 DDPM 的名称映射，不代表厂商正式语义；OSD/厂商文档核对仍属于 §12.2 实测项。

## 8. 发布阻断

出现以下任一情况时不得扩大范围：

- Capability String 缺失、畸形、offset 不连续或 checksum 无效；
- 目标 raw value 未广告；
- 写后读回不匹配、全部失败或返回 unsupported；
- sleep、stop、断连后旧 worker 仍发布结果；
- 预设切换导致亮度/对比度不可恢复且没有明确产品策略；
- 任何 Q1-Q10/Q20 未执行却被文档或 UI 表述为已验证。

## 9. 自动化验证结果

验证日期：2026-07-30。

| Check | Command | Actual result |
|---|---|---|
| 全量单元测试 | `xcodebuild test -project ToolBox.xcodeproj -scheme ToolBox -configuration Debug -derivedDataPath /tmp/macToolBox-display-poc-final -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO` | PASS - 357 tests, 0 failures, `TEST SUCCEEDED` |
| Debug 构建 | `CONFIG=Debug OPEN=0 ./build.sh` | PASS - `BUILD SUCCEEDED` |
| Release 构建 | `OPEN=0 ./build.sh` | PASS - `BUILD SUCCEEDED` |
| 基线差异格式 | `git diff --check 8a35f5092adf30dd6b23a44e3db41778cbd30f65..HEAD` | PASS - 无输出 |
| 延后范围扫描 | `rg -n "ColorSync\|maximumPotentialExtendedDynamicRange\|maximumExtendedDynamicRange\|0x16\|0x18\|0x1A\|DellMonitorSdk\|plawebsvc" Sources/ToolBox/DisplayControl` | PASS - 无匹配；未实现 ICC、HDR、RGB Gain 写入、Dell USB SDK 或远程下载 |

自动化只验证代码分支、边界和构建完整性，不能替代外接显示器报文或
ColorSync 行为。第 5 节的 Q1-Q10、Q20 状态仍为 `NOT RUN`。

当前发布结论：

```text
DDPM-COMPATIBLE GENERIC DISCOVERY / NAMES FROM DDPM TABLE / UNKNOWN VALUES SHOW Preset 0xXX
```
