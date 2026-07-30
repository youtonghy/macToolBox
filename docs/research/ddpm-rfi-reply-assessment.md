# DDPM RFI 答复复核与实施建议

日期：2026-07-30

复核对象：`/Users/youtonghy/Downloads/break/DDPM/10-rfi-reply.md`

## 1. 总体结论

这份 RFI 答复显著提高了原文档的可用性，特别是补充了 DDPM 二进制中的函数地址、三类 DDC 路径、Capability String 分块读取、checksum 和型号映射逻辑。

但它目前仍不能直接作为 macToolBox 的权威实现规范，原因有三类：

1. `[已验证]` 实际只表示“从 DDPM 二进制中看到了对应逻辑”，不表示符合 MCCS 规范，也不表示显示器已经实测通过。
2. 部分协议字段和 macOS API 的解释存在明确错误。
3. 多处将通用经验或实现建议写成接近确定事实的结论，适用范围并未被型号、固件和实机数据证明。

建议当前将其定位为：

> **DDPM 逆向实现参考 v1，而不是 macToolBox 生产实现规范。**

在修正本复核列出的 P0 问题后，可以开始实现 Capability String 读取和受限的 `0x14` 色彩预设 POC；RGB Gain、ICC 自动联动和 HDR 判断仍不应直接进入正式功能。

## 2. 答复状态总表

| 问题 | 当前状态 | 复核结论 |
|---|---|---|
| Q1 Capability 命令 | 部分闭环 | `0xF3` 和调用路径可信，可进入 POC；仍缺实机报文 |
| Q2 Get VCP 布局 | 需要修正 | 11 字节结论合理，但对 `[3]`、`[4]` 的规范解释写反 |
| Q3 读取失败语义 | 未闭环 | 与 Q2 冲突，且把“未声明”“不支持”“哨兵值”混为一类 |
| Q4 Capability 失败降级 | 设计已明确 | fail-closed 方向可接受，实验模式仍需进一步限权 |
| Q5 `0x14` 映射 | 部分闭环 | Dell 型号覆盖逻辑可信，但没有区分 MCCS 标准值和 Dell 扩展/覆盖 |
| Q6 Capability 解析 | 部分闭环 | 可以指导新解析器，但 `0x14` 无子值时不能按连续型处理 |
| Q7 Apple Silicon Capability | 部分闭环 | 证明代码路径存在，不能据此声称“可靠读取” |
| Q8 写后读回 | 未闭环 | DDPM 时序与推荐时序混杂，RGB 不读回建议无证据 |
| Q9 preset 副作用 | 未闭环 | 大部分仍是经验推断，缺少型号和固件矩阵 |
| Q10 HDR | 需要重大修正 | 使用的是 EDR 能力值，不是当前 HDR 开关状态 |
| Q11 checksum | 部分闭环 | 公式可用于单元测试，仍需原始响应和多后端验证 |
| Q12 RGB Gain | 未闭环 | 反而确认 DDPM 没有可复用实现，必须独立实测 |
| Q13 MinLu | 部分闭环 | 反编译公式更完整，但缺少 UI 范围和调用现场，不能直接采用 |
| Q14 USB SDK | 部分闭环 | 重试逻辑可信；成功语义和许可结论仍缺 SDK/EULA 证据 |
| Q15 cleanDDCCI | 需要复核 | 循环伪代码中的 `if (err) break` 与“失败重试三次”矛盾 |
| Q16 ColorSync 注册 | 未闭环 | API 存在已确认，但注册策略和示例仍只是未经验证的建议 |
| Q17 ICC 应用确认 | 未闭环 | 需要 POC；通知常量名称还写错 |
| Q18 preset ↔ ICC 映射 | 部分闭环 | DDPM 行为较清楚，但不代表 macToolBox 应复制该安全模型 |
| Q19 ICC 状态机 | 未闭环 | DDPM 行为得到解释，但串行队列不足以防循环或过期操作 |
| Q20 定时切换 | 可延期 | 可作为产品参考，暂不应影响基础架构 |
| Q21 按应用切换 | 需要修正 | 串行队列不是 debounce，反而可能累计全部过期操作 |
| Q22 远程 ICC | 需要修正 | 未签名 HTTP + SHA256 不能提供可靠来源认证 |

## 3. 必须退回提供方修正的 P0 问题

### 3.1 Q2：Get VCP Reply 的 `[3]` 和 `[4]` 解释写反

RFI 答复给出的实际布局：

```text
[2] Get VCP Feature Reply = 0x02
[3] 未解释
[4] VCP code echo
[5] VCP type
```

这本身与 macToolBox 当前解析逻辑一致，但文档随后声称：

> MCCS 规范说 `[3]` 是 VCP code echo、`[4]` 是 result code。

这句话需要修正。标准 Get VCP Feature Reply 中：

- `[3]` 是 result code；
- `[4]` 是 VCP opcode echo；
- `[5]` 是 VCP type；
- `[6...7]` 是 maximum value；
- `[8...9]` 是 current value。

因此 DDPM 检查 `[4] == requestedVCP` 并不违反标准。

这还会影响 Q3：如果 `[3]` 非零，它正是协议层显式“不支持”结果，不能说 DDPM Reply 中没有不支持状态。

macToolBox 当前的 `DDCFeatureReplyParser` 已按 `[3]` 为状态、`[4]` 为 VCP echo 解析；不应依据 RFI 这段错误描述反向修改。

### 3.2 Q3：必须拆分五种不同语义

RFI 建议的枚举仍然过度合并：

```swift
case unsupported // 0xFFFF 或 cap string 未声明
```

以下状态不应归为同一个 `unsupported`：

1. Reply result code 明确表示不支持；
2. Capability String 没有声明该 VCP；
3. Capability String 声明了 VCP，但没有公布枚举子值；
4. 当前值为 DDPM 内部哨兵 `0xFFFF`；
5. 传输成功，但无法确认该功能是否支持读取。

建议逻辑层至少保留以下概念：

```swift
enum DDCReadOutcome {
    case success(DDCReadResult)
    case unsupportedReply(resultCode: UInt8)
    case malformedReply
    case checksumFailure
    case transportFailure
}

enum DDCAdvertisedSupport {
    case advertised
    case notAdvertised
    case advertisedWithoutValues
    case unavailable
}
```

是否合并为较简单的 public API，可以在上层决定；底层不应过早丢失原因。

“写入支持但读取不支持”也不能仅凭一次或多次读取失败推断。它只能来自明确的型号规则、厂商说明或实机验证。

### 3.3 Q5：`0x14` 不能整体描述为“不是 MCCS 标准定义”

更准确的结论应是：

- `0x14` 作为 Select Color Preset 属于 MCCS 体系；
- MCCS 定义了一部分标准 preset 值；
- Dell 又根据型号和固件增加、覆盖或重新命名了一些值；
- Capability String 只提供当前设备公开的值集合，不能单独提供完整的人类可读语义。

新版文档应分别列出：

1. MCCS 标准值；
2. Dell 通用值；
3. Dell 型号/固件覆盖值；
4. 未知值的 UI 策略。

不能把某台 Dell 显示器的 `0x0B = sRGB` 推广给所有显示器。

### 3.4 Q6：`0x14` 没有子值时不能“按连续型处理”

`0x14` 是枚举型功能。Capability String 中出现 `14` 但没有 `14(...)` 时，只能说明：

- 显示器声称支持该 VCP；
- 当前没有得到允许值列表。

安全策略应该是：

- 普通 UI 不展示可写枚举选项；
- 已验证型号可以通过 allowlist 补充；
- 调试模式可以展示原始信息；
- 不能把 `0x14` 当成连续滑块，也不能枚举盲写。

### 3.5 Q7：“存在 Apple Silicon 调用路径”不等于“可靠”

反编译可以证明 DDPM 尝试通过 IOAVService 读取 Capability String，但不能证明：

- 所有 Apple Silicon 芯片都成功；
- HDMI、DP、USB-C、Thunderbolt 和扩展坞行为一致；
- MST 或多显示器映射准确；
- 返回长度和错误恢复在所有 macOS 版本相同。

Q7 标题和结论应改为：

> `[已验证：代码路径] DDPM 在 Apple Silicon 上实现了 Capability String 读取。实际兼容性待实测。`

### 3.6 Q8：不能采用“RGB Gain 不读回”

RFI 一方面确认 DDPM 没有直接 RGB Gain 控制，另一方面又建议 RGB 写入后不读回。这项建议没有 DDPM 证据，也没有实机依据。

在完成 POC 前，RGB Gain 应保持未实现。以后如果实现，应：

- 优先读取 Capability String；
- 读取每个通道的 maximum/current；
- 写后读回；
- 明确当前 preset 是否允许调整；
- 单个通道失败时把整体状态标记为部分失败，而不是静默成功。

### 3.7 Q9：preset 副作用仍属于待实测

以下描述都不能作为跨型号规则：

- 大多数显示器切 sRGB 后会重置亮度；
- RGB Gain 只在 `0x14 = 0x14` 时可用；
- HDR 下一定禁用亮度和对比度；
- 切 preset 后固定等待 300 ms。

新版文档应把这些内容标为 `[待实测]` 或限定到明确型号/固件。

macToolBox 可以采用保守刷新策略：

1. preset 写入并验证；
2. 延迟后重新读取亮度和对比度；
3. 将 RGB、ICC 等相关状态标记为 stale；
4. 不假设具体值一定被重置或锁定。

### 3.8 Q10：`maximumPotentialExtendedDynamicRangeColorComponentValue` 不是当前 HDR 状态

Apple SDK 对该属性的定义是：

> 显示器在启用扩展动态范围时能够达到的最大分量值，与当前是否启用无关。

因此：

```swift
screen.maximumPotentialExtendedDynamicRangeColorComponentValue > 1
```

只能说明显示器具有 EDR/HDR 能力，不能说明系统当前开启了 HDR。

同一 SDK 还提供：

```swift
screen.maximumExtendedDynamicRangeColorComponentValue
```

它表示当前可用的最大 EDR 分量，但也不应未经 POC 就等同于系统设置中的“HDR 开关”。

另外，通过 `NSScreen.localizedName` 匹配显示器不可靠：多台同型号显示器可以同名。应优先使用 `CGDirectDisplayID` 或系统提供的屏幕身份映射。

因此当前不能实现“根据 macOS HDR 开关阻止 preset/ICC 切换”。短期策略应是：

- 不宣称能够读取或切换系统 HDR；
- 不使用 potential EDR 作为当前 HDR 状态；
- 在 ICC POC 完成前不启用 HDR 自动联动。

### 3.9 Q14：SDK 许可不能通过反编译标记为 `[已验证]`

“Dell 私有 SDK 不可重新分发”是很可能正确的风险判断，但二进制反编译不能证明法律授权范围。

需要的证据应是：

- Dell SDK EULA；
- 软件包许可证；
- Dell 的书面授权说明；
- 公开发布条款。

在没有许可前，macToolBox 不使用或分发 Dell SDK 的决定是正确的；但新版文档应把原因写成“没有获得可分发授权”，而不是声称已经完成法律事实验证。

### 3.10 Q15：`cleanDDCCI` 重试伪代码自相矛盾

RFI 给出的代码：

```c
for (i = 0; i < 3; i++) {
    usleep(60000);
    kern_return_t err = IOAVServiceWriteI2C(...);
    if (err) break;
}
```

按照 `kern_return_t == 0` 表示成功的常规语义，这段代码会在第一次失败时退出，而不是失败后重试三次。

提供方需要重新核对：

- 分支是否在伪代码中写反；
- 原始汇编跳转条件；
- 三次循环是在成功时继续清理，还是在失败时重试；
- `cleanDDCCI` 的返回值最终如何影响真实操作。

在问题澄清前，macToolBox 不应复制这段重试逻辑。

### 3.11 Q16/Q17：ColorSync 示例仍需修正和 POC

当前 SDK 可以确认：

- `ColorSyncDeviceSetCustomProfiles` 是公开 API；
- custom profile 的 key 必须是设备注册过的 Profile ID 子集，或者 `kColorSyncDeviceDefaultProfileID`；
- `ColorSyncDeviceCopyDeviceInfo` 可以查询 factory/custom profile 信息；
- 可以使用 `ColorSyncIterateDeviceProfiles` 判断 `kColorSyncDeviceProfileIsCurrent`；
- 正确通知常量为 `kColorSyncDeviceProfilesNotification`，RFI 中的 `kColorSyncDeviceProfilesNotificationNotification` 是笔误。

RFI 中以下建议仍没有依据：

- 查不到设备就由应用注册；
- 注册后永远不取消；
- 注册操作是幂等的；
- UUID 重插后通常稳定；
- Hardened Runtime 或 App Sandbox 下一定可用。

macToolBox 当前启用了 Hardened Runtime，但没有启用 App Sandbox。仍需制作独立 POC，不能先把注册逻辑放入正式显示器控制路径。

建议 POC 顺序：

1. 使用 `CGDisplayCreateUUIDFromDisplayID` 获取 UUID；
2. 只查询，不注册；
3. 枚举当前 profile；
4. 对测试 ICC 调用 `ColorSyncDeviceSetCustomProfiles`；
5. 等待 ColorSync 和屏幕颜色空间通知；
6. 再次枚举并确认 current profile；
7. 测试显示器重插、应用重启和 Hardened Runtime 签名版本。

### 3.12 Q19/Q21：串行队列不是循环抑制，也不是 debounce

串行队列只能保证操作不同时执行，不能：

- 阻止 DDC → ICC → DDC 回环；
- 合并快速连续操作；
- 取消已经过期的 preset 切换；
- 保证多显示器操作互不干扰。

如果每次前台应用变化都入队，串行队列会依次执行全部旧操作，效果正好与 debounce 相反。

正式实现至少需要：

- operation origin：user、DDC sync、ICC sync、schedule、application；
- per-display generation；
- latest-wins 合并；
- 当前操作的 suppression token；
- 显示器离线时取消该显示器的 pending 操作。

第一版建议只实现用户触发的单向流程：

```text
HDR/能力 preflight
  → 写 DDC preset
  → 读回确认
  → 刷新相关 DDC 状态
  → 可选写 ICC
  → ICC 失败则进入 hardwareOnly
```

暂不实现 ICC → DDC 反向同步。

### 3.13 Q22：HTTP + SHA256 不能证明下载来源可信

如果 hash 和文件都从同一个未认证或可被篡改的通道下载，攻击者可以同时替换文件和 hash。

SHA256 只有在以下条件之一成立时才能提供有效的完整性保证：

- 可信的 hash 内置在应用中；
- manifest 使用应用内置公钥验证数字签名；
- 通过正确验证证书的 HTTPS 获取，并且服务端供应链同样受控。

因此“只有 hash 可以防篡改”的表述需要删除。

macToolBox 第一版不实现远程 ICC 下载，也不分发来源和许可证不明确的 Dell ICC 文件。

## 4. 对当前 macToolBox 实现的影响

当前未提交的代码已经具备两个良好基础：

- `DDCFeatureReplyParser` 按 `[3]` 为 result、`[4]` 为 VCP echo 解析；
- `DDCCapabilityParser` 能提取 `0x14` 和 `0x60` 的嵌套允许值，并对缺失 `vcp(...)` 的输入 fail closed。

但它们目前尚未形成完整功能：

1. `DarwinDisplayControlProvider` 仍调用兼容接口 `transport.read(...)`，没有消费 `DDCReadOutcome`。
2. `DDCReadOutcome` 仍把 checksum、格式、echo 和传输失败统一成 `transientFailure`。
3. Capability parser 只有字符串解析，没有 Intel/Apple Silicon 分块读取和 per-display 缓存。
4. Capability 结果尚未用于控制 UI 可见性和允许值。
5. 现有测试使用合成报文，没有硬件抓包测试向量。

因此当前代码可以保留，但不应据此宣称色彩预设已经具备生产级能力。

## 5. 推荐的实施范围

### 第一阶段：可以继续

目标是建立安全的能力探测基础，不立即开放正式色彩 UI：

1. 完成 Intel 和 Apple Silicon Capability String 分块读取。
2. 严格校验长度、offset、checksum 和结束块。
3. 建立 per-display capability cache，并在断开、重连或固件身份变化后失效。
4. 将 Reply result、checksum、格式和 transport failure 保留为不同内部原因。
5. 对 `0x14` 使用 fail-closed：
   - 没有 Capability String：不展示；
   - 有 `0x14` 但没有允许值：不展示可写选项；
   - 有允许值：只展示该集合；
   - 未知映射：显示原始值或隐藏，不猜测名称。
6. 功能先放在开发开关后，仅用于硬件验证。

### 第二阶段：需要硬件结果后继续

1. 在 allowlist 显示器上写 `0x14`；
2. 写后等待并读回；
3. 重新读取亮度、对比度及其他已支持控制；
4. 记录切换前后原始值和错误；
5. 根据型号、固件和 Capability String 建立经过验证的名称映射。

### 暂缓

- RGB Gain；
- MinLu 特殊映射；
- ICC 自动切换；
- ICC → DDC 反向同步；
- HDR 自动判断或联动；
- 定时色域；
- 按应用色域；
- 远程 ICC 下载。

## 6. 必须完成的 POC 和实机验证

### DDC 协议

- Intel Get VCP 正常和 unsupported Reply；
- Apple Silicon Get VCP 正常和 unsupported Reply；
- checksum 错误；
- VCP echo 错误；
- Capability String 至少两个非空分块及一个零长度结束块；
- Capability String 读取中途失败和恢复；
- RTK `cleanDDCCI` 前后效果；
- `0x14` 写入、读回和副作用；
- 显示器断电重连后的 capability cache 失效。

### 显示器范围

- 至少一台 Dell 已知型号；
- 至少一台 Dell 未知型号；
- 至少一台非 Dell DDC/CI 显示器；
- Apple Silicon 直连；
- HDMI 和 USB-C/DP；
- 一种扩展坞连接；
- 如果仍支持 Intel，则补一台 Intel Mac。

### ICC

- 查询系统已注册的显示器；
- 枚举 factory/custom/current profile；
- 设置和恢复测试 profile；
- ColorSync 通知与 `NSScreenColorSpaceDidChangeNotification`；
- Hardened Runtime 签名构建；
- 重插、多台同型号显示器和失败恢复。

## 7. 建议回复提供方的修订要求

可以将以下内容直接发回：

> 感谢本次 RFI 答复。反编译调用路径已经解决了大量问题，但请在生成 `11-authoritative-spec.md` 前继续修正以下内容：
>
> 1. Q2 中 MCCS 字段说明写反：`[3]` 应为 result code，`[4]` 应为 VCP opcode echo。请同步修正 Q3 的 unsupported 语义。
> 2. 请区分“不支持 Reply”“Capability 未声明”“没有枚举子值”“DDPM 0xFFFF 哨兵”和“读取失败”。
> 3. Q5 请分别列出 MCCS 标准值、Dell 通用映射及型号/固件覆盖，不要把 `0x14` 整体描述成非标准。
> 4. Q6 请删除“`0x14` 无子值时按连续型处理”，统一改为 fail-closed。
> 5. Q7 请将“可靠读取”改为“实现了读取代码路径，兼容性待实测”。
> 6. Q8 请删除未经验证的 RGB Gain 不读回建议。
> 7. Q9 中所有跨型号副作用和固定 300 ms 时序请标为待实测。
> 8. Q10 使用的是 `maximumPotentialExtendedDynamicRangeColorComponentValue`，它表示潜在能力而非当前 HDR 状态。请重新评估整个 HDR preflight 结论。
> 9. Q14 中 SDK 许可请提供 EULA 或授权来源，不能以反编译标为已验证。
> 10. Q15 请核对 `if (err) break` 与“三次失败重试”的矛盾，并提供原始跳转逻辑。
> 11. Q16/Q17 请删除未经验证的注册幂等、永不取消注册和 UUID 稳定性结论；通知名称应为 `kColorSyncDeviceProfilesNotification`。
> 12. Q19/Q21 请明确串行队列不等于循环抑制或 debounce，并补充 operation token、generation、合并和取消语义。
> 13. Q22 请删除“未签名 HTTP + SHA256 可以防篡改”的表述；同时把许可结论与技术逆向结论分开。
>
> 新版规范请继续区分“二进制代码路径已确认”和“硬件行为已验证”。对于没有实机结果的内容，不要使用无范围限制的“唯一结论”。

## 8. 需要 macToolBox 决定的产品方向

建议采用以下决策：

1. **能力探测**：必须先读取 Capability String，枚举控制默认 fail-closed。
2. **preset 映射**：只对已验证型号显示友好名称；未知值不猜测。
3. **MinLu**：第一版不引入 DDPM 的型号特例。
4. **RGB Gain**：没有独立实测前不实现。
5. **HDR**：只声明暂不支持系统 HDR 状态判断和切换。
6. **ICC**：完成独立 POC 后，只实现 DDC → ICC 单向同步。
7. **ICC 失败**：硬件不回滚，状态进入 `hardwareOnly` 并允许用户重试。
8. **自动化**：定时、按应用和远程 ICC 均不进入第一版。

按照这个范围，DDPM RFI 已经足以支持“Capability String + 受控色彩预设 POC”，但还不足以支持完整的正式色彩管理功能。
