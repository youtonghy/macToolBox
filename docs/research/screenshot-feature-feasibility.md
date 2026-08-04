# macToolBox 截图、标注、长截图与本地 OCR 可行性研究

调研日期：2026-07-30

> 后续产品决策（2026-07-31）：已批准的实现方案改为完全本地
> PaddleOCR，包括默认 PP-OCRv6 tiny、可选 small/medium、PP-StructureV3 和
> PaddleOCR-VL。本报告中早期的 Apple Vision 建议仅保留为当时的可行性研究记录，
> 不再代表实施方向。以
> [截图工作流总设计](../superpowers/specs/2026-07-31-screenshot-workflow-design.md)
> 和 [本地 PaddleOCR 实施计划](../superpowers/plans/2026-07-31-local-paddleocr.md)
> 为准。

## 结论

这组功能适合加入当前项目，但不应作为一个巨型 `ScreenshotManager` 直接接入。
现有工程已经具备 Carbon 全局热键、辅助功能权限、AX 窗口读取、多显示器覆盖窗和
SwiftUI/AppKit 混合界面基础；真正缺失的是统一快捷键注册表、ScreenCaptureKit 图像
管线、元素级 AX 命中、非破坏标注模型、滚动拼接算法和本地 PaddleOCR 运行时。

建议范围如下：

1. 将“区域截图”作为一个动作加入统一快捷键规则清单，允许启停、改键、恢复默认和
   显示冲突。
2. 支持手动区域、全屏/显示器、窗口和 AX 元素智能选区。AX 不可用时，手动区域和
   ScreenCaptureKit 窗口候选仍可工作。
3. 截图后进入单一编辑窗口，第一版提供矩形、箭头、自由笔/荧光笔、文字、马赛克及
   撤销/重做。
4. “元素自动识别”第一版应明确为截图前的 AX 智能选区，以及编辑时的候选框吸附；
   不承诺从已生成的位图中用 AI 还原任意 UI 控件。
5. 本地 OCR 使用 PaddleOCR：PP-OCRv6 提供 tiny/small/medium，默认 tiny；另提供
   可选 PP-StructureV3 和 PaddleOCR-VL。运行时代码随应用签名发布，只有模型权重和
   静态资源可按需下载，不允许云端回退。
6. 长截图采用“选定 ROI、滚动、等待画面稳定、重叠匹配、增量拼接”的独立可取消
   状态机。它是本需求中风险最高的能力，应先做原型，不能把 PixPin 报告里的
   `stitch(current, frame, offset)` 当成现成算法。

暂不纳入二维码、贴图历史、录屏、表格/公式识别、翻译、TTS、脚本宏、云同步和多种
导出格式。基础输出以 PNG、剪贴板和另存为为限。

## 证据边界

### PixPin 参考资料

检查了 `/Users/youtonghy/Downloads/break/PixPin.app.analysis/` 中全部六份 Markdown。
它们能提供有价值的产品拆分和私有符号线索：

- `ScreenShotView`、`ScreenShotBgLayer` 和选择状态机；
- `UiRegionDetectorThreadWarp` 的异步元素区域查询、父子候选和缓存；
- `LongShotWidget`、`SimulateMouseScroll` 和逐帧拼接；
- `PinWindowMarkEdit` 的标注层；
- OCR 检测、分类、识别和文字块结果；
- 快捷键绑定列表、注册失败状态和动作分发。

但这些材料也明确说明伪代码和调用关系是“整理”结果，不是源代码或可复现实验。
尤其是下列内容不能直接作为设计事实：

- 文档只把 ScreenCaptureKit/CoreGraphics 列为依赖，没有说明静态截图的实际调用链和
  权限错误处理。
- `reached_bottom`、`stitch`、动态内容处理和滚动失败恢复都是伪代码占位。
- “QxtGlobalShortcut 在 macOS 使用 CGEventTap”缺少后端代码证据。
- “PaddleOCR 风格”不能证明模型来源、许可证、语言范围或准确率。
- 私有类名、动态库名、端点和模型 CDN 不能作为本项目可链接或可复制的 API。

因此，PixPin 资料在本报告中只用于确定体验和模块边界；平台能力以 Apple 官方文档、
当前 Xcode SDK 头文件和 macToolBox 源码为准。

### Context7 状态

已按仓库要求调用 Context7 查询 Apple ScreenCaptureKit、Vision 和 Accessibility，
但服务返回月度额度已用尽。随后改用 Apple 官方开发者文档和本机 Xcode 26.6 /
macOS 26.5 SDK 头文件交叉核对。

## 当前工程基线

当前项目是 macOS 14+ 的 Swift 5 菜单栏应用，使用 SwiftUI、AppKit 和 Combine，
由 XcodeGen 管理工程；应用启用 Hardened Runtime、未启用 App Sandbox，且通过
`LSUIElement` 作为 accessory app 运行
（[project.yml](../../project.yml)、[ToolBox.entitlements](../../Resources/ToolBox.entitlements)）。

现有可复用能力：

- [AppDelegate.swift](../../Sources/ToolBox/AppDelegate.swift) 是服务和 coordinator
  的组合根，适合接入独立 `ScreenshotCoordinator`。
- [Permissions.swift](../../Sources/ToolBox/Permissions.swift) 已有 Accessibility、
  Input Monitoring 的检查、提示和系统设置跳转，可扩展 Screen Recording 和
  Post Event 两种能力。
- [SystemFocusModeObserver.swift](../../Sources/ToolBox/FocusMode/SystemFocusModeObserver.swift)
  已有 AX 消息超时、失效元素处理、窗口位置/尺寸读取和事件观察经验。
- [FocusModeModels.swift](../../Sources/ToolBox/FocusMode/FocusModeModels.swift) 已有
  AX 左上角坐标与 AppKit 左下角坐标之间的转换逻辑。
- [FocusOverlayManager.swift](../../Sources/ToolBox/FocusMode/FocusOverlayManager.swift)
  负责消费屏幕列表并管理多显示器遮罩，
  [SystemFocusModeObserver.swift](../../Sources/ToolBox/FocusMode/SystemFocusModeObserver.swift)
  负责屏幕变化通知；[ScreenWipeCoordinator.swift](../../Sources/ToolBox/ScreenWipe/ScreenWipeCoordinator.swift)
  则直接监听热插拔并重建每屏窗口。这些模块已经覆盖 Spaces 和绝对坐标放置经验。
- 设置页已有共享 UI 原语和独立功能页结构
  （[SettingsView.swift](../../Sources/ToolBox/SettingsView.swift)、
  [SettingsChrome.swift](../../Sources/ToolBox/Settings/SettingsChrome.swift)）。
- Store 的成熟模式是版本化 `Codable + UserDefaults + schemaVersion + 显式损坏状态`，
  可参考
  [BrightnessScheduleStore.swift](../../Sources/ToolBox/DisplayControl/Schedule/BrightnessScheduleStore.swift)。

当前完全缺失 ScreenCaptureKit、Screen Recording 权限、本地 OCR 运行时和模型管理、
截图编辑画布、标注文档、滚动驱动和图像拼接实现。

## 快捷键规则清单

### 当前实现不能直接扩展

[HotKeyController.swift](../../Sources/ToolBox/HotKeyController.swift) 只包装一个
Carbon `RegisterEventHotKey`：

- 一个 controller 只有一个回调和一个当前注册项；
- `EventHotKeyID` 固定为签名 `HOTK`、ID `1`；
- 回调没有读取事件中的 hot key ID；
- 没有动作模型、持久化、启停、冲突状态和回滚。

当前唯一使用方是擦屏幕退出键。它在
[ScreenWipeCoordinator.swift](../../Sources/ToolBox/ScreenWipe/ScreenWipeCoordinator.swift)
中硬编码为 `⌃⌥⌘ Esc`，启动遮罩前先注册，失败时拒绝盖住屏幕。这种 fail-closed
语义必须保留。

多个截图动作不能通过创建多个现有 `HotKeyController` 来实现。应用级事件处理器无法
区分固定 ID 的注册项，路由会变得不确定。需要先把它重构为一个集中式 registry。

### 推荐模型

```swift
enum ShortcutActionID: String, Codable {
    case captureRegion
    case captureDisplay
    case captureText
    case screenWipeExit
}

struct ShortcutBinding: Codable, Equatable {
    let keyCode: UInt32
    let modifiers: ShortcutModifiers
}

struct ShortcutRule: Codable, Identifiable {
    let id: ShortcutActionID
    var binding: ShortcutBinding
    var isEnabled: Bool
}
```

对应模块：

- `ShortcutRegistry`：安装一个 Carbon handler，为每条规则分配唯一 ID，解析事件并
  分派动作。
- `ShortcutRuleStore`：版本化持久化、默认值、损坏数据和 schema 迁移。
- `ShortcutRecorderView`：记录组合、格式化显示、拒绝无修饰键或保留组合。
- `ShortcutConflict`：区分清单内重复、Carbon 注册冲突和无效组合。

改键应采用事务语义：先验证新组合；注册失败时保留旧组合，不能先注销旧绑定再让动作
失效。擦屏幕退出键可以出现在同一清单，但应是“受保护规则”：允许改键，不能在遮罩
运行时没有任何有效退出绑定；每次启动仍须先验证注册成功。

媒体键不应强行迁入同一个 Carbon registrar。它们由
[DisplayControlMediaKeyController.swift](../../Sources/ToolBox/DisplayControl/DisplayControlMediaKeyController.swift)
使用可吞事件的 CGEventTap，权限和行为与普通组合键不同。可以在同一设置页展示，但
运行时仍保持两套输入后端。

另有一个现存文档偏差需要在后续实现时处理：README 称擦屏幕退出需要长按 1.5 秒，
实际代码在收到单次 hot-key pressed 后立即退出，没有长按检测。

## 截图捕获与选择

### API 选择

macOS 14 基线可使用
[SCScreenshotManager](https://developer.apple.com/documentation/screencapturekit/scscreenshotmanager)
的 `captureImage(contentFilter:configuration:)` 获取单帧 `CGImage`。Apple 将其定义为
“从流中捕获一个单帧”，并允许使用
[SCContentFilter](https://developer.apple.com/documentation/screencapturekit/sccontentfilter)
选择显示器、窗口、应用或排除本应用窗口。

`SCStreamConfiguration.sourceRect` 使用显示器逻辑坐标中的 point，输出 `width/height`
使用 pixel。当前 SDK 还确认：

- `SCScreenshotManager.captureImage(contentFilter:configuration:)` 自 macOS 14 可用；
- 直接按全局任意矩形调用 `captureImage(in:)` 直到 macOS 15.2 才可用；
- macOS 26 的 `SCScreenshotConfiguration` 不能用于项目的 macOS 14 基线。

因此不能以新系统的 rect API 作为核心实现。macOS 14 的跨屏选区需要把全局选区与
每个显示器求交，分别以 display filter + `sourceRect` 捕获，再按 scale 和色彩空间
合成。

### 推荐交互管线

```text
快捷键
  -> 检查 Screen Recording 权限
  -> 捕获每个显示器的冻结帧（排除 ToolBox）
  -> 建立每屏选择 overlay，显示冻结帧
  -> 手动框选 / 窗口候选 / AX 元素候选
  -> 裁剪并生成不可变 CaptureDocument
  -> 编辑窗口
  -> OCR / 标注 / 复制 / 保存
```

先捕获、后显示 overlay，比用户确认后再截一次更可靠：不会把选区边框、工具栏和点击
反馈截入结果，也使选择期间画面保持稳定。

建议所有选择几何先保存为“全局 point 坐标”，同时为每个 display 保存：

- `CGDirectDisplayID` / ScreenCaptureKit display ID；
- AppKit frame；
- backing scale；
- 对应 `CGImage` 的 pixel size；
- point rect 到 pixel rect 的显式变换。

不要假设所有显示器 scale 相同，也不要直接混用 AX、AppKit、ScreenCaptureKit 和
Vision 的坐标。混合 Retina、负坐标副屏、上下排列屏幕必须作为纯逻辑测试夹具。

## AX 元素识别

Apple 的
[AXUIElementCopyElementAtPosition](https://developer.apple.com/documentation/applicationservices/1462077-axuielementcopyelementatposition)
会按窗口 z-order 返回指定位置的 AX 元素，输入坐标是左上角原点。随后可读取
`kAXRoleAttribute`、`kAXPositionAttribute`、`kAXSizeAttribute` 和
[`kAXParentAttribute`](https://developer.apple.com/documentation/applicationservices/kaxparentattribute)
构建由具体控件到窗口的候选链。

推荐单独建立 `AXRegionProvider`，不要把功能塞进现有只跟踪聚焦窗口的 observer：

- 鼠标移动做 30-60 Hz 节流，AX 查询在串行后台队列执行；
- 每个元素设置较短消息超时，丢弃过期结果；
- 过滤零面积、超大、离屏和 ToolBox 自身元素；
- 缓存最近位置和候选链；
- Tab/方向键在父子候选之间切换；
- AX 返回 `cannotComplete`、`notImplemented` 或无 frame 时，降级到 SCWindow 或手动
  区域，不阻断截图。

部分 Electron/WebView、自绘 canvas、游戏、受保护窗口和权限未授权场景无法提供稳定
的控件级 AX 区域，这是平台边界，不应在 UI 中显示为“识别失败等于截图失败”。

“截图后的元素自动识别”建议只复用已经得到的 AX 区域，在编辑器中提供矩形吸附和
候选框。对截图位图重新运行通用 UI 元素检测是另一项计算机视觉工程，不在本期范围。

## 标注编辑器

推荐使用不可变原图 + 非破坏 annotation document，而不是每次拖动直接改写 bitmap：

```text
ScreenshotEditorDocument
  baseImage: CGImage
  annotations: [Annotation]
  selection: Annotation.ID?
  history: undo / redo commands
  ocrResult: OCRResult?
```

第一版 annotation 类型：

- rectangle / ellipse；
- arrow / line；
- pen / highlighter；
- text；
- mosaic（像素化）；
- optional numbered marker。

文字对象保存文本、字体、字号、颜色、对齐和 transform；编辑时保持矢量，导出时再用
Core Graphics/Core Image 扁平化。OCR 文字层与用户标注分离，避免“隐藏 OCR 框”也
改动最终图像。

长图需要避免每次编辑都复制整张 bitmap。渲染器应使用增量预览或 tiled view，并在
导出前估算 `width * height * 4` 内存；超过限制时提示缩小、分段保存或停止继续拼接。

## 本地 OCR

批准方案锁定 PaddleOCR `v3.7.0` 的 PP-OCRv6：

- tiny / small / medium 三档，默认 tiny；
- tiny 支持 49 种语言但不支持日语，small / medium 支持日语；
- 输出文字行、confidence、polygon 和 reading order；
- PP-StructureV3 保留标题、段落、图片、表格等结构块；
- PaddleOCR-VL 保留 document blocks、Markdown 和关联区域。

三类结果不能强制转换为同一种文字数组。PP-OCRv6 通过 Objective-C++/C++ bridge
接入 ONNX Runtime，CPU EP 是 macOS 基线；Core ML EP 只有在准确率、算子覆盖和
设备性能门槛通过后启用。ONNX Runtime 官方 XNNPACK EP 当前不支持 macOS，不进入
生产后端。

PP-StructureV3 和 PaddleOCR-VL 使用随应用签名发布的本地 worker。worker runtime、
Python/package、dylib 和适配代码不得在运行时下载；只有经过随应用 catalog、公钥
签名、SHA-256、长度、路径和 required-files 校验的模型权重与静态字典可以按需安装。
所有管线均须在断网环境完成推理，不得上传截图或回退到云端。

高级管线的包体、依赖许可、签名、公证、Apple Silicon 兼容性、冷启动和峰值内存风险
显著高于普通 OCR。正式 UI 只能显示已经通过 ARM64 架构门槛的管线；未通过时保留
PP-OCRv6 和原图/标注能力，不能用占位选项掩盖不可用状态。

## 长截图

ScreenCaptureKit 只负责取帧，不提供滚动、重叠估计、底部判断或拼接。长截图应作为
独立 `ScrollCaptureSession`：

```text
idle
 -> acquiringTarget
 -> capturingInitialFrame
 -> scrolling
 -> waitingForStability
 -> matchingOverlap
 -> appending
 -> completed / cancelled / failed
```

建议流程：

1. 用户选择窗口内的 ROI，并确认滚动目标。
2. 捕获初始帧，保存目标应用 PID、AX scroll area（若可用）和鼠标位置。
3. 优先向目标位置合成小步长 scroll-wheel event；AX scroll bar value 只作为支持良好
   应用的可选优化。
4. 连续采样 ROI，直到两帧差异低于阈值或到达超时，避免惯性滚动中取帧。
5. 在上一帧底部与新帧顶部的重叠带中估计垂直位移；低置信度时暂停并要求用户重试或
   改为手动滚动。
6. 只追加非重叠区域，检测固定 header/footer 并排除其重复部分。
7. 连续多次没有新内容时判断到底；恢复鼠标位置和会话状态。

自动滚动事件属于“event synthesizing”，当前 SDK 提供
`CGPreflightPostEventAccess` / `CGRequestPostEventAccess`。系统设置侧将这项信任
归入辅助功能，但代码应单独 preflight 事件合成能力，不要错误要求 Input Monitoring。
后者是监听输入，而自动长截图是在发送输入。

第一版必须提供手动滚动模式。PDF、网页、聊天列表、终端、自绘应用、动态视频、吸顶
栏、懒加载、水平滚动和缩放页面会产生不同失败模式，任何单一拼接参数都不可能覆盖。

长截图原型应先验证：

- Safari/Chrome 普通网页；
- Finder 列表；
- 系统设置；
- 聊天类动态列表；
- 固定 header；
- Retina 与非 Retina 外屏；
- 到底、用户反向滚动、窗口移动、目标应用失焦和取消。

## 目标权限与降级矩阵

下表描述规划完成后的目标行为，不是当前 `HotKeyController` 已有的行为。

| 能力 | 所需权限 | 无权限时行为 |
| --- | --- | --- |
| Carbon 普通全局快捷键 | 无 TCC | 注册冲突时保留旧规则并显示冲突 |
| 静态屏幕/窗口/区域捕获 | Screen Recording | 显示授权状态和系统设置入口，不启动空 overlay |
| 手动区域选择 | 捕获权限即可 | 正常工作 |
| AX 控件级智能选区 | Accessibility | 降级到窗口候选和手动区域 |
| 自动滚动事件注入 | 事件合成访问（系统设置归入辅助功能） | 改用手动滚动模式 |
| 本地 PaddleOCR | 已安装并验证的本地模型 | 只禁用对应 OCR 管线，不影响原图和标注 |
| 保存/剪贴板 | 无额外 TCC（用户选择路径） | 明确报告写入或粘贴板错误 |

Screen Recording 可用
[`CGPreflightScreenCaptureAccess`](https://developer.apple.com/documentation/coregraphics/cgpreflightscreencaptureaccess%28%29)
检查，并用
[`CGRequestScreenCaptureAccess`](https://developer.apple.com/documentation/coregraphics/cgrequestscreencaptureaccess%28%29)
请求。项目当前非沙盒，不需要为这项功能新增 App Sandbox entitlement。

## 推荐模块边界

```text
Shortcut/
  ShortcutRule.swift
  ShortcutRuleStore.swift
  ShortcutRegistry.swift

Screenshot/
  ScreenshotCoordinator.swift
  ScreenshotModels.swift
  Capture/
    ScreenCaptureProvider.swift
    ScreenCapturePermission.swift
  Selection/
    ScreenshotSelectionOverlayManager.swift
    AXRegionProvider.swift
    SelectionGeometry.swift
  Editor/
    ScreenshotEditorDocument.swift
    Annotation.swift
    AnnotationRenderer.swift
    ScreenshotEditorView.swift
  OCR/
    OCRCoordinator.swift
    PPOCRv6Service.swift
    OCRModelStore.swift
    OCRWorkerClient.swift
  LongCapture/
    ScrollCaptureSession.swift
    ScrollDriver.swift
    OverlapMatcher.swift
    IncrementalImageComposer.swift
```

`ScreenshotCoordinator` 是唯一业务编排入口，维护
`idle -> selecting -> captured -> editing/exporting`，并负责取消、权限错误和窗口
生命周期。系统 API 通过协议注入，纯几何、规则、拼接和 annotation model 不依赖
AppKit，便于 XCTest。

## 分期建议

### 阶段 0：技术原型

- ScreenCaptureKit 单屏/窗口/区域单帧，验证权限拒绝、授权后重试和排除本应用。
- 多显示器冻结帧 overlay，验证 point/pixel/scale 转换。
- PP-OCRv6 原生 ONNX Runtime parity、CPU/Core ML provider、签名/离线运行门槛。
- PP-StructureV3 与 PaddleOCR-VL worker 的签名、公证、取消、崩溃恢复和内存门槛。
- 仅针对固定测试夹具做两帧垂直重叠匹配，再用 Safari/Finder 做自动滚动原型。

原型没有通过前，不先完成全部设置 UI。

### 阶段 1：统一快捷键基础

- 规则模型、版本化 store、集中 registry、唯一 hot key ID、冲突和事务式改键。
- 迁移擦屏幕退出键，保持 fail-closed。
- 设置中增加统一快捷键清单。

### 阶段 2：静态截图与智能选区

- Screen Recording 权限状态。
- 多屏冻结 overlay、手动区域、显示器/窗口候选。
- AX 元素候选链、节流、缓存和降级。
- PNG/剪贴板/另存为。

### 阶段 3：编辑与标注

- 非破坏 annotation document。
- 矩形、箭头、画笔/荧光、文字、马赛克。
- 选中、移动、缩放、删除、撤销/重做和导出扁平化。

### 阶段 4：本地 OCR

- PP-OCRv6 tiny/small/medium、本地模型下载校验、可取消任务和文字结果层。
- 通过架构门槛后接入 PP-StructureV3 和 PaddleOCR-VL 的独立结果层。
- 中英繁体、small/medium 日语、空结果、低置信度和超大图策略。

### 阶段 5：长截图

- 手动滚动先行，自动滚动作为增强。
- 稳定检测、重叠匹配、固定区域处理、到底判断和增量合成。
- 尺寸/内存上限、明确错误和恢复。

## 验证计划

自动测试应至少覆盖：

- 快捷键默认值、round-trip、schema 迁移、损坏数据、内部重复和注册冲突回滚；
- registry 只分发命中的唯一动作，析构/停用时全部注销；
- 多屏负坐标、上下排列、混合 scale 和跨屏裁剪；
- AX 无权限、超时、失效元素、零面积和父子候选排序；
- annotation command、undo/redo 和渲染范围；
- OCR 坐标转换、阅读顺序和空结果；
- 拼接已知偏移、无重叠、重复帧、低置信度、固定 header 和取消；
- 权限拒绝、捕获失败、窗口关闭、目标应用退出和长图超限。

测试实现应沿用仓库现有模式：用闭包表或协议注入系统 API，并以 recorder/fake 断言
生命周期（[HotKeyControllerTests.swift](../../Tests/ToolBoxTests/HotKeyControllerTests.swift)）；
把坐标与候选排序留在纯值逻辑中
（[FocusTargetResolverTests.swift](../../Tests/ToolBoxTests/FocusTargetResolverTests.swift)）；
持久化测试使用独立 UserDefaults suite，覆盖未知 schema 和损坏数据
（[BrightnessScheduleStoreTests.swift](../../Tests/ToolBoxTests/BrightnessScheduleStoreTests.swift)）。

真机矩阵应包含不同缩放显示器、Spaces/全屏应用、系统设置、Safari、Chrome、Finder、
Electron 应用、动态列表和受保护内容。最终仍需运行项目现有全量 XCTest、Debug/Release
构建、签名/链接检查和 `git diff --check`。

## 决策状态与剩余风险

1. **长截图成功率**：这是最大风险。应先定义支持矩阵和可见失败，不承诺任意应用。
2. **快捷键安全规则已定**：擦屏幕退出键允许改键但不允许禁用；启动前保持
   fail-closed。
3. **默认快捷键已定**：区域截图使用 `⌃⌥S`，避开系统截图组合。
4. **元素识别范围已定**：本期只做 AX/窗口智能选区和 Shift 多元素扩选，不做位图 UI
   控件检测。
5. **默认动作已定**：截图后进入非破坏编辑器。
6. **长图上限已定**：60,000 px 或预计 RGBA 512 MiB；仍需通过分块渲染验证
   resident memory。
7. **分发验证仍是风险**：Screen Recording、Accessibility 授权在签名变化和升级后的表现必须
   用 Developer ID 构建做真机验证。

## 本次调查执行的检查

```bash
rg --files Sources/ToolBox Tests/ToolBoxTests docs
rg -n "HotKey|RegisterEventHotKey|AXUIElement|ScreenCaptureKit|Vision" Sources Tests docs
plutil -p Resources/ToolBox.entitlements
xcrun --sdk macosx --show-sdk-path
xcodebuild -version
rg -n "SCScreenshotManager|sourceRect|CGPreflightScreenCaptureAccess" \
  /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk
```

本次只做研究和文档整理，没有修改产品代码，也没有运行构建或测试。
