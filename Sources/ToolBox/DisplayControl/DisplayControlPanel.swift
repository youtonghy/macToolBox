import SwiftUI

enum DisplayControlPanelRow: Hashable {
    case brightness
    case contrast
    case preset
    case volume
}

enum DisplayControlPanelLayout {
    static let iconWidth: CGFloat = 18
    static let labelWidth: CGFloat = 66
    static let rowSpacing: CGFloat = 8
    static let displayPickerWidth: CGFloat = 210
    static let minimumPresetControlWidth: CGFloat = 210
    static let panelPadding: CGFloat = 8

    static func rows(showsPreset: Bool) -> [DisplayControlPanelRow] {
        showsPreset
            ? [.brightness, .contrast, .preset, .volume]
            : [.brightness, .contrast, .volume]
    }

    static func availablePresetControlWidth(panelWidth: CGFloat) -> CGFloat {
        max(
            0,
            panelWidth
                - MenuPanelLayout.contentInsets.left
                - MenuPanelLayout.contentInsets.right
                - MenuPanelLayout.sectionPadding * 2
                - panelPadding * 2
                - iconWidth
                - labelWidth
                - rowSpacing * 2
        )
    }
}

struct DisplayControlPanel: View {
    @ObservedObject var model: DisplayControlMenuModel

    var body: some View {
        if model.hasExternalDisplay {
            VStack(alignment: .leading, spacing: MenuPanelLayout.controlRowSpacing) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text("外接显示器")
                        .font(.headline)
                    Spacer(minLength: 8)
                    Text(model.selectedDisplayName)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                HStack(alignment: .center, spacing: 10) {
                    Text(model.statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Spacer(minLength: 8)

                    Picker("", selection: selectionBinding) {
                        ForEach(model.displayItems) { item in
                            Text(item.name).tag(Optional(item.id))
                        }
                    }
                    .labelsHidden()
                    .frame(width: DisplayControlPanelLayout.displayPickerWidth)
                    .disabled(model.displayItems.count <= 1)
                }

                VStack(spacing: MenuPanelLayout.controlRowSpacing) {
                    ForEach(
                        DisplayControlPanelLayout.rows(showsPreset: model.presetAvailable),
                        id: \.self
                    ) { row in
                        controlRow(row)
                    }
                }
            }
            .padding(DisplayControlPanelLayout.panelPadding)
        }
    }

    private var selectionBinding: Binding<CGDirectDisplayID?> {
        Binding(
            get: { model.selectedDisplayID },
            set: { newValue in
                if let newValue {
                    model.select(displayID: newValue)
                }
            }
        )
    }

    @ViewBuilder
    private func controlRow(_ row: DisplayControlPanelRow) -> some View {
        switch row {
        case .brightness:
            sliderRow(kind: .brightness)
        case .contrast:
            sliderRow(kind: .contrast)
        case .preset:
            presetRow
        case .volume:
            sliderRow(kind: .volume)
        }
    }

    private var presetRow: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: DisplayControlPanelLayout.rowSpacing) {
                Image(systemName: "paintpalette.fill")
                    .frame(width: DisplayControlPanelLayout.iconWidth)

                Text("色彩预设")
                    .frame(width: DisplayControlPanelLayout.labelWidth, alignment: .leading)

                Picker("", selection: presetSelectionBinding) {
                    ForEach(model.presetItems) { item in
                        Text(item.name)
                            .lineLimit(1)
                            .tag(Optional(item.rawValue))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(
                    minWidth: DisplayControlPanelLayout.minimumPresetControlWidth,
                    maxWidth: .infinity,
                    alignment: .trailing
                )
            }
            .accessibilityIdentifier("display-control-preset-row")

            if let errorText = model.presetErrorText {
                Text(errorText)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(
                        .leading,
                        DisplayControlPanelLayout.iconWidth
                            + DisplayControlPanelLayout.labelWidth
                            + DisplayControlPanelLayout.rowSpacing * 2
                    )
                    .accessibilityIdentifier("display-control-preset-error")
            }
        }
    }

    private func sliderRow(kind: DisplayControlKind) -> some View {
        guard let item = model.sliderItems.first(where: { $0.kind == kind }) else {
            return AnyView(EmptyView())
        }

        return AnyView(
            HStack(spacing: DisplayControlPanelLayout.rowSpacing) {
                Image(systemName: item.symbolName)
                    .frame(width: DisplayControlPanelLayout.iconWidth)
                    .foregroundStyle(item.isEnabled ? .primary : .secondary)

                Text(item.title)
                    .frame(width: DisplayControlPanelLayout.labelWidth, alignment: .leading)

                ScrollWheelSlider(value: binding(for: kind), in: 0...1, step: item.step)
                    .disabled(!item.isEnabled)

                Text(item.percentText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: kind == .volume ? 44 : 40, alignment: .trailing)

                if kind == .volume {
                    Button {
                        model.toggleMute()
                    } label: {
                        Image(systemName: model.selectedMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    }
                    .buttonStyle(.borderless)
                    .disabled(!model.muteAvailable)
                    .help("切换静音")
                }
            }
        )
    }

    private var presetSelectionBinding: Binding<UInt8?> {
        Binding(
            get: { model.selectedPresetRawValue },
            set: { rawValue in
                if let rawValue {
                    model.setColorPreset(rawValue: rawValue)
                }
            }
        )
    }

    private func binding(for kind: DisplayControlKind) -> Binding<Double> {
        Binding(
            get: {
                model.sliderItems.first(where: { $0.kind == kind })?.value ?? 0
            },
            set: { newValue in
                model.setValue(kind: kind, value: newValue)
            }
        )
    }
}
