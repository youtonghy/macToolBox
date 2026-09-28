import AppKit
import SwiftUI

struct PopoverContent: View {
    @ObservedObject var state: FeatureState
    @ObservedObject var customization: MenuBarCustomizationModel
    @ObservedObject var hardware: HardwareMenuModel
    @ObservedObject var displayControl: DisplayControlMenuModel
    @ObservedObject var audioRouting: AudioRoutingService
    @ObservedObject var focusMode: FocusModeCoordinator
    @ObservedObject var wifiSignal: WiFiSignalModel
    @ObservedObject var networkLocation: NetworkLocationModel

    private var runtimeContext: MenuBarElementRuntimeContext {
        MenuBarElementRuntimeContext(
            cableItemCount: hardware.cableItems.count,
            audioRowCount: audioRouting.menuRows.count,
            isAudioLiteMode: audioRouting.isLiteMode,
            hasExternalDisplay: displayControl.hasExternalDisplay,
            showsColorPreset: displayControl.presetAvailable
        )
    }

    /// User-enabled elements in configured order, filtered by the current
    /// runtime availability signals.
    private var visibleElements: [MenuBarElementID] {
        MenuBarElementProjection.visibleElements(
            from: customization.entries,
            context: runtimeContext
        )
    }

    var body: some View {
        let elements = visibleElements

        return VStack(alignment: .leading, spacing: 0) {
            header

            ForEach(elements) { element in
                MenuBarElementSectionView(
                    element: element,
                    hardware: hardware,
                    displayControl: displayControl,
                    audioRouting: audioRouting,
                    focusMode: focusMode,
                    wifiSignal: wifiSignal,
                    networkLocation: networkLocation,
                    state: state,
                    isInteractive: true
                )
                .padding(.top, spacing(before: element, in: elements))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.clear)
    }

    private var header: some View {
        Text("ToolBox")
            .font(.system(size: 22, weight: .semibold))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 2)
            .frame(height: MenuPanelLayout.headerHeight, alignment: .center)
    }

    /// Vertical spacing between the header/previous element and this element.
    /// Mirrors `MenuPanelLayout.spacing(before:in:)` exactly: the compact
    /// quick-controls row keeps its outer spacing wherever it is placed,
    /// regular sections use the tighter content spacing.
    private func spacing(before element: MenuBarElementID, in elements: [MenuBarElementID]) -> CGFloat {
        guard let index = elements.firstIndex(of: element), index > 0 else {
            return MenuPanelLayout.outerSpacing
        }
        let previous = elements[index - 1]
        if element == .quickControls || previous == .quickControls {
            return MenuPanelLayout.outerSpacing
        }
        return MenuPanelLayout.contentSpacing
    }
}

struct CableListView: View {
    var items: [CableDisplayItem]

    var body: some View {
        let columns = Array(
            repeating: GridItem(.flexible(), spacing: MenuPanelLayout.cableGridSpacing, alignment: .top),
            count: HardwareMenuLayout.cableColumnCount(itemCount: items.count)
        )

        LazyVGrid(columns: columns, alignment: .leading, spacing: MenuPanelLayout.cableGridSpacing) {
            ForEach(items) { item in
                CableRowView(item: item)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

private struct CableRowView: View {
    var item: CableDisplayItem

    private var visibleLines: [String] {
        Array(item.lines.prefix(4))
    }

    private var accentColor: Color {
        switch item.cableType {
        case .active:
            return .purple
        case .opticallyIsolated:
            return .green
        case .passive, .unknown, .none:
            break
        }

        switch item.kind {
        case .magSafe, .power:
            return .orange
        case .usbC:
            return .blue
        case .thunderbolt:
            return .indigo
        case .display:
            return .teal
        case .unknown:
            return .gray
        }
    }

    private var symbolName: String {
        switch item.kind {
        case .magSafe, .power:
            return "bolt.fill"
        case .usbC:
            return "cable.connector"
        case .thunderbolt:
            return "bolt.horizontal.circle"
        case .display:
            return "display"
        case .unknown:
            return "questionmark.circle"
        }
    }

    private var badgeText: String? {
        switch item.cableType {
        case .active:
            return "主动线"
        case .passive:
            return "被动线"
        case .opticallyIsolated:
            return "光隔离"
        case .unknown, .none:
            break
        }

        switch item.kind {
        case .magSafe:
            return "MagSafe"
        case .power:
            return "供电"
        case .usbC:
            return "USB-C"
        case .thunderbolt:
            return "TB / USB4"
        case .display:
            return "显示"
        case .unknown:
            return nil
        }
    }

    private var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: symbolName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(accentColor)
                    .frame(width: 18, height: 18)
                    .background(accentColor.opacity(0.12), in: Circle())
                    .accessibilityHidden(true)

                Text(item.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 4)

                if let badgeText {
                    Text(badgeText)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(accentColor)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(accentColor.opacity(0.10), in: Capsule(style: .continuous))
                }
            }

            VStack(alignment: .leading, spacing: 1) {
                ForEach(visibleLines.indices, id: \.self) { index in
                    let line = visibleLines[index]
                    Text(line)
                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(
            maxWidth: .infinity,
            minHeight: MenuPanelLayout.cableRowHeight,
            maxHeight: MenuPanelLayout.cableRowHeight,
            alignment: .topLeading
        )
        .background(cardShape.fill(Color.primary.opacity(0.055)))
        .overlay(
            cardShape.strokeBorder(accentColor.opacity(0.28), lineWidth: 1)
        )
        .clipShape(cardShape)
        .accessibilityElement(children: .combine)
    }
}
