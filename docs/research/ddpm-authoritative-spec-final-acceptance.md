# DDPM 权威规范最终验收

日期：2026-07-30

验收对象：`/Users/youtonghy/Downloads/break/DDPM/11-authoritative-spec.md`

## 1. 最终结论

`11-authoritative-spec.md` **验收通过**，现在可以作为以下范围的单一规范：

- Capability String 分块读取与解析；
- Get VCP Reply 严格校验；
- per-display 能力探测；
- fail-closed 的枚举控制；
- 已验证型号上的受控 `0x14` 色彩预设 POC；
- preset 写后读回及亮度、对比度状态刷新 POC。

规范不授权直接扩大到完整正式色彩管理。以下能力仍必须通过 §12.2 对应项目后再进入实现：

- 未知型号的友好 preset 名称；
- RGB Gain；
- HDR 状态判断或联动；
- DDC → ICC 单向同步；
- ColorSync 多显示器身份和 profile 应用确认；
- Dell USB SDK；
- 定时、按应用和远程 ICC。

该边界已经在 §0.2、§0.3、§11.3 和 §12.2 中保持一致。

## 2. 上一轮阻塞项关闭情况

### P0

| 原阻塞项 | 状态 | 当前处理 |
|---|---|---|
| 未核实的 MCCS `0x14` 标准值表 | **已关闭** | 旧表已删除；没有 VESA 原文前不推断任何 value 语义 |
| Capability 子值与标准表取交集 | **已关闭** | 解析层保留显示器报告的全部原始 value |
| `DDCReadOutcome` 混入 Capability 状态 | **已关闭** | 已拆分为 `DDCReadOutcome` 和 `DDCAdvertisedSupport` |

### P1

| 原问题 | 状态 | 当前处理 |
|---|---|---|
| 把 EDR current maximum 当作 HDR 开关 | **已关闭** | 只作为未来候选信号，必须经过 §12.2-Q5 POC |
| macToolBox 路径混入 Dell USB fallback | **已关闭** | §0.4 和 §2.5 明确第一版仅用 AVService/Intel I2C |
| 证据标签混乱 | **已关闭** | §0.1 只允许五种标签，并禁止组合标签 |
| 待实测项缺少统一索引 | **已关闭** | §12.2 提供 Q1–Q20 全量矩阵 |
| malformed Capability 策略矛盾 | **已关闭** | 畸形 `vcp(...)` 统一 all-or-nothing、fail-closed |
| “硬件不可逆”表述 | **已关闭** | 改为产品选择不自动回滚 |
| ICC POC 只检查 API 返回值 | **已关闭** | 增加 current profile 读回、多显示器身份和重插验证 |

## 3. 证据与范围检查

已确认：

1. 文档只定义五种证据等级。
2. 正文没有继续使用有效的组合证据标签；`[已验证:SDK + 代码]` 只作为删除写法的示例出现。
3. DDPM 反编译事实与 macToolBox 产品决策已经分开。
4. USB SDK 的未知封装没有被用于 macToolBox 第一版。
5. Capability parser 保留原始 enum values，不再依赖未经核实的 MCCS 显示名。
6. `0xFFFF` 被保留为 invalid sentinel，而不是直接等同协议 unsupported。
7. `maximumPotentialExtendedDynamicRangeColorComponentValue` 被正确限定为能力信息。
8. ICC 第一版仅允许在独立 POC 后进行单向 DDC → ICC。
9. Q1–Q20 共 20 项，编号连续且能够回指对应章节。
10. `10-rfi-reply.md` 继续只承担历史追溯，`11-authoritative-spec.md` 是唯一规范来源。

## 4. 实现约束

开始 POC 时必须遵守：

1. 色彩预设功能放在开发开关或实验入口后。
2. Capability String 读取或完整解析失败时，不展示 `0x14` 控件。
3. 仅展示显示器 `14(...)` 报告的 value。
4. 未命中已验证型号映射时，只显示 `Preset 0xXX`，不猜测色域名称。
5. 写入后必须读回确认；无法读回时不报告完整成功。
6. preset 切换后使亮度和对比度缓存失效并重新读取。
7. 记录原始请求、响应、checksum、result code、显示器身份和连接路径。
8. 不复制 Dell USB SDK 路径。
9. 不实现 RGB Gain、HDR、ICC、定时或按应用切换，除非对应 §12.2 项已经完成并回写规范。

## 5. 非阻塞性文字改进

以下问题不阻塞 Capability String + preset POC，但建议下次修订顺手处理：

1. §4.2 的“这是 MCCS 留的歧义”应改为“这是旧表自身的歧义”。当前没有查阅 VESA 原文，不能把歧义归因于 MCCS。
2. §9.3 的“第三方应用不可重新分发”应改为“在取得明确许可前不得重新分发”。当前 EULA 仍在 §12.2-Q19 待确认。
3. §3.2 对畸形 `vcp(...)` 应统一报告 `capabilityStringUnavailable`，不要在同一规则中保留 `notAdvertised` 备选，否则会损失诊断语义。
4. §1.4 实现时应补充块边界要求：在访问 payload/checksum 前验证长度字节、最大 payload 和所有数组索引，畸形块直接失败。

这些属于证据措辞、诊断精度和防御性实现要求，不改变当前产品边界。

## 6. 状态

```text
10-rfi-reply.md                         ACCEPTED AS TRACE
11-authoritative-spec.md                ACCEPTED FOR POC SCOPE
Capability String POC                   READY
受控 color preset POC                   READY
正式色彩管理                            BLOCKED BY §12.2
```

后续实现和测试发现的新事实应直接回写 `11-authoritative-spec.md`，不再修改被 supersede 的 `03/05/07/08/09`。
