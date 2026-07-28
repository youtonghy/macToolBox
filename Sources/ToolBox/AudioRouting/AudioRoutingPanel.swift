import AppKit
import SwiftUI

struct AudioRoutingPanel: View {
    @ObservedObject var service: AudioRoutingService

    private let iconPointSize: CGFloat = 24

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            LazyVStack(spacing: 6) {
                ForEach(service.menuRows) { row in
                    audioRow(row)
                }
            }
            .padding(.trailing, 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func audioRow(_ row: AudioRoutingRow) -> some View {
        HStack(spacing: 10) {
            Button {
                service.setVolume(bundleID: row.bundleID, percent: 100)
            } label: {
                appIcon(for: row)
            }
            .buttonStyle(.plain)
            .disabled(row.volumePercent == 100)
            .help(iconHelp(for: row))
            .accessibilityLabel("\(row.name)，恢复 100%")
            .accessibilityHint(statusDescription(for: row.state))

            ScrollWheelSlider(
                value: Binding(
                    get: { Double(row.volumePercent) },
                    set: { service.setVolume(bundleID: row.bundleID, percent: Int($0.rounded())) }
                ),
                in: 0...300,
                step: 1
            )
            .controlSize(.small)
            .help("音量 \(row.volumePercent)%（0–300%）")

            Text("\(row.volumePercent)%")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .trailing)
                .accessibilityLabel("音量 \(row.volumePercent)%")
        }
        .padding(.horizontal, 2)
        .frame(minHeight: 30, maxHeight: 30)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(row.name)，音量 \(row.volumePercent)%，\(statusDescription(for: row.state))")
    }

    @ViewBuilder
    private func appIcon(for row: AudioRoutingRow) -> some View {
        let size = iconPointSize
        ZStack(alignment: .bottomTrailing) {
            Image(nsImage: AppIconResolver.icon(for: row.bundleID, pointSize: size))
                .resizable()
                .interpolation(.high)
                .antialiased(true)
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
                .opacity(row.isRunning || isActive(row.state) ? 1 : 0.55)
                .contentShape(Rectangle())

            if let badge = statusBadgeColor(for: row.state) {
                Circle()
                    .fill(badge)
                    .frame(width: 7, height: 7)
                    .overlay(
                        Circle()
                            .strokeBorder(Color(nsColor: .windowBackgroundColor).opacity(0.9), lineWidth: 1)
                    )
                    .offset(x: 1.5, y: 1.5)
                    .accessibilityHidden(true)
            }
        }
        .frame(width: size, height: size)
    }

    private func iconHelp(for row: AudioRoutingRow) -> String {
        let status = statusDescription(for: row.state)
        if row.volumePercent == 100 {
            return "\(row.name)\n\(status)"
        }
        return "\(row.name)\n点击恢复 100%\n\(status)"
    }

    private func isActive(_ state: AudioRouteState) -> Bool {
        if case .active = state { return true }
        return false
    }

    private func statusBadgeColor(for state: AudioRouteState) -> Color? {
        switch state {
        case .active: nil
        case .starting, .awaitingAudio: .orange
        case .degraded: .orange
        case .failed: .red
        case .waitingForProcess, .inactive: nil
        }
    }

    private func statusDescription(for state: AudioRouteState) -> String {
        switch state {
        case .inactive: "使用原生输出"
        case .waitingForProcess: "等待应用播放音频"
        case .starting: "正在启动音频路由"
        case let .awaitingAudio(message), let .degraded(message), let .failed(message): message
        case .active: "分应用音频路由已生效"
        }
    }
}

enum AppIconResolver {
    private static let renderedIcons = NSCache<NSString, NSImage>()

    /// Returns a retina-ready icon drawn at the requested point size from the
    /// highest-resolution representation available.
    static func icon(for bundleID: String, pointSize: CGFloat = 24) -> NSImage {
        let source = sourceIcon(for: bundleID)
        let scale = max(NSScreen.main?.backingScaleFactor ?? 2, 2)
        let cacheKey = NSString(
            format: "%@|%.4f|%.4f",
            bundleID,
            Double(pointSize),
            Double(scale)
        )
        if let cached = renderedIcons.object(forKey: cacheKey) {
            return cached
        }
        let pixelSize = max(1, Int((pointSize * scale).rounded()))
        let pixelSide = CGFloat(pixelSize)
        let targetRect = NSRect(x: 0, y: 0, width: pixelSide, height: pixelSide)

        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelSize,
            pixelsHigh: pixelSize,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        )
        guard let bitmap else {
            return source
        }

        NSGraphicsContext.saveGraphicsState()
        if let context = NSGraphicsContext(bitmapImageRep: bitmap) {
            NSGraphicsContext.current = context
            context.imageInterpolation = .high
            context.shouldAntialias = true
            NSColor.clear.setFill()
            targetRect.fill()

            if let rep = source.bestRepresentation(for: targetRect, context: context, hints: nil) {
                rep.draw(in: targetRect)
            } else {
                source.draw(in: targetRect, from: .zero, operation: .sourceOver, fraction: 1)
            }
        }
        NSGraphicsContext.restoreGraphicsState()

        let output = NSImage(size: NSSize(width: pointSize, height: pointSize))
        output.cacheMode = .never
        output.addRepresentation(bitmap)
        renderedIcons.setObject(output, forKey: cacheKey)
        return output
    }

    private static func sourceIcon(for bundleID: String) -> NSImage {
        if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID }),
           let icon = app.icon {
            return icon
        }

        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }

        if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID }),
           let url = app.bundleURL {
            return NSWorkspace.shared.icon(forFile: url.path)
        }

        return fallbackSymbol(pointSize: 24)
    }

    private static func fallbackSymbol(pointSize: CGFloat) -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: pointSize * 0.72, weight: .medium)
        if let symbol = NSImage(systemSymbolName: "app.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(config) {
            return symbol
        }
        return NSImage(size: NSSize(width: pointSize, height: pointSize))
    }
}
