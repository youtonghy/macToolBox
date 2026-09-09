import SwiftUI

/// 设置 → 图像：默认参数与能力状态。
struct ImageSettingsView: View {
    @AppStorage("imageTools.defaultLevel") private var defaultLevel = ImageQualityTable.defaultLevel
    @AppStorage("imageTools.defaultNaming") private var defaultNaming = "overwrite"

    var body: some View {
        Form {
            Section(L10n.string("压缩/转换默认值")) {
                Picker(L10n.string("质量级别"), selection: $defaultLevel) {
                    ForEach(1 ... 6, id: \.self) { level in
                        Text("\(level)（\(level == 1 ? L10n.string("最高质量") : level == 6 ? L10n.string("最小体积") : L10n.string("均衡"))）").tag(level)
                    }
                }
                Picker(L10n.string("输出命名"), selection: $defaultNaming) {
                    Text(L10n.string("覆盖原文件")).tag("overwrite")
                    Text(L10n.string("加后缀另存")).tag("suffix")
                }
                LabeledContent(L10n.string("说明")) {
                    Text(L10n.string("纯压缩无收益时保留原件；转换、缩放或剥离元数据允许体积增加。"))
                        .foregroundStyle(.secondary)
                }
                LabeledContent(L10n.string("转换")) {
                    Text(L10n.string("转换并覆盖时写入新扩展名文件，成功后删除源文件（先写后删）。"))
                        .foregroundStyle(.secondary)
                }
            }

            Section(L10n.string("换 Hash")) {
                LabeledContent(L10n.string("原理")) {
                    Text(L10n.string("在格式规范的保留位置注入随机注释（不重编码），MD5/SHA-1/SHA-256 全部变化，像素逐位不变，可重复执行。"))
                        .foregroundStyle(.secondary)
                }
                LabeledContent(L10n.string("支持格式")) {
                    Text(L10n.string("JPEG、PNG、WebP、GIF、HEIC、AVIF、TIFF"))
                        .foregroundStyle(.secondary)
                }
            }

            Section(L10n.string("命令行")) {
                LabeledContent(L10n.string("压缩")) {
                    Text("toolbox image compress <路径> --level 1-6")
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
                LabeledContent(L10n.string("转换")) {
                    Text("toolbox image convert <路径> --format webp")
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
                LabeledContent(L10n.string("换 Hash")) {
                    Text("toolbox image rehash <路径>")
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
            }

            Section(L10n.string("编码能力")) {
                LabeledContent("WebP") {
                    Text(L10n.string("可用（内嵌 libwebp）")).foregroundStyle(.green)
                }
                ForEach([ImageFormat.heic, .avif, .jpeg, .png, .tiff], id: \.self) { format in
                    LabeledContent(format.rawValue.uppercased()) {
                        Text(ImageCapabilities.canImageIOEncode(format) ? L10n.string("可用") : ImageCapabilities.unavailableReason(for: format) ?? L10n.string("不可用"))
                            .foregroundStyle(ImageCapabilities.canImageIOEncode(format) ? Color.green : Color.orange)
                    }
                }
                LabeledContent(L10n.string("动图")) {
                    Text(L10n.string("GIF 动画与 HDR/宽色域内容暂不支持压缩/转换（换 Hash 不受影响）；JXL 输出暂不支持。"))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Color.clear)
    }
}
