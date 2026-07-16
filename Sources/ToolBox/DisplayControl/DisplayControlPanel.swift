import SwiftUI

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
                    .frame(width: 210)
                    .disabled(model.displayItems.count <= 1)
                }

                VStack(spacing: MenuPanelLayout.controlRowSpacing) {
                    sliderRow(kind: .brightness)
                    sliderRow(kind: .contrast)
                    sliderRow(kind: .volume)
                }
            }
            .padding(8)
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

    private func sliderRow(kind: DisplayControlKind) -> some View {
        guard let item = model.sliderItems.first(where: { $0.kind == kind }) else {
            return AnyView(EmptyView())
        }

        return AnyView(
            HStack(spacing: 8) {
                Image(systemName: item.symbolName)
                    .frame(width: 18)
                    .foregroundStyle(item.isEnabled ? .primary : .secondary)

                Text(item.title)
                    .frame(width: 66, alignment: .leading)

                Slider(value: binding(for: kind), in: 0...1, step: item.step)
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
