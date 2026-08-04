# 截图、Shift 多元素扩选、标注、长截图与本地 OCR 设计

## 背景

ToolBox 需要新增一条完整的截图工作流：可配置全局快捷键、手动区域和智能元素选区、
Shift 多元素扩选、截图后标注、本地 OCR、滚动长截图、PNG/剪贴板输出。

参考的 PixPin 分析材料用于理解产品形态，不作为可复用实现。macOS 平台能力以
ScreenCaptureKit、Accessibility、Core Graphics 和项目当前源码为准。OCR 使用
[PaddleOCR](https://github.com/PaddlePaddle/PaddleOCR) 的本地模型；截图内容、OCR
输入和识别结果不得发送到云端。

## 已批准的产品决策

| 决策 | 结果 |
| --- | --- |
| 推进方式 | 纵向分阶段交付，每阶段可独立验收 |
| 默认截图快捷键 | `⌃⌥S`，避开系统 `⌘⇧3/4/5` |
| 普通智能选择 | 点击后立即完成选择并进入编辑器 |
| 多元素选择 | 按住 `Shift` 点击追加或移除相连候选，松开 `Shift` 完成 |
| 多元素结果 | 所有元素最小外接矩形，保留真实间隔和背景 |
| 不相邻元素 | 拒绝；新增候选必须与已选区域边缘接触或重叠 |
| 手动拖拽 | 普通模式松手即完成；`Shift` 期间禁用 |
| 滚动截图选区 | 先切换滚动模式，再点击或拖拽，完成后立即开始 |
| 截图完成 | 默认进入编辑器 |
| 标注模型 | 不可变原图 + 非破坏标注 + 撤销/重做 |
| 默认 OCR | PP-OCRv6 tiny |
| PP-OCRv6 规格 | tiny / small / medium |
| PP-OCRv6 语言提示 | tiny 不支持日语；small / medium 支持日语 |
| 高级 OCR | 可选 PP-StructureV3 和 PaddleOCR-VL |
| OCR 隐私 | 全部本地运行，模型按需下载，禁止云端回退 |
| 长截图 | 手动与自动滚动；默认自动，无权限时手动 |
| 长图上限 | 高度 60,000 px 或预计 RGBA 512 MiB，先到者停止 |
| 基础输出 | PNG、剪贴板、另存为 |

## 目标

1. 用统一快捷键规则清单管理普通 Carbon 全局快捷键，并支持事务式改键和冲突状态。
2. 在混合缩放、多显示器和负坐标布局下准确冻结、选择和裁剪屏幕内容。
3. 用 AX 元素、ScreenCaptureKit 窗口和手动区域构成可降级的候选体系。
4. 允许用户通过 Shift 将多个元素扩展成一张连续矩形截图。
5. 提供文字、箭头、形状、画笔、荧光、马赛克和序号等非破坏标注。
6. 在本机运行 PP-OCRv6、PP-StructureV3 和 PaddleOCR-VL，并明确管理模型生命周期。
7. 通过可取消、可降级的状态机完成手动和自动滚动长截图。
8. 对权限、模型、worker、捕获和拼接错误提供可见、可重试的状态。

## 非目标

1. 不实现录屏、GIF、贴图历史、二维码、翻译、TTS、云同步或脚本宏。
2. 不把多个离散元素重新排版或透明拼贴；结果始终是原屏幕中的连续矩形。
3. 不从截图位图中用通用 CV 模型重建 UI 控件层级。
4. 不支持表格导出 Excel、公式转 LaTeX 或云端文档解析。
5. 不替换显示器媒体键的 CGEventTap 后端。
6. 不下载或执行未随已签名应用发布的代码；只有模型和静态资源可按需下载。

## 总体架构

```text
ShortcutRegistry
      |
      v
ScreenshotCoordinator
      |
      +-- ScreenCaptureProvider
      +-- ScreenshotSelectionOverlayManager
      |     +-- WindowRegionProvider
      |     +-- AXRegionProvider
      |     +-- SelectionReducer
      |
      +-- ScreenshotEditorDocument
      |     +-- AnnotationRenderer
      |     +-- LocalOCRService
      |
      +-- ScrollCaptureSession
            +-- ScrollDriver
            +-- OverlapMatcher
            +-- IncrementalImageComposer
```

`ScreenshotCoordinator` 是唯一流程编排者，公开状态固定为：

```swift
enum ScreenshotWorkflowState: Equatable {
    case idle
    case preparing
    case selecting
    case editing
    case longCapturing(ScrollCapturePresentationState)
    case exporting
    case failed(ScreenshotWorkflowIssue)
}
```

`ScreenshotCoordinator` 仍是唯一公开工作流所有者。`ScrollCaptureCoordinator` 是其
内部子会话；父 coordinator 将子状态映射成 `longCapturing`，统一传播取消、失败、
编辑器隐藏/恢复和最终 handoff。系统 API 位于注入协议之后；坐标、选择 reducer、
快捷键规则、标注文档、模型 manifest、拼接和资源限制保持纯值逻辑。AppDelegate
只负责构造、启动和停止。

## 统一快捷键

### 规则模型

```swift
enum ShortcutActionID: String, Codable, CaseIterable {
    case captureRegion
    case screenWipeExit
}

struct ShortcutBinding: Codable, Equatable, Sendable {
    var keyCode: UInt32
    var modifiers: ShortcutModifiers
}

struct ShortcutRule: Codable, Equatable, Identifiable, Sendable {
    var id: ShortcutActionID
    var binding: ShortcutBinding
    var isEnabled: Bool
}
```

默认规则：

- `captureRegion`：`⌃⌥S`，可启停、可改键；
- `screenWipeExit`：`⌃⌥⌘Esc`，可改键、不可禁用。

`ShortcutRegistry` 安装一个应用级 Carbon handler，为每个动作分配稳定且唯一的
`EventHotKeyID`，从事件中解析 ID 后分发。不能继续为每个动作创建固定 `HOTK/1` 的
现有 `HotKeyController`。

改键采用事务语义：

1. 校验修饰键、清单内重复和受保护规则；
2. 尝试注册新组合；
3. 注册成功后注销旧组合并保存；
4. 注册失败时保留旧组合和持久化值；
5. UI 显示 `invalid`、`duplicate` 或 `systemConflict`。

擦屏幕启动前仍须验证退出动作当前已注册；失败则保持 fail-closed，不建立黑屏窗口。

媒体键继续由 `DisplayControlMediaKeyController` 管理。设置页可显示其权限状态，但不
迁移到 Carbon registry。

## 屏幕捕获

### API

macOS 14 使用 `SCScreenshotManager.captureImage(contentFilter:configuration:)`。
每个显示器建立 `SCContentFilter`，排除 ToolBox 自身应用和窗口。捕获输出包含：

```swift
struct DisplayCaptureFrame: Sendable {
    let displayID: CGDirectDisplayID
    let globalFramePoints: CGRect
    let scale: CGFloat
    let image: CGImage
    let colorSpace: CGColorSpace?
}
```

选择开始前先捕获所有显示器冻结帧，再显示 overlay。用户确认后从冻结帧裁剪，不进行
第二次实时截图，避免边框、工具栏和点击反馈进入结果。

macOS 14 没有跨显示器的全局 rect 单次截图。跨屏选区必须与每块显示器 frame 求交，
分别做 point-to-pixel 转换，再合成到统一输出。不能假设所有显示器 scale 相同。

合成输出 scale 固定为所有相交显示器 `pixelSize / pointSize` 的最大值。每个 fragment
先按自己的 scale 裁剪，再映射到 `selection * outputScale` 的目标像素矩形；1x 内容在
2x 输出中按逻辑尺寸重采样，不把不同 scale 的像素直接拼接。输出统一转换为 sRGB。
冻结帧集合在捕获前做 checked aggregate byte 估算，默认上限 768 MiB；超限或乘法溢出
必须在显示 overlay 前报错。确认合成或取消后立即释放全部冻结帧。

### 权限

- `CGPreflightScreenCaptureAccess()` 检查 Screen Recording；
- `CGRequestScreenCaptureAccess()` 只在用户主动启动截图时请求；
- 未授权时不创建空白 overlay；
- 授权变化后重新获取 `SCShareableContent`，不复用旧内容快照。

## 候选区域与 Shift 多选

### 候选优先级

1. 光标下有效 AX 元素；
2. ScreenCaptureKit 窗口；
3. 当前显示器；
4. 用户手动拖拽区域。

候选解析先按 Core Graphics 的前后顺序确定光标下窗口，再用该窗口 owner PID 创建
应用级 AX 根节点并执行 `AXUIElementCopyElementAtPosition`，避免 ToolBox 全屏选择层截获
系统级命中。查询读取 role、title、position、size 和 parent；串行后台队列只保留最新
待处理点位，设置短消息超时，并通过 generation 丢弃过期结果。AX 无权限、超时、失效
或不支持时仍保留窗口候选，不影响其它选择方式。

### 会话模型

```swift
struct SelectedRegionSnapshot: Equatable, Identifiable, Sendable {
    let id: UUID
    let source: SelectionSource
    let ownerPID: pid_t?
    let windowID: CGWindowID?
    let displayID: CGDirectDisplayID
    let topologyGeneration: UInt64
    let role: String?
    let title: String?
    let globalRect: CGRect
}

struct SelectionSessionState: Equatable, Sendable {
    var hoveredCandidate: SelectionCandidate?
    var selectedRegions: [SelectedRegionSnapshot]
    var manualRegion: CGRect?
    var captureBounds: CGRect?
}
```

会话只保存元素快照，不长期持有 `AXUIElement`。相同候选在单次会话内用
`ownerPID + role + quantizedRect + hierarchyIndex` 生成稳定匹配键。

### 交互

- 普通点击：清空旧选择、添加当前候选并立即进入编辑器；
- 移动光标：重置为当前位置最具体的 AX 元素候选；滚轮在该元素与父级候选之间循环切换；
- `Shift + 点击`未选择候选：追加；
- `Shift + 点击`已选择候选：移除；
- `Shift` 多选中的新增候选必须与至少一个已选区域边缘接触或重叠，移除后整体仍须连通；
- 松开 `Shift`：存在有效选区时立即进入编辑器；
- `Delete`：删除最后加入的元素；
- `Command + Z`：撤销最近一次选择变更；
- `Return`：确认当前有效选区；
- `Escape`：取消；
- 普通按下只记录起点；松开时，未超过移动阈值则选择当前候选，超过阈值则清空元素集合并以拖拽矩形进入编辑器；
- 底部普通截图和滚动截图控件只切换模式；滚动模式下下一次有效点击或拖拽立即开始长截图。

当前候选和已选区域使用 4 pt 系统强调色内描边与半透明深色外描边；同一时刻只强调
当前层级，避免父子候选同时叠加。候选链固定以窗口候选收尾，AX 没有返回有效组件时
仍可直接选择窗口，再按显示器顺序降级。

`captureBounds` 是全部 `selectedRegions.globalRect` 的标准化 union。元素各自显示实线
描边，最终外接矩形显示独立强调描边和像素尺寸。不相连候选不得进入选择集合。

候选必须有限、有正面积并与当前显示器联合区域相交。跨屏候选在确认时按各显示器边界
拆分，不直接用一个 scale 裁剪。

选区启动时 ToolBox 暂时激活；光标所在显示器的 overlay panel 可以成为 key window
但不能成为 main window，其余 panel 不成为 key。光标跨屏时 key ownership 随交互
panel 移动。Escape、Delete、Command-Z 和 Return 由当前 key panel 的本地事件链处理，
不安装全局键盘监听，因此不新增 Input Monitoring 要求。取消时恢复启动截图前的前台
应用；确认进入编辑器时保持 ToolBox 激活。

## 截图文档与编辑器

```swift
struct ScreenshotDocument {
    let baseImage: ScreenshotImageSource
    let captureMetadata: ScreenshotCaptureMetadata
    var annotations: [ScreenshotAnnotation]
    var ocrResult: OCRResult?
}
```

`ScreenshotImageSource` 提供不可变尺寸和有界像素读取；普通截图由 `CGImage` source
实现，长图由只读 tiled/file-backed source 实现。原图创建后不可变。标注类型：

- rectangle / ellipse；
- line / arrow；
- pen / highlighter；
- text；
- mosaic；
- numberedMarker。

每个 annotation 保存原始像素坐标、颜色、宽度、透明度和类型参数。编辑预览按当前
zoom 映射；存储和导出不使用 view point 坐标。`ScreenshotEditorDocument` 通过命令
对象维护 undo/redo，选择变化不污染导出。

文字保存内容、字体 family、字号、weight、颜色、对齐和 transform。马赛克保存区域和
block size，导出时从原图生成，不反复作用于已马赛克像素。

导出使用 Core Graphics/Core Image 扁平化到 PNG。剪贴板和另存为使用同一个导出器；剪贴板同时发布由同一 PNG 解码得到的 TIFF 表示，
避免预览与最终输出不一致。

## 本地 PaddleOCR

### 管线与结果

```swift
enum PPOCRv6Profile: String, Codable, CaseIterable {
    case tiny
    case small
    case medium
}

enum OCRPipelineID: Codable, Equatable {
    case ppOCRv6(PPOCRv6Profile)
    case ppStructureV3
    case paddleOCRVL
}

enum OCRResult {
    case text(TextOCRDocument)
    case structured(StructuredOCRDocument)
    case document(DocumentParseResult)
}
```

PP-OCRv6 返回文字行、confidence、polygon 和 reading order。PP-StructureV3 返回标题、
段落、图片、表格等 layout blocks。PaddleOCR-VL 返回 document blocks、Markdown 和
关联区域。编辑器不能把三种结果强制转换成单一文字数组。

### 推理运行时

PP-OCRv6 采用 ONNX Runtime，通过 Objective-C++/C++ bridge 接入 Swift。CPU EP 是
macOS 生产基线；Core ML EP 只有在目标设备的准确率、算子覆盖、冷启动、P95 延迟和
峰值内存门槛全部通过后才启用，不支持的算子可在同一 session 内回退 CPU。ONNX
Runtime 官方 XNNPACK EP 当前不支持 macOS，因此不列入生产后端。
模型预处理、检测后处理、透视裁剪、识别解码和 reading-order projection 位于
`Sources/ToolBox/OCRRuntime/`，不放进 SwiftUI。

PP-StructureV3 和 PaddleOCR-VL 由签名时已经包含在应用中的本地 `ToolBoxOCRWorker`
进程运行。worker runtime 随应用发布，不从网络下载代码或 Python package；模型权重
和静态字典可按需下载。主进程通过 JSON-lines stdin/stdout 协议发送版本化请求：

```json
{"schemaVersion":1,"taskID":"uuid","pipeline":"ppStructureV3","inputPath":"..."}
```

输出是版本化 result envelope。输入文件位于权限为当前用户可读写的会话临时目录。
worker 单并发执行，支持 cancel 消息；空闲 5 分钟后退出。worker crash、超时或协议
错误只让当前 OCR 任务失败，不得终止 ToolBox 或损坏截图文档。

高级管线接入正式 UI 前必须通过 ARM64 本地原型：

- 安装包可签名和公证；
- 全程无网络推理请求；
- 模型冷启动、峰值内存和单图耗时可记录；
- 取消能在 2 秒内停止任务或终止 worker；
- worker 异常后下一任务可重新启动。

### 模型管理

模型保存到：

```text
~/Library/Application Support/ToolBox/OCRModels/<model-id>/<version>/
```

每套模型由随应用发布的 manifest 描述：

```swift
struct OCRModelManifest: Codable, Equatable, Sendable {
    let modelID: String
    let version: String
    let pipeline: OCRPipelineID
    let downloadURL: URL
    let archiveSHA256: String
    let archiveByteCount: Int64
    let installedByteCount: Int64
    let files: [OCRModelFileManifest]
    let supportedArchitectures: [String]
    let supportedLanguages: [String]
    let runtimeCompatibility: OCRRuntimeCompatibility
    let licenseResource: String
}
```

每个 `OCRModelFileManifest` 固定相对路径、字节数和 SHA-256；runtime compatibility
固定 PaddleOCR revision、ONNX opset、输入/输出名称与 shape 约束。catalog 的 canonical
bytes 由发布密钥签名，应用仅包含验签公钥。

下载规则：

1. 用户主动确认后开始；
2. 写入同目录的随机 staging 文件；
3. 校验 HTTP status、期望长度、归档 SHA-256、归档路径和逐文件哈希/长度；
4. 解压到 staging 目录；
5. 完整验证后原子 rename；
6. 失败时保留旧版本并清理 staging；
7. 禁止从 manifest 归档写出目标目录；
8. 默认不自动更新模型，更新由用户触发。

状态固定为 `notInstalled / downloading(progress) / validating / ready /
corrupt / updateAvailable / failed(issue)`。正在执行的模型持有 lease，不能删除。

PP-OCRv6 tiny 是默认选择，但首次 OCR 仍需用户确认下载。所有 OCR pipeline 禁止上传
截图或使用云端回退。tiny 不支持日语；当用户选择日语时，设置和执行入口必须提示并
要求切换到 small 或 medium，不能静默返回低质量结果。

PaddleOCR-VL 官方当前只在 Apple M4 上验证过准确率和速度；M1/M2/M3 及未来架构必须
分别通过兼容性、内存和延迟门槛后才显示为可用。Intel Mac 只显示其已打包 runtime
明确支持的管线，不尝试启动 ARM64 worker。

## 长截图

### 会话

用户先切换滚动截图模式，再用普通点击或拖拽得到的 `captureBounds` 作为固定 ROI。
滚动过程中不重新查询元素；滚动模式不支持 Shift 多选。

长截图还需要唯一 `ScrollCaptureTargetSnapshot`：同一 `ownerPID + windowID`、确认时
窗口 frame、显示器 ID、scale 和 topology generation。ROI 必须完全位于该窗口可见
区域；跨窗口、跨进程、跨显示器 union 以及无法解析到唯一窗口的手动区域仍可做静态
截图，但不能开始长截图。

```swift
enum ScrollCaptureState: Equatable {
    case idle
    case acquiringTarget
    case capturingInitialFrame
    case scrolling
    case waitingForStability
    case matchingOverlap
    case appending
    case paused(ScrollCaptureIssue)
    case completed
    case cancelled
    case failed(ScrollCaptureIssue)
}
```

自动模式在 ROI 中心向目标 PID 合成小步长 scroll-wheel event，并用
`CGPreflightPostEventAccess` 检查事件合成能力。缺少信任时进入手动模式。手动模式由
用户滚动，ToolBox 只检测稳定、捕获和拼接。

进入长截图前先关闭选区 overlay，若从编辑器启动则临时 order-out 编辑器；随后激活并
复验目标应用/窗口。捕获控制使用不抢占目标应用的 nonactivating panel，并放在 ROI
之外。自动和手动滚动期间目标窗口必须保持前台；任何激活、窗口或 ROI 复验失败都暂停
且不追加。完成/取消/失败后，coordinator 按来源恢复编辑器或原前台应用。

### 拼接

每轮：

1. 捕获 ROI；
2. 等待连续采样差异进入稳定阈值；
3. 将上一帧底部与新帧顶部的候选重叠带转为亮度图；
4. 忽略光标、小面积动画和连续不变 header/footer；
5. 估计垂直 offset 和 confidence；
6. confidence 达标才追加非重叠区域；
7. 连续三帧没有新内容时完成。

低置信度、反向滚动、窗口移动/缩放、目标 PID 退出、显示器变化或 ROI 尺寸变化时暂停
或失败，不静默生成错图。用户可以重试、切换手动、结束并保留已有部分或取消。

帧按条带写入 session 临时目录，编辑预览使用 tiled/downsampled 图。达到高度
60,000 px 或预计 RGBA 512 MiB 时停止追加并允许进入编辑器。编辑渲染和导出也必须
逐 tile/band 工作，使用磁盘或 mmap backing，不建立第二个完整 RGBA context；峰值
resident working set 的验收上限为 256 MiB（不含独立 OCR worker）。正常结束后删除
中间帧；启动时清理超过 24 小时的遗留 session。

## 设置

### 快捷键页

普通规则列表显示动作、启用状态、当前组合、录制按钮、冲突状态和恢复默认。擦屏幕
退出规则不可禁用。媒体键在分隔 section 中只显示现有开关和权限状态。

### 截图页

- 截图后默认进入编辑器；
- AX 智能候选开关；
- 默认 OCR pipeline；
- PP-OCRv6 默认 profile，初始 tiny；
- 模型下载、进度、版本、校验、占用和删除；
- 长截图默认模式；
- 截图后复制/保存行为；
- Screen Recording、Accessibility、事件合成权限状态。

设置通过 coordinator/store 写入，SwiftUI 不直接拥有系统生命周期。

## 权限与降级

| 能力 | 权限/资源 | 降级 |
| --- | --- | --- |
| Carbon 快捷键 | 无 TCC | 冲突时保留旧组合 |
| 屏幕捕获 | Screen Recording | 不打开 overlay，提供授权入口 |
| AX 元素选择 | Accessibility | 窗口候选和手动区域 |
| 自动滚动 | 事件合成访问 | 手动滚动 |
| PP-OCRv6 | 本地模型 | 仅禁用相应 OCR 动作 |
| 高级 OCR | 本地模型 + worker | 保留 PP-OCRv6、原图和标注 |
| 模型下载 | 网络 | 已安装模型继续离线工作 |

Input Monitoring 不是截图、AX 选择或自动滚动的新要求。它只属于现有媒体键监听路径。

## 错误与资源安全

1. 所有 public async operation 返回 typed error，不用空结果代替失败。
2. 捕获、OCR、导出和长截图任务均可取消；取消后状态回到可继续操作的位置。
3. OCR worker、模型下载和长截图临时目录不能持有用户截图超过必要生命周期。
4. 模型归档必须防 path traversal、symlink escape、尺寸欺骗和哈希不匹配。
5. 日志只记录 pipeline、耗时、尺寸、错误类别和模型版本，不记录截图内容或 OCR 文本。
6. 超大截图在建立完整输出 buffer 前检查尺寸和乘法溢出。
7. AppDelegate stop 路径必须注销快捷键、关闭 overlay、取消任务、停止 worker 并清理
   临时 lease；所有清理幂等。

## 测试

### 自动测试

- 快捷键默认值、持久化、未知 schema、损坏数据、内部重复、系统冲突和回滚；
- event hot key ID 唯一路由、停用和析构注销；
- 多屏负坐标、上下排列、混合 scale 和跨屏裁剪；
- AX 无权限、超时、失效、零面积和父子候选；
- 普通点击/拖拽自动完成、Shift 相连添加/移除、非相邻拒绝、松开 Shift 完成、撤销和 Delete；
- 普通/滚动模式切换、滚动模式选区自动开始，以及手柄和键盘调整不自动提交；
- annotation 增删改、undo/redo、坐标映射和导出；
- manifest 解析、SHA-256、staging、原子安装、损坏归档和 lease；
- OCR request/result schema、取消、worker crash、超时和重新启动；
- overlap 已知 offset、重复帧、低置信度、固定 header、反向滚动和资源上限；
- 所有权限拒绝与降级路径。

系统 API 使用协议或闭包表注入；持久化使用独立 UserDefaults suite；纯值逻辑不依赖
AppKit。图像算法使用仓库内固定夹具和像素级断言。

### 真机验收

- 内建屏、Retina 外屏、非 Retina 外屏和混合排列；
- Spaces、全屏应用、Stage Manager、睡眠唤醒和显示器热插拔；
- Safari、Chrome、Finder、系统设置、PDF、聊天列表和 Electron；
- 中文简繁、英文、日文、混排、低清和长图 OCR；
- 模型首次下载、断网、损坏、更新、删除和磁盘不足；
- Developer ID 签名、公证和权限升级路径。

## 交付顺序

1. 统一快捷键注册表；
2. 静态截图与 Shift 多元素扩选；
3. 非破坏标注编辑器；
4. 本地 PaddleOCR；
5. 长截图。

每阶段必须有聚焦 XCTest、全量测试、Debug/Release 构建、README 更新和真机验收记录。
后一阶段只能消费前一阶段已验证的公开接口。
