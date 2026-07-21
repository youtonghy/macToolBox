# Background Music 与 macOS 分应用音频控制调研

调研日期：2026-07-21
上游版本：`kyleneideck/BackgroundMusic` commit [`8c25450`](https://github.com/kyleneideck/BackgroundMusic/tree/8c25450e9b0d3867417c4872018b03fb30c0c85c)（2026-06-10）

## 结论

目标需要拆成三项能力，它们在 macOS 上的可行性不同：

| 能力 | 可行性 | 关键限制 |
| --- | --- | --- |
| 分应用输出音量 0%-300% | 可行 | 必须先拿到该应用的独立音频流，再做 DSP 增益；300% 会削波，不能靠普通设备音量属性实现 |
| 分应用输出到指定设备 | 可行，但工作量明显高于音量 | Core Audio 没有“替另一个进程设置输出设备”的公开属性；需要截获/静音原流，并由本应用建立到目标设备的独立播放管线 |
| 强制某应用使用指定输入源 | 通用方案不可行 | Core Audio 只公开系统默认输入设备和进程当前所用设备的查询，没有替任意第三方进程改输入设备的公开 API；只能依赖目标应用自己选择，或让用户选择本产品提供的虚拟输入设备 |

因此，建议第一版范围为：

1. 弹窗提供每应用 `0%-300%` 的步进百分比，默认 `100%`。
2. 设置页提供同一数值的精细滑块和每应用输出设备。
3. “输入源”先作为受限能力设计：显示当前/期望输入设备并给出应用内选择指引；只有在引入虚拟输入设备且 Zoom 等应用选中它后，才能稳定控制送入该应用的信号。

## Background Music 实际做了什么

Background Music 不是调用一个系统级“应用音量 API”。它由两个主要部分组成：

- `BGMDriver` 是基于 `AudioServerPlugIn` 的虚拟音频设备驱动，向系统同时暴露名为 Background Music 的输入和输出设备。
- `BGMApp` 启动时把虚拟设备设为系统默认输出，从虚拟设备的输入流读取混音结果，再播放到一个真实输出设备。上游架构说明明确描述了这条数据通路：[DEVELOPING.md](https://github.com/kyleneideck/BackgroundMusic/blob/8c25450e9b0d3867417c4872018b03fb30c0c85c/DEVELOPING.md#how-background-music-works)。

驱动收到 HAL 提供的 `AudioServerPlugInClientInfo`，其中有 client ID、PID 和 bundle ID；这使驱动能在每个客户端的 `kAudioServerPlugInIOOperationProcessOutput` 阶段、系统混音前修改该客户端的样本：[BGM_Client.cpp](https://github.com/kyleneideck/BackgroundMusic/blob/8c25450e9b0d3867417c4872018b03fb30c0c85c/BGMDriver/BGMDriver/DeviceClients/BGM_Client.cpp)、[BGM_Device.cpp](https://github.com/kyleneideck/BackgroundMusic/blob/8c25450e9b0d3867417c4872018b03fb30c0c85c/BGMDriver/BGMDriver/BGM_Device.cpp#L1473-L1491)。应用与驱动之间的“应用音量”通信是 BGM 自定义的 AudioObject 属性，不是 Apple 通用属性：[BGM_Types.h](https://github.com/kyleneideck/BackgroundMusic/blob/8c25450e9b0d3867417c4872018b03fb30c0c85c/SharedSource/BGM_Types.h#L144-L163)。

上游当前的相对音量原始范围是 `0...100`，中点 `50` 为原始音量，驱动将曲线结果乘以 4，所以最大线性增益为约 `4.0x`；README 也明确说明可把应用放大到其自身最大音量以上：[BGM_Clients.cpp](https://github.com/kyleneideck/BackgroundMusic/blob/8c25450e9b0d3867417c4872018b03fb30c0c85c/BGMDriver/BGMDriver/DeviceClients/BGM_Clients.cpp#L312-L357)、[README Application volume](https://github.com/kyleneideck/BackgroundMusic/blob/8c25450e9b0d3867417c4872018b03fb30c0c85c/README.md#application-volume)。因此 `0%-300%` 可以定义为更直观的线性增益 `0.0...3.0`，`100% = 1.0`；不建议照搬上游的 `0...100` UI 映射。

上游只维护一个真实输出设备。菜单切换的是整个 BGM play-through 的目的设备，而不是某个应用的目的设备：[BGMAudioDeviceManager.mm](https://github.com/kyleneideck/BackgroundMusic/blob/8c25450e9b0d3867417c4872018b03fb30c0c85c/BGMApp/BGMApp/BGMAudioDeviceManager.mm#L227-L337)、[BGMOutputDeviceMenuSection.mm](https://github.com/kyleneideck/BackgroundMusic/blob/8c25450e9b0d3867417c4872018b03fb30c0c85c/BGMApp/BGMApp/BGMOutputDeviceMenuSection.mm#L320-L369)。所以“Zoom 到耳机、其他应用到扬声器”不是上游已有功能，不能通过给现有菜单多存一个 device ID 完成。

## Apple 公开 API 的边界

### 设备发现和系统默认设备

Core Audio 的 Audio Hardware API 提供：

- `kAudioHardwarePropertyDevices`：枚举系统音频设备；
- `kAudioHardwarePropertyDefaultInputDevice`：系统默认输入；
- `kAudioHardwarePropertyDefaultOutputDevice`：系统默认输出；
- `kAudioHardwarePropertyDefaultSystemOutputDevice`：系统提示音输出。

这些都是系统级默认值，不是每应用策略。参见 Apple [Audio Hardware](https://developer.apple.com/documentation/coreaudio/audio-hardware) 文档和 SDK `AudioHardware.h` 的 AudioSystemObject properties。

macOS 还公开了 Process AudioObject：可以按 PID 找到进程对象，并通过 `kAudioProcessPropertyDevices` 查询该进程当前用于输入或输出的设备。但该属性的语义是“当前使用的设备列表”，公开 API 没有相应的“为目标进程设置设备”选择器。参见 Apple [Audio Hardware](https://developer.apple.com/documentation/coreaudio/audio-hardware) 中的 Process properties。

结果是：应用可以选择自己创建的 AudioUnit/AudioDevice IO 所使用的设备，也可以修改全局默认设备，但不能可靠地改写 Zoom、Chrome 等另一个进程内部保存的输入/输出设备选择。

### macOS 14.2+ Process Tap

`AudioHardwareCreateProcessTap` 自 macOS 14.2 起公开。`CATapDescription` 可以包含指定 process object，得到这些进程输出音频的输入流；`CATapMuteBehavior` 还能让原音频继续播放、始终静音，或仅在 tap 被读取时静音。Apple 公开定义见 [`AudioHardwareCreateProcessTap`](https://developer.apple.com/documentation/coreaudio/audiohardwarecreateprocesstap(_:_:)) 和 [`CATapDescription`](https://developer.apple.com/documentation/coreaudio/catapdescription)。

Tap 的数据通过包含该 tap 的 Aggregate Audio Device 暴露给 IO；公开的 `AudioHardwareCreateAggregateDevice` 与 `kAudioAggregateDeviceTapListKey` 支持创建私有、进程生命周期内的 aggregate device。参见 Apple [`AudioHardwareCreateAggregateDevice`](https://developer.apple.com/documentation/coreaudio/audiohardwarecreateaggregatedevice(_:_:))。

这给出了不安装自定义 HAL 驱动的现代输出方案：

```text
Zoom process -> Process Tap (mute original) -> 3.0 gain -> headphone output AudioUnit
Music process -> Process Tap (mute original) -> 1.0 gain -> speaker output AudioUnit
```

但它是“捕获、处理、重新播放”，不是改变 Zoom 自己的输出设备。实现仍需处理每个目标设备的 sample rate、channel layout、clock drift、设备断开、延迟和实时线程约束。系统音频捕获权限的实际提示与拒绝恢复行为也必须在支持的各 macOS 版本上做真机原型验证。

### 输入源

Process Tap 只处理进程的**输出**音频，不能替某个进程注入或重定向麦克风输入。通用输入方案需要一个虚拟输入设备：

```text
physical mic -> our capture/processing -> virtual input device -> Zoom
```

最后一步仍要求 Zoom 在自身设置中选择该虚拟输入设备，或让该虚拟设备成为系统默认输入后由 Zoom 跟随默认值。若 Zoom 已固定选择其他设备，本应用没有公开 API 强制覆盖。

Background Music 的虚拟设备输入流主要用于把系统输出暴露给 QuickTime 等录音应用；上游 README 同样要求用户在录音应用里手动选择 Background Music，不能自动替目标应用选择：[Recording system audio](https://github.com/kyleneideck/BackgroundMusic/blob/8c25450e9b0d3867417c4872018b03fb30c0c85c/README.md#recording-system-audio)。

## 推荐架构选择

### 推荐：macOS 14.2+ 的 Process Tap 输出管线

如果本产品可以把此功能的最低系统要求定为 macOS 14.2，优先做 Process Tap：

- 使用公开 API，避免安装 `/Library/Audio/Plug-Ins/HAL` 驱动；
- 以 bundle ID 保存规则，以 PID/process object 绑定当前运行实例；
- 每个有自定义规则的应用建立 tap，`muteBehavior = mutedWhenTapped`，确保只有成功启动重放后才静音原流；
- 按目标输出设备分组，组内混音后通过独立 AudioUnit/AudioDevice IO 输出；
- 先做线性 `0.0...3.0` 增益，并在最终混音加入 peak meter、软限幅器或明确削波告警；
- 未配置的应用不建 tap，继续走系统原输出，减少常驻开销和故障面。

需要先用一个最小原型验证 Zoom。上游明确记录 Zoom/Teams/Discord 等应用可能由 helper 进程实际发声，按主应用 PID 识别并不总是有效：[Background Music bug template](https://github.com/kyleneideck/BackgroundMusic/blob/8c25450e9b0d3867417c4872018b03fb30c0c85c/.github/ISSUE_TEMPLATE/bug_report.md#L43-L49)。macOS 26 才新增 `CATapDescription.bundleIDs` 和 process restore，因此较低版本要自行维护 bundle ID、helper PID 与重启重绑。

### 兼容路线：定制 AudioServerPlugIn 虚拟设备

若必须支持 macOS 10.13-14.1，可以参考 Background Music 保留虚拟 HAL 驱动路线。但分设备输出要求扩展驱动协议和实时数据结构：在系统混音前按 client/route 分流，维护多条 ring buffer 或 route bus，再由应用为每个真实设备建立 play-through；现有 BGM 只有单一混音 ring buffer和单一真实输出，不能小改获得该能力。

这条路线的安装和维护成本更高：上游驱动安装到 `/Library/Audio/Plug-Ins/HAL`，需要管理员权限，并重启 `coreaudiod` 才加载：[quick_install.sh](https://github.com/kyleneideck/BackgroundMusic/blob/8c25450e9b0d3867417c4872018b03fb30c0c85c/BGMDriver/BGMDriver/quick_install.sh#L162-L209)。驱动崩溃或应用异常退出还可能把虚拟设备留为默认输出，导致系统无声；上游专门提供 XPC helper 恢复默认设备，并在 README 记录该故障恢复步骤。

## 0%-300% 音量语义和安全性

建议数据模型把用户百分比与 DSP 值明确分开：

- 持久化：整数 `0...300`，默认 `100`；
- DSP：`linearGain = percent / 100.0`；
- `0%` 是静音，`100%` 原样，`300%` 是 `3.0x` 振幅，约 `+9.54 dB`；
- 输出设备自身音量保持独立，不把应用增益写进硬件 master volume。

任何超过 `100%` 的线性放大都可能使峰值超过 `1.0` 并削波。Background Music 自己也把“超过中点会削波”列为已知问题：[README Known issues](https://github.com/kyleneideck/BackgroundMusic/blob/8c25450e9b0d3867417c4872018b03fb30c0c85c/README.md#known-issues-and-solutions)。第一版至少应：

- 使用 Float32 管线并在最终输出前检测峰值；
- UI 对 `>100%` 给出非阻塞削波风险状态；
- 明确决定是硬限幅、软限幅，还是允许削波。静默 clamp 会让 300% 的含义不可信，不建议采用。

## 计划建议

### 阶段 0：技术原型和产品边界

1. 确定最低支持 macOS 版本；优先验证 14.2+ Process Tap。
2. 建立命令行/测试宿主原型：枚举 AudioProcess，tap Zoom/helper，静音原流，`1.0x` 重放到指定耳机。
3. 验证设备热插拔、蓝牙切 profile、Zoom 重启/helper PID 变化、权限拒绝和应用崩溃后的原音频恢复。
4. 决定输入源产品表述：第一版不承诺“强制设置”，仅保存期望设备并引导用户在目标应用选择；虚拟输入作为后续独立项目。

### 阶段 1：领域模型和持久化

建立以 bundle ID 为稳定键的 `AppAudioRule`：

- `bundleID`
- `volumePercent: Int`，约束 `0...300`，默认 `100`
- `outputDeviceUID: String?`，为空表示跟随系统默认
- `preferredInputDeviceUID: String?`，先标记为 advisory/unsupported enforcement
- 运行时 PID/process object、tap ID 和设备 AudioObjectID 不持久化

设备规则必须存 UID，不能存会在重启/热插拔后变化的 AudioObjectID。所有 AudioObject 调用应返回明确错误并进入可见降级状态，不能吞掉异常。

### 阶段 2：弹窗最小交互

1. 在当前运行应用列表显示音量百分比，默认 `100%`。
2. 提供减/加按钮或步进器，范围 `0%-300%`；建议步长 `5%`，点击后立即更新规则和音频管线。
3. 目标应用没有活跃音频进程时仍允许保存规则，启动后自动绑定。
4. 后端未就绪或权限缺失时禁用控制并显示具体状态，不显示已生效的假状态。

### 阶段 3：设置页详细控制

1. 每应用显示 `0...300` 精细滑块、数值输入/步进器和 `100%` 重置。
2. 输出设备菜单使用当前可用设备 UID，并提供“系统默认”；设备消失时保留规则但明确回退到默认输出。
3. 输入设备菜单先作为“偏好/需在应用中选择”呈现，不与输出设备使用同一“已生效”状态。
4. 弹窗和设置页共享同一规则 store 与校验逻辑，避免两套百分比映射。

### 阶段 4：音频路由服务

1. Process registry：监听进程对象和运行状态，维护主应用与 helper 的归属。
2. Tap lifecycle：先启动目的设备和 render callback，再读取 tap 并触发静音；失败时销毁 tap，让原音频恢复。
3. Route mixer：按输出设备分组，做 sample-rate conversion、声道映射、增益、峰值检测和限制器。
4. Device lifecycle：监听设备列表和默认输出变化，处理断开、睡眠唤醒和 `coreaudiod` 重启；Apple 文档指出服务重启后缓存和 listeners 必须重新建立。

### 阶段 5：测试和发布门槛

- 单元测试：百分比边界、默认值、UID 持久化、设备消失回退、helper 归属、规则迁移。
- 音频测试：`0/100/300%` 数值增益、双应用隔离、双设备并发、削波/限制器、格式转换。
- 集成测试：Zoom、浏览器 helper、Music；有线耳机、USB、蓝牙、内建扬声器；设备插拔和应用重启。
- 故障测试：权限拒绝、tap 创建失败、输出启动失败、设备中途断开、进程退出和主应用崩溃，确认不会造成永久静音。
- 发布测试：Developer ID 签名、notarization、安装/升级/卸载和权限说明。Apple 的当前分发要求应以 [Notarizing macOS software before distribution](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution) 为准。

## 私有/不支持机制与分发影响

- 不要使用私有 LaunchServices API 去找“responsible process”。Background Music 的源码注释提到存在这种私有 API，但当前实现使用硬编码 helper bundle ID 映射；这本身已经显示该领域会随浏览器/会议应用内部结构变化：[ResponsibleBundleIDsOf](https://github.com/kyleneideck/BackgroundMusic/blob/8c25450e9b0d3867417c4872018b03fb30c0c85c/BGMApp/BGMApp/BGMBackgroundMusicDevice.cpp#L205-L289)。优先用公开 Process properties、运行态观测和可维护的兼容映射。
- `AudioHardwareService*` 旧接口已在新 SDK 中标记 deprecated；不要把它当作分应用控制方案。它处理设备音量/平衡，不解决每进程路由。
- 如果采用 HAL 驱动，产品不能按普通单体 `.app` 处理发布：需要特权安装、升级和卸载路径，异常恢复 helper，以及对 `coreaudiod` 生命周期的测试。还需在确定分发渠道后单独核实 App Sandbox/Mac App Store 可接受性。
- 如果直接复制或修改 Background Music 源码，必须先做许可证决策：仓库主体是 GPLv2，派生和分发会带来对应源代码与许可义务；仅参考架构、基于 Apple 公开 API 独立实现可降低耦合，但仍应保留独立实现记录。上游许可见 [LICENSE](https://github.com/kyleneideck/BackgroundMusic/blob/8c25450e9b0d3867417c4872018b03fb30c0c85c/LICENSE)。

## 尚需原型确认的风险

1. Process Tap 对 Zoom 及其 helper 的实际粒度，以及呼叫过程中 PID/设备切换行为。
2. 多目标设备同时输出时的时钟漂移和长期同步；不能假设两个硬件时钟一致。
3. 蓝牙耳机同时承担 Zoom 输入和输出时，系统切到通话 profile 后的采样率/声道变化。
4. 音频捕获权限在目标最低版本上的提示、撤销和重新授权体验。
5. `300%` 下采用何种限幅策略，以及可接受的额外延迟和 CPU 开销。
6. 当前 macToolBox 的签名、sandbox 和发布渠道是否允许目标方案；在原型通过前不应先写完整 UI。
