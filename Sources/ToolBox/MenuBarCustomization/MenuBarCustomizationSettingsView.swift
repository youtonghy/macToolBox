import SwiftUI

/// Settings → 自定义: a WYSIWYG editor for the live menu-bar layout.
///
/// Cards share the exact rendering dispatch (`MenuBarElementSectionView`) with
/// the real panel; only the interaction layer differs — visibility toggles and
/// drag ordering are live, business controls are read-only.
struct MenuBarCustomizationSettingsView: View {
    fileprivate static let previewWidth: CGFloat = 460

    @ObservedObject var customization: MenuBarCustomizationModel
    @ObservedObject var hardware: HardwareMenuModel
    @ObservedObject var displayControl: DisplayControlMenuModel
    @ObservedObject var audioRouting: AudioRoutingService
    @ObservedObject var focusMode: FocusModeCoordinator
    @ObservedObject var wifiSignal: WiFiSignalModel
    @ObservedObject var networkLocation: NetworkLocationModel
    @EnvironmentObject private var featureState: FeatureState

    private var runtimeContext: MenuBarElementRuntimeContext {
        MenuBarElementRuntimeContext(
            cableItemCount: hardware.cableItems.count,
            audioRowCount: audioRouting.menuRows.count,
            isAudioLiteMode: audioRouting.isLiteMode,
            hasExternalDisplay: displayControl.hasExternalDisplay,
            showsColorPreset: displayControl.presetAvailable
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsChrome.sectionSpacing) {
            hintCard

            editorList
                .frame(
                    minWidth: 0,
                    maxWidth: .infinity,
                    maxHeight: .infinity,
                    alignment: .topLeading
                )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var hintCard: some View {
        SettingsSection(
            title: L10n.string("菜单栏布局"),
            subtitle: L10n.string("拖拽调整顺序，开关控制显示")
        ) {
            HStack(alignment: .center, spacing: 12) {
                Text(L10n.string("点击条目展开完整实时预览；布局修改立即同步到菜单栏。"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 8)

                Button {
                    customization.resetToDefault()
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(customization.isDefaultLayout)
                .help(L10n.string("恢复默认布局"))
                .accessibilityLabel(L10n.string("恢复默认布局"))
            }
        }
    }

    private var editorList: some View {
        List {
            ForEach(Array(customization.entries.enumerated()), id: \.element.id) { pair in
                EditableMenuBarElementCard(
                    entry: pair.element,
                    position: pair.offset + 1,
                    isRuntimeAvailable: runtimeContext.isRuntimeAvailable(pair.element.id),
                    hardware: hardware,
                    displayControl: displayControl,
                    audioRouting: audioRouting,
                    focusMode: focusMode,
                    wifiSignal: wifiSignal,
                    networkLocation: networkLocation,
                    featureState: featureState,
                    setVisible: { customization.setVisible($0, for: pair.element.id) }
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 8))
                .accessibilityElement(children: .contain)
            }
            .onMove { offsets, destination in
                customization.move(fromOffsets: offsets, toOffset: destination)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .accessibilityLabel(L10n.string("菜单栏布局"))
    }

}

/// One editable menu-bar element: drag handle, name, visibility toggle and a
/// read-only live preview (or an availability placeholder).
private struct EditableMenuBarElementCard: View {
    let entry: MenuBarElementEntry
    let position: Int
    let isRuntimeAvailable: Bool
    @ObservedObject var hardware: HardwareMenuModel
    @ObservedObject var displayControl: DisplayControlMenuModel
    @ObservedObject var audioRouting: AudioRoutingService
    @ObservedObject var focusMode: FocusModeCoordinator
    @ObservedObject var wifiSignal: WiFiSignalModel
    @ObservedObject var networkLocation: NetworkLocationModel
    @ObservedObject var featureState: FeatureState
    let setVisible: (Bool) -> Void
    @State private var isExpanded = false

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: SettingsChrome.innerCornerRadius, style: .continuous)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            headerRow

            if isExpanded {
                if isRuntimeAvailable {
                    livePreview
                } else {
                    unavailablePlaceholder
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(shape.fill(SettingsChrome.cardBackground))
        .overlay(shape.strokeBorder(SettingsChrome.cardBorder, lineWidth: 1))
        .clipShape(shape)
        .opacity(entry.isVisible ? 1 : 0.55)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(entry.id.displayName)
    }

    private var headerRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .accessibilityLabel(L10n.string("拖拽调整顺序"))
                .accessibilityValue(String(format: L10n.string("第 %d 位"), position))

            Button {
                isExpanded.toggle()
            } label: {
                HStack(spacing: 10) {
                    SettingsIconBadge(
                        systemName: entry.id.symbolName,
                        accent: accent,
                        emphasized: entry.isVisible && isRuntimeAvailable
                    )

                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.id.displayName)
                            .font(.system(size: 13, weight: .semibold))

                        if !isRuntimeAvailable {
                            Text(L10n.string("当前不可用，菜单栏暂不显示；恢复后自动回到原位置"))
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    Spacer(minLength: 8)

                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 12)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L10n.string(isExpanded ? "收起预览" : "展开完整预览"))
            .accessibilityLabel(entry.id.displayName)
            .accessibilityValue(L10n.string(isExpanded ? "收起预览" : "展开完整预览"))

            Toggle(
                "",
                isOn: Binding(
                    get: { entry.isVisible },
                    set: setVisible
                )
            )
            .toggleStyle(.switch)
            .labelsHidden()
            .fixedSize()
            .accessibilityLabel(String(format: L10n.string("在菜单栏显示“%@”"), entry.id.displayName))
        }
    }

    private var accent: Color {
        switch entry.id {
        case .chipPower:
            return Color(nsColor: .systemOrange)
        case .appAudio:
            return Color(nsColor: .systemGreen)
        case .cableStatus:
            return Color(nsColor: .systemPurple)
        case .wifiSignal:
            return Color(nsColor: .systemGreen)
        case .displayControl:
            return Color(nsColor: .systemTeal)
        case .quickControls:
            return Color(nsColor: .systemIndigo)
        }
    }

    /// Read-only live rendering of the element, shared with the real panel.
    /// Business controls stay inert so editing the layout can never trigger
    /// screen wipes, sleep prevention, display or audio changes.
    private var livePreview: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            MenuBarElementSectionView(
                element: entry.id,
                hardware: hardware,
                displayControl: displayControl,
                audioRouting: audioRouting,
                focusMode: focusMode,
                wifiSignal: wifiSignal,
                networkLocation: networkLocation,
                state: featureState,
                isInteractive: false
            )
            .frame(
                width: MenuBarCustomizationSettingsView.previewWidth,
                alignment: .leading
            )
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var unavailablePlaceholder: some View {
        SettingsEmptyState(
            symbolName: placeholderSymbol,
            title: placeholderTitle,
            description: L10n.string("菜单栏暂不显示该组件，数据恢复后自动回到原位置")
        )
    }

    private var placeholderSymbol: String {
        switch entry.id {
        case .appAudio:
            return "speaker.slash"
        case .cableStatus:
            return "cable.connector.slash"
        case .displayControl:
            return "display.trianglebadge.exclamationmark"
        default:
            return "info.circle"
        }
    }

    private var placeholderTitle: String {
        switch entry.id {
        case .appAudio:
            return L10n.string("当前没有应用音频数据")
        case .cableStatus:
            return L10n.string("未检测到线缆")
        case .displayControl:
            return L10n.string("未检测到外接显示器")
        default:
            return L10n.string("当前不可用")
        }
    }
}
