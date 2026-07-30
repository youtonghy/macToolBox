# DDPM 权威规范交付验收

日期：2026-07-30

> **历史状态说明**：本文件记录的是上一版本 `11-authoritative-spec.md` 的有条件验收结果。提供方后续已经完成全部 P0/P1 修订；最终结论见 [ddpm-authoritative-spec-final-acceptance.md](ddpm-authoritative-spec-final-acceptance.md)。

验收对象：

- `/Users/youtonghy/Downloads/break/DDPM/10-rfi-reply.md`
- `/Users/youtonghy/Downloads/break/DDPM/11-authoritative-spec.md`

文件元数据复核：当前 `11-authoritative-spec.md` 实际为 27,377 字节、634 行；交付说明中的“608 行”应是修订前统计，不影响内容验收。

## 1. 验收结论

| 交付物 | 结论 | 说明 |
|---|---|---|
| `10-rfi-reply.md` | **通过** | 顶部已增加 13 行修订记录，逐项列出原结论、修订结论和证据，并保留原始答复供追溯 |
| `11-authoritative-spec.md` | **有条件通过** | 结构、范围约束和证据边界基本合格，但仍有 3 项 P0 和 4 项 P1 问题需要修正 |

当前文档已经足以指导：

- Capability String 读取 POC；
- Get VCP Reply 严格解析；
- fail-closed 的受控 `0x14` 色彩预设 POC。

当前文档仍不足以指导：

- 面向未知显示器的 preset 名称映射；
- RGB Gain；
- HDR 状态判断；
- 正式 ICC 联动；
- USB SDK 集成；
- 定时、按应用和远程 ICC。

## 2. 已达到的交付要求

### 2.1 `10-rfi-reply.md`

已确认：

1. 修订记录位于正文之前。
2. 表格恰好包含 13 条修订。
3. 每条均保留“原结论”和“修订后结论”。
4. 原始 Q1–Q22 答复仍保留。
5. 文档明确说明权威结论转移到 `11-authoritative-spec.md`。

因此该文件可以作为历史追踪材料。

### 2.2 `11-authoritative-spec.md`

已确认：

1. 明确 supersede `03/05/07/08/09` 的协议和设计结论。
2. 13 项复核修正大部分已并入正文。
3. 8 项产品决策已写入 §0.3，并在后续章节落实。
4. 明确反编译只能证明 DDPM 二进制行为。
5. 明确第一版仅支持 Capability String 和受控色彩预设 POC。
6. RGB、HDR、ICC 反向同步和自动化已经从第一版移除。
7. §12.2 集中列出了 9 类主要硬件实测任务。
8. Get VCP `[3]` result code、`[4]` VCP echo 已修正。
9. `cleanDDCCI` 已改为连续发送三次、任一失败退出的 blast 模式。
10. HDR potential EDR 的原始误判已被指出。
11. ColorSync 未验证的幂等、注册和 UUID 稳定性结论已删除。
12. 串行队列不再被描述为 debounce 或循环抑制。
13. HTTP + SHA256 不再被描述为可靠的主动防篡改机制。

## 3. P0：进入实现前必须修正

### 3.1 §4.2 的 “MCCS 标准 `0x14` value 表”不能作为实现依据

当前 §4.2 将以下内容统一称为 “VESA MCCS v3.0 标准值”：

- Multimedia、Movie、Nature、Game、Sport、Text；
- sRGB、Adobe RGB；
- Rec.709、DCI-P3、Rec.2020；
- ComfortView；
- 多组 HDR preset。

这张表存在明显风险：

1. 没有提供 VESA 规范的版本、表号、页码或原文证据。
2. `0x07` 被同时解释为 sRGB 和 Adobe RGB，一个所谓标准值不应具有两个互斥语义。
3. 表内大量项目与前文已经确认的 Dell 型号/固件映射混在一起。
4. “所有 value 编号本身都是跨厂商 MCCS 标准”的结论，与“同一 value 需要 Dell 型号覆盖”的事实边界不清。
5. 该表被标为 `[已验证:SDK]`，但 VESA 规范不是 macOS SDK。

在提供方给出可核查的 VESA 来源前，应采取以下修正：

- 删除 §4.2 当前值表，或整体标为 `[待实测]`；
- 不对未知型号自动使用该表生成友好名称；
- 保留 Capability String 中报告的原始 value；
- 仅对 macToolBox 已验证的 vendor/model/firmware allowlist 使用友好名称；
- 未知 value 显示 `Preset 0xXX` 或隐藏。

这项问题直接影响 UI 是否向用户展示错误的色彩空间名称，属于实现阻塞项。

### 3.2 §3.2 的“与标准值表取交集”会错误删除厂商值

当前规则：

```text
14 存在且有子值 → 子值集合 ∩ MCCS 标准 value 表
```

这与 §4.3 的“未知 value 显示原始值或隐藏”相互矛盾。

如果先取交集，厂商扩展 value 会被永久丢弃，后续就无法：

- 按型号 allowlist 识别；
- 展示原始 value；
- 收集硬件测试数据；
- 在未来增加映射。

正确的数据模型应保留：

```swift
advertisedValues: Set<UInt8>        // 显示器原始声明，绝不丢弃
knownMappings: [UInt8: PresetName]  // 当前身份范围内已验证的名称
unknownValues: Set<UInt8>           // advertised - knownMappings.keys
```

UI 是否显示 unknown value 是产品策略，但协议解析层不能把它删掉。

### 3.3 `DDCReadOutcome` 仍混入了 Capability 层状态

§2.3 当前把以下内容放进同一个枚举：

- Reply result；
- checksum/transport failure；
- Capability 未声明；
- Capability 没有枚举子值；
- DDPM 内部 `0xFFFF` 哨兵。

其中 `notInCapability` 和 `emptyEnumSubset` 并不是一次 DDC read 的结果，而是能力声明状态。继续混用会导致：

- 单次读取 API 依赖全局 capability cache；
- 无法区分“线上的报文结果”和“离线能力判断”；
- transport 层与产品策略互相耦合；
- 后续对连续值和枚举值采用不同策略时难以扩展。

建议保持两个模型：

```swift
enum DDCReadOutcome {
    case success(DDCReadResult)
    case unsupportedReply(resultCode: UInt8)
    case checksumFailure
    case malformedReply
    case transportFailure
}

enum DDCAdvertisedSupport {
    case advertised(values: Set<UInt8>?)
    case notAdvertised
    case unavailable
}
```

`0xFFFF` 应先作为 `invalidValue` 或 `invalidSentinel` 保留，而不是未经实机确认就等同于协议层 unsupported。

## 4. P1：POC 期间必须修正或澄清

### 4.1 HDR 的未来实现建议仍然过度确定

文档已经正确指出：

```swift
maximumPotentialExtendedDynamicRangeColorComponentValue
```

表示潜在 EDR 能力，而不是当前 HDR 状态。

但 §6.3 又把：

```swift
maximumExtendedDynamicRangeColorComponentValue
```

直接称为“当前状态 API”，并建议未来用它判断 HDR。

SDK 头文件只说明它是“当前最大 EDR color component value”，且会受到渲染上下文是否请求 EDR、系统能力及其他条件影响。它仍不等同于系统设置中的 HDR 开关。

应修改为：

- `maximumExtended...` 只能作为候选信号；
- 在独立 POC 证明与系统 HDR 设置、显示器模式和目标 ICC 的关系前，不用于业务决策；
- §12.2 增加 HDR 状态判定 POC；
- 第一版继续完全禁用 HDR 自动判断和联动。

### 4.2 macToolBox 降级路径不应包含 Dell USB SDK

§2.5 写的是：

```text
尝试 cap string（三条路径：USB → M1/Intel → USB 兜底）
```

这是 DDPM 的调用策略，不是 macToolBox 的可用策略。本文同时在 §8 明确：

- USB SDK 不进入第一版；
- macToolBox 不集成 Dell SDK。

应拆成：

- **DDPM 行为**：USB → M1/Intel → USB；
- **macToolBox 第一版行为**：Apple Silicon 使用 IOAVService，Intel 使用 IOKit I2C；不使用 Dell USB SDK。

此外，§1.3 将 Intel 和 USB Get 请求都描述为“5 字节、前缀 `0x51`”，但 §1.2 又说明 USB Set 使用 `0x81` 和尾部 `0x00` 的 SDK 封装。USB Get 的精确封装应单独给出反编译证据，否则标为未知。

### 4.3 证据标签没有严格限定为五种

正文出现了不在 §0.1 定义中的组合标签：

- `[已验证:SDK + 代码]`
- `[已验证:SDK + 逆向]`

同时：

- VESA MCCS 被标为 `[已验证:SDK]`；
- HTTP 安全分析被标为 `[已验证:SDK + 逆向]`；
- 法律许可被标为 `[待实测]`。

这些都与五级证据定义不一致。

建议每个陈述分别标注，而不是组合标签，例如：

```text
[已验证:代码] DDPM 调用了 maximumPotential...
[已验证:SDK] Apple 头文件定义该属性表示潜在能力
[逆向推断] DDPM 因此可能把 capable 误当作 active
```

许可问题不是硬件实测，应写成：

```text
[实现建议] 在取得明确分发授权前不集成或分发 Dell SDK/ICC。
```

不要声称“第三方不可分发”，除非引用了实际 EULA 或书面授权。

### 4.4 `[待实测]` 尚未真正集中到 §12.2

虽然 §12.2 列出了 9 项，但正文仍散落多项未完整进入矩阵的待验证内容：

- Capability String 是否在运行时变化；
- HDR 当前状态判定方法；
- ColorSync 设备是否已注册；
- 设置 profile 后如何确认 current profile；
- ColorSync 通知行为；
- UUID 与显示器重插、多台同型号显示器的身份稳定性；
- USB SDK 返回日志和许可；
- ICC 文件许可；
- `0xFFFF` 在真实 Reply 中的语义。

如果 §12.2 是统一验收入口，应将上述内容全部纳入矩阵，并增加“适用阶段”：

- preset POC 必须；
- ICC POC 必须；
- 后续 USB/自动化；
- 法务/许可确认。

正文可以保留 `[待实测]` 标记，但所有标记都应能映射到 §12.2 的一条测试或确认任务。

### 4.5 parser 的 malformed 策略前后矛盾

§3.2 规定：

```text
括号不闭合/截断 → 整个 cap string 丢弃
```

§3.3 的状态机注释却规定：

```text
遇到非预期字符 → 丢弃整个 vcp() 块，继续找下一个
```

对于枚举型写入，建议统一采用严格模式：

- `vcp(...)` 块畸形或截断时，Capability Report 整体不可用于写入；
- 原始字符串仍保留供诊断；
- 不能使用部分解析结果开放 `0x14`；
- 可以另行保留非权威 partial diagnostics，但不能进入能力决策。

### 4.6 ICC 状态机中的“硬件不可逆”表述不准确

§7.3 写道：

> 硬件切换不可逆，不回滚。

大多数 preset 在技术上可以再次写回旧值。这里真正的产品决策是：

- ICC 失败后不自动回滚硬件；
- 原因是旧状态可能已经失效、回滚也可能再次失败，并且会增加 DDC 操作风险；
- UI 进入 `hardwareOnly`，由用户决定重试 ICC 或手动切换 preset。

应删除“硬件不可逆”，改成“产品选择不自动回滚”。

### 4.7 ICC POC 项目不足以支撑“应用成功”结论

§7.2 已列出部分 POC，但 §12.2 只保留了“沙盒下 ColorSync API”一行。

正式启用 DDC → ICC 前至少要验证：

1. 通过显示器 UUID 查询到正确的 ColorSync device；
2. 两台同型号显示器不会互相串配；
3. `ColorSyncDeviceSetCustomProfiles` 返回成功；
4. 使用 `ColorSyncIterateDeviceProfiles` 或等价方式确认 current profile；
5. 收到显示器 profile/颜色空间变化通知；
6. 显示器重插后仍能恢复正确关联；
7. 写入失败、URL 无效和 profile 损坏时状态进入 `hardwareOnly`；
8. Hardened Runtime 构建可用；
9. 如果未来启用 App Sandbox，单独验证沙盒构建。

## 5. 可直接使用的规范范围

在上述问题修正前，建议实现只采用以下章节：

| 章节 | 使用方式 |
|---|---|
| §1.2 Set VCP | 作为 DDPM 代码路径参考，并用现有测试向量验证 |
| §1.3 Get VCP | 使用 11 字节布局，读取 `[3]` result、校验 `[4]` echo |
| §1.4 Capability String | 用于实现 feature-flag 下的分块读取 POC |
| §1.5 cleanDDCCI | 仅作为 DDPM 行为参考；先实测再决定是否复制 blast-3-times |
| §1.6 checksum | 用于合成测试；正式结论等待硬件报文 |
| §3 Capability parser | 使用严格 fail-closed，但保留所有原始 enum values |
| §5 preset 写后验证 | 延时和重试作为可配置 POC 参数，不固化为兼容性事实 |

暂时不要采用：

- §4.2 MCCS value 表；
- §6 HDR 未来判断方法；
- §7 正式 ICC 集成；
- §8 USB SDK；
- §9 远程 ICC；
- §10 MinLu；
- §11 自动化。

## 6. 建议退回提供方的最后修订清单

可直接发送：

> 两份交付物的整体方向已经符合要求。`10-rfi-reply.md` 验收通过；`11-authoritative-spec.md` 有条件通过。请在作为正式实现规范前完成以下最后修订：
>
> 1. 删除或提供可核查来源证明 §4.2 的 MCCS `0x14` value 表。当前表明显混合了标准值与 Dell/型号 preset，且 `0x07` 同时对应两种语义，不能用于未知显示器。
> 2. §3.2 不要将 Capability 子值与标准表取交集。必须保留显示器报告的全部原始 value，映射和 UI 展示在上层决定。
> 3. 将 `DDCReadOutcome` 与 `DDCAdvertisedSupport` 分开；Capability 未声明和空枚举不是一次 DDC read 的结果。`0xFFFF` 先保留为 invalid sentinel，不直接等同协议 unsupported。
> 4. §6.3 不要把 `maximumExtendedDynamicRangeColorComponentValue` 直接定义为系统 HDR 当前状态。它只能作为候选信号，必须经过独立 POC。
> 5. §2.5 区分 DDPM 的 USB fallback 与 macToolBox 第一版传输路径；macToolBox 不使用 Dell USB SDK。USB Get 的确切封装无证据时请标为未知。
> 6. 严格使用五种已定义证据标签，删除 `[已验证:SDK + 代码]` 等组合标签。VESA 规范、安全分析和法律许可不能标成 macOS SDK 证据。
> 7. 将正文所有 `[待实测]` 映射到 §12.2；补充 HDR、ColorSync 身份/应用确认/通知/重插、`0xFFFF` 和许可确认。
> 8. 统一 malformed Capability 的 fail-closed 行为：`vcp(...)` 畸形时不得用部分结果开放枚举写入。
> 9. 将“硬件不可逆”改为“产品选择不自动回滚硬件”。
> 10. 扩充 ICC POC 验收项，必须确认 current profile 和多显示器身份映射，不能只检查 API 返回 true。
>
> 完成以上修订后，文档可以作为 Capability String + 受控色彩预设 POC 的单一规范。正式色彩管理仍需通过 §12.2 的对应硬件和 ColorSync 验证后再扩大范围。

## 7. 最终建议

当前建议状态：

```text
10-rfi-reply.md       ACCEPTED
11-authoritative-spec CONDITIONAL ACCEPTANCE
正式功能开发           NOT YET
Capability/preset POC READY AFTER P0 DOC FIXES
```

不建议继续围绕旧的 `03/05/07/08/09` 修改。提供方只需再修订 `11-authoritative-spec.md`，由它继续承担单一事实来源。
