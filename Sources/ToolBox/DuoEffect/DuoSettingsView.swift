import SwiftUI

struct DuoSettingsView: View {
    @ObservedObject var model: DuoEffectModel
    @ObservedObject var sensor: LidAngleSensor
    @ObservedObject var permissions: ShortcutPermissionCenter
    @Binding var isEnabled: Bool

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: SettingsChrome.sectionSpacing) {
                effectSection
                endpointSection
                permissionSection
                parametersSection
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 4)
        }
        .onAppear {
            // Keep the hinge sensor alive while this tab is open so the live
            // angle and calibration work before the effect is enabled.
            model.setSettingsVisible(true)
            permissions.refresh()
        }
        .onDisappear {
            model.setSettingsVisible(false)
        }
    }

    private var effectSection: some View {
        SettingsSection(title: "Duo 屏幕效果", subtitle: model.statusText) {
            VStack(spacing: 8) {
                SettingsInnerCard {
                    HStack(spacing: 12) {
                        SettingsIconBadge(
                            systemName: "macbook",
                            accent: Color(nsColor: .systemIndigo),
                            emphasized: isEnabled
                        )

                        VStack(alignment: .leading, spacing: 3) {
                            Text("屏幕展开效果")
                                .font(.system(size: 13, weight: .semibold))
                            Text("随屏幕开合角度，桌面呈现悬浮玻璃过渡")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                        }

                        Spacer(minLength: 12)

                        Toggle("", isOn: $isEnabled)
                            .toggleStyle(.switch)
                            .labelsHidden()
                    }
                }

                SettingsInnerCard {
                    HStack(spacing: 12) {
                        SettingsIconBadge(
                            systemName: sensor.isSupported
                                ? "checkmark.circle.fill"
                                : "exclamationmark.circle.fill",
                            accent: sensor.isSupported
                                ? Color(nsColor: .systemGreen)
                                : Color(nsColor: .systemOrange),
                            emphasized: sensor.isSupported
                        )

                        VStack(alignment: .leading, spacing: 3) {
                            Text("铰链传感器")
                                .font(.system(size: 13, weight: .semibold))
                            Text(sensor.statusText)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                        }

                        Spacer(minLength: 12)

                        if sensor.isAvailable {
                            Text("\(Int(sensor.angle.rounded()))°")
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                        }
                    }
                }
            }
        }
    }

    private var endpointSection: some View {
        SettingsSection(
            title: "展开终点",
            subtitle: "效果从 0° 起算，到展开终点恢复清晰 · 当前 \(Int(model.openAngle.rounded()))°"
        ) {
            SettingsInnerCard {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("将屏幕打开到日常使用的位置后保存")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                        if !model.calibrationMessage.isEmpty {
                            Text(model.calibrationMessage)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Color(nsColor: .systemTeal))
                        }
                    }

                    Spacer(minLength: 8)

                    Button("保存当前角度") {
                        model.saveOpenAngle()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(!sensor.isAvailable)
                }
            }
        }
    }

    private var permissionSection: some View {
        let granted = permissions.snapshot.screenCaptureTrusted

        return SettingsSection(title: "权限") {
            SettingsInnerCard {
                HStack(spacing: 12) {
                    SettingsIconBadge(
                        systemName: granted ? "checkmark.shield.fill" : "exclamationmark.shield.fill",
                        accent: granted ? Color(nsColor: .systemGreen) : Color(nsColor: .systemOrange),
                        emphasized: granted
                    )

                    VStack(alignment: .leading, spacing: 3) {
                        Text("屏幕录制")
                            .font(.system(size: 13, weight: .semibold))
                        Text("实时捕获桌面内容，仅在本机处理")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 12)

                    Text(granted ? "已授权" : "未授权")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(granted ? Color.green : Color.orange)

                    if !granted {
                        Button("授权") {
                            permissions.requestScreenCapture()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }
            }
        }
    }

    private var parametersSection: some View {
        SettingsSection(title: "效果参数") {
            VStack(spacing: 8) {
                SettingsInnerCard {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 10) {
                            Text("磨砂强度")
                                .font(.system(size: 13, weight: .semibold))

                            Spacer(minLength: 8)

                            Text("\(Int((model.frost / DuoEffectModel.frostRange.upperBound * 100).rounded()))%")
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                        }

                        ScrollWheelSlider(
                            value: $model.frost,
                            in: DuoEffectModel.frostRange,
                            step: 0.01
                        )
                    }
                }

                SettingsInnerCard {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("预览效果")
                                .font(.system(size: 13, weight: .semibold))
                            Text("8 秒实时预览，无需移动屏幕")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                        }

                        Spacer(minLength: 8)

                        Button("预览 8 秒") {
                            model.onPreview()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .disabled(!sensor.isSupported)
                    }
                }
            }
        }
    }
}
