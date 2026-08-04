import AppKit
import CoreGraphics
import ScreenCaptureKit

@MainActor
protocol ScreenCaptureProviding: AnyObject {
    func captureDisplays() async throws -> [DisplayCaptureFrame]
    func captureRegion(_ region: CGRect, displayID: CGDirectDisplayID) async throws -> CGImage
}

extension ScreenCaptureProviding {
    func captureRegion(_ region: CGRect, displayID: CGDirectDisplayID) async throws -> CGImage {
        let frames = try await captureDisplays()
        guard frames.contains(where: { $0.geometry.displayID == displayID }) else {
            throw ScreenshotCaptureError.missingDisplayFrame(displayID)
        }
        return try ScreenshotImageComposer.compose(selection: region, frames: frames)
    }
}

@MainActor
final class ScreenCaptureProvider: ScreenCaptureProviding {
    private let elapsedTimeHandler: (TimeInterval) -> Void

    init(elapsedTimeHandler: @escaping (TimeInterval) -> Void = { _ in }) {
        self.elapsedTimeHandler = elapsedTimeHandler
    }

    func captureDisplays() async throws -> [DisplayCaptureFrame] {
        let startedAt = ProcessInfo.processInfo.systemUptime
        defer { elapsedTimeHandler(ProcessInfo.processInfo.systemUptime - startedAt) }

        let initialContent = try await shareableContent()
        guard let ownApplication = initialContent.applications.first(where: {
            $0.processID == ProcessInfo.processInfo.processIdentifier
        }) else {
            throw ScreenshotCaptureError.ownApplicationUnavailable
        }

        let displays = initialContent.displays.sorted { $0.displayID < $1.displayID }
        let screenFrames: [CGDirectDisplayID: CGRect] = Dictionary(
            uniqueKeysWithValues: NSScreen.screens.compactMap { screen -> (CGDirectDisplayID, CGRect)? in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return nil
            }
            return (CGDirectDisplayID(number.uint32Value), screen.frame)
        })
        var captureRequests: [(SCDisplay, SCContentFilter, DisplayCaptureGeometry)] = []
        captureRequests.reserveCapacity(displays.count)
        for display in displays {
            guard let frame = screenFrames[display.displayID] else {
                throw ScreenshotCaptureError.displayGeometryUnavailable(display.displayID)
            }
            let filter = SCContentFilter(
                display: display,
                excludingApplications: [ownApplication],
                exceptingWindows: []
            )
            let geometry = DisplayCaptureGeometry(
                displayID: display.displayID,
                globalFramePoints: frame,
                pixelSize: Self.pixelSize(
                    for: frame.size,
                    pointPixelScale: CGFloat(filter.pointPixelScale)
                )
            )
            captureRequests.append((display, filter, geometry))
        }
        try FrozenCaptureBudget.validate(pixelSizes: captureRequests.map { $0.2.pixelSize })

        var frames: [DisplayCaptureFrame] = []
        frames.reserveCapacity(displays.count)
        for (display, filter, geometry) in captureRequests {
            try Task.checkCancellation()
            let configuration = SCStreamConfiguration()
            configuration.width = Int(geometry.pixelSize.width)
            configuration.height = Int(geometry.pixelSize.height)
            configuration.showsCursor = false
            configuration.scalesToFit = false

            do {
                let image = try await SCScreenshotManager.captureImage(
                    contentFilter: filter,
                    configuration: configuration
                )
                frames.append(DisplayCaptureFrame(geometry: geometry, image: image))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw ScreenshotCaptureError.displayCaptureFailed(display.displayID)
            }
        }

        let currentContent = try await shareableContent()
        guard topology(of: displays) == topology(of: currentContent.displays) else {
            throw ScreenshotCaptureError.displayTopologyChanged
        }
        return frames
    }

    static func pixelSize(for pointSize: CGSize, pointPixelScale: CGFloat) -> CGSize {
        CGSize(
            width: (pointSize.width * pointPixelScale).rounded(),
            height: (pointSize.height * pointPixelScale).rounded()
        )
    }

    private func shareableContent() async throws -> SCShareableContent {
        do {
            return try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw ScreenshotCaptureError.shareableContentUnavailable
        }
    }

    private func topology(of displays: [SCDisplay]) -> [DisplayTopology] {
        displays
            .map { DisplayTopology(id: $0.displayID, frame: $0.frame, width: $0.width, height: $0.height) }
            .sorted { $0.id < $1.id }
    }

    private struct DisplayTopology: Equatable {
        let id: CGDirectDisplayID
        let frame: CGRect
        let width: Int
        let height: Int
    }
}
