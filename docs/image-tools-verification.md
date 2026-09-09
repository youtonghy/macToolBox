# 图像处理修复与验证记录

验证日期：2026-09-10。环境：macOS 27.0（26A5425a）、Xcode 26.6；项目部署目标仍为 macOS 14。

## 需求复核

批准计划中的 7 项问题均已修复：

| 问题 | 最终行为 | 验证 |
| --- | --- | --- |
| 转换格式泄漏到压缩模式 | 面板压缩模式不传输出格式；转换模式记住用户选择 | 模型测试、独立面板交互 |
| EXIF 方向重复旋转 | 像素变换后将方向归一化为 1，更新实际尺寸；变换失败保留原件 | 方向 1–8 × 保留／剥离元数据，比较显示像素 |
| 并发目标覆盖 | 同目录临时文件写完后，通过 RENAME_EXCL 排他发布；冲突递增编号 | 20 个并发发布、同名不同格式转换、已有文件保护 |
| 转换被无收益保护拦截 | 无收益保护仅作用于纯压缩；显式输出格式、实际缩放或剥离元数据允许增大 | JPEG→PNG 变大、纯压缩原件字节不变、CLI 和面板文案 |
| WebP 丢元数据 | 写入归一化 EXIF、XMP、ICC；EXIF 保留拍摄时间、GPS 和 DPI | JPEG／PNG／WebP 保留／剥离与缩放测试 |
| TIFF、HEIC/AVIF 注入持续增长 | TIFF 使用长度和校验和尾部结构，兼容可识别旧尾注；BMFF 核对完整尾部块长度 | 连续 20 次、旧格式归一化、非本工具尾部保护 |
| 取消后仍写文件 | 检查批次、处理和提交边界；完成正在提交的文件后解除运行状态 | 已取消批次、提交前取消、批次边界取消、旧回调隔离 |

补充的文件安全行为：目标发布失败保留源文件；目标已发布但源文件删除失败时保留两份文件，并报告“源文件未删除”。CLI 使用现有 saved-as 结果及 detail 字段表达该情况，不增加协议枚举值。

面板运行期间不能修改文件列表或模式；关闭其他窗口不会取消图像任务。取消后已完成项保留，未开始项单独标记。

## 工程复核

- 复用 ImageIO 和项目已有 libwebp mux，没有增加第三方依赖。
- 保留既有 CLI 请求／响应字段；totalBytesSaved 的负值表示产物增大。
- 元数据统一归一化后供两个编码通道使用。WebP 的 EXIF 由 ImageIO 序列化，再校正临时载体的尺寸字段。
- 逐帧验证换 Hash 结果，检查帧数并限制各帧像素预算；逐帧释放渲染缓冲区。
- 文件名冲突保护由文件系统原子操作保证，不依赖仅覆盖当前批次的内存锁。
- 取消和失败测试使用明确的任务／提交边界，避免依赖随机延时。
- 保留工作区中原有的其他功能改动；未发布或部署。

## 已执行的验证

### 图像专项测试

对以下测试目标执行了 xcodebuild test 的 `-only-testing` 过滤：

- ToolBoxTests/ImagePipelineTests
- ToolBoxTests/ImagePipelineSafetyTests
- ToolBoxTests/ImageHashChangerTests
- ToolBoxTests/ImageFormatTests
- ToolBoxTests/ImageFileCollectorTests
- ToolBoxTests/ImageToolsRegressionTests
- ToolBoxTests/ImageToolsPanelModelTests
- ToolBoxCLITests

结果：通过。新测试使用 Swift Testing，并含参数化方向、格式和元数据选项用例。

### 全套测试

```sh
xcodebuild test \
  -project ToolBox.xcodeproj -scheme ToolBox \
  -destination 'platform=macOS' \
  -derivedDataPath /tmp/mactoolbox-image-verification \
  -clonedSourcePackagesDirPath "$PWD/.derivedData/SourcePackages" \
  -disableAutomaticPackageResolution \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=
```

结果：`TEST SUCCEEDED`。主 XCTest 目标执行 994 项（5 项跳过），CLI XCTest 执行 9 项，新增 Swift Testing 执行 20 个测试函数（含参数化用例），均无失败。

5 项跳过均为 PaddleOCRRuntimeIntegrationTests，需要本地模型或指定诊断图像；没有图像处理测试因该条件跳过。

最初使用 `CODE_SIGNING_ALLOWED=NO` 运行全套测试时，现有电源采样 XPC 身份测试因 invalidSignature 失败。改用项目默认的本地临时签名后通过；未修改该测试或电源采样实现。

### 构建

分别将 CONFIG 设为 Debug、Release 执行：

```sh
xcodebuild build \
  -project ToolBox.xcodeproj -scheme ToolBox \
  -configuration "$CONFIG" -destination 'platform=macOS' \
  -derivedDataPath /tmp/mactoolbox-image-verification \
  -clonedSourcePackagesDirPath "$PWD/.derivedData/SourcePackages" \
  -disableAutomaticPackageResolution \
  CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=
```

结果：Debug、Release 均 `BUILD SUCCEEDED`。

另外执行 `git diff --check` 和三种语言 Localizable.strings 的 `plutil -lint`，均通过。

### 面板交互检查

用当前图像模块编译独立测试面板，仅加载 `/tmp/toolbox-image-review/ui-input` 中的生成样本：

1. 转换模式选择 PNG，再切回压缩，开启剥离元数据和另存，产物仍为 JPEG。
2. 切回转换模式，保留 PNG 选择；生成 PNG，界面正确显示体积增加。
3. 未对个人图像执行操作。取消、重新开始、窗口归属和结果保留由可控的模型测试验证。

## 限制

- 未在 macOS 14 等其他系统版本实机运行；保持原部署目标和运行时格式能力检测。
- 未在所有网络／外置文件系统测试 RENAME_EXCL；不支持该操作时明确失败并保留原件，不降级为覆盖写入。
- 旧 TIFF 尾注只有符合本工具既有结构时才会清理，无法确认的尾部数据保留。
- 本次不扩展图像格式、动图压缩或 HDR 编码支持，也不恢复此前已经丢失的原始数据。
