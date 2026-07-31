import AppKit
import ApplicationServices
import CoreGraphics

struct AXRegionRecord: Equatable, Sendable {
    let ownerPID: pid_t
    let role: String?
    let title: String?
    let position: CGPoint
    let size: CGSize
    let hierarchyIndex: Int
}

enum AXLookupFailure: Equatable, Sendable {
    case timeout
    case permissionDenied
    case unavailable
}

enum AXLookupResult: Equatable, Sendable {
    case success([AXRegionRecord])
    case failure(AXLookupFailure)
}

enum AXRegionError: Error, Equatable {
    case timeout
    case permissionDenied
    case unavailable
    case staleGeneration
}

@MainActor
final class AXRegionProvider {
    typealias Lookup = @Sendable (CGPoint, TimeInterval) -> AXLookupResult

    private let ownPID: pid_t
    private let primaryScreenTop: () -> CGFloat
    private let currentGeneration: (() -> UInt64)?
    private let lookup: Lookup
    private let queue = DispatchQueue(label: "ToolBox.AXRegionProvider")

    init(
        ownPID: pid_t = ProcessInfo.processInfo.processIdentifier,
        primaryScreenTop: @escaping () -> CGFloat = { NSScreen.main?.frame.maxY ?? 0 },
        currentGeneration: (() -> UInt64)? = nil,
        lookup: Lookup? = nil
    ) {
        self.ownPID = ownPID
        self.primaryScreenTop = primaryScreenTop
        self.currentGeneration = currentGeneration
        self.lookup = lookup ?? { point, timeout in
            AXRegionProvider.systemLookup(point: point, timeout: timeout)
        }
    }

    func regions(at point: CGPoint, generation: UInt64) async throws -> [SelectionCandidate] {
        let screenTop = primaryScreenTop()
        let axPoint = CGPoint(x: point.x, y: screenTop - point.y)
        let result = await withCheckedContinuation { continuation in
            queue.async { [lookup] in
                continuation.resume(returning: lookup(axPoint, 0.15))
            }
        }

        if let currentGeneration, generation != currentGeneration() {
            throw AXRegionError.staleGeneration
        }
        let records: [AXRegionRecord]
        switch result {
        case let .success(value): records = value
        case .failure(.timeout): throw AXRegionError.timeout
        case .failure(.permissionDenied): throw AXRegionError.permissionDenied
        case .failure(.unavailable): throw AXRegionError.unavailable
        }

        return records.compactMap { record in
            guard record.ownerPID != ownPID,
                  isFinite(record.position),
                  isFinite(record.size),
                  record.size.width > 0,
                  record.size.height > 0 else {
                return nil
            }
            let rect = CGRect(
                x: record.position.x,
                y: screenTop - record.position.y - record.size.height,
                width: record.size.width,
                height: record.size.height
            )
            return SelectionCandidate(
                providerIdentity: "ax",
                source: .accessibility,
                ownerPID: record.ownerPID,
                windowID: windowID(ownerPID: record.ownerPID, axRect: CGRect(origin: record.position, size: record.size)),
                displayID: displayID(containing: rect),
                topologyGeneration: generation,
                role: record.role,
                title: record.title,
                hierarchyIndex: record.hierarchyIndex,
                globalRect: rect
            )
        }
    }

    nonisolated private static func systemLookup(point: CGPoint, timeout: TimeInterval) -> AXLookupResult {
        guard AXIsProcessTrusted() else { return .failure(.permissionDenied) }
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, Float(timeout))
        var hit: AXUIElement?
        let hitError = AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &hit)
        guard hitError == .success, var current = hit else {
            return .failure(hitError == .cannotComplete ? .timeout : .unavailable)
        }

        var records: [AXRegionRecord] = []
        for index in 0..<16 {
            AXUIElementSetMessagingTimeout(current, Float(timeout))
            var pid: pid_t = 0
            guard AXUIElementGetPid(current, &pid) == .success else { break }
            if let position = pointAttribute(current, key: kAXPositionAttribute),
               let size = sizeAttribute(current, key: kAXSizeAttribute) {
                records.append(AXRegionRecord(
                    ownerPID: pid,
                    role: stringAttribute(current, key: kAXRoleAttribute),
                    title: stringAttribute(current, key: kAXTitleAttribute),
                    position: position,
                    size: size,
                    hierarchyIndex: index
                ))
            }
            guard let parent = elementAttribute(current, key: kAXParentAttribute) else { break }
            current = parent
        }
        return .success(records)
    }

    nonisolated private static func stringAttribute(_ element: AXUIElement, key: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success else { return nil }
        return value as? String
    }

    nonisolated private static func pointAttribute(_ element: AXUIElement, key: String) -> CGPoint? {
        var value: CFTypeRef?
        var point = CGPoint.zero
        guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success,
              let rawValue = value,
              CFGetTypeID(rawValue) == AXValueGetTypeID(),
              let axValue = rawValue as! AXValue?,
              AXValueGetValue(axValue, .cgPoint, &point) else { return nil }
        return point
    }

    nonisolated private static func sizeAttribute(_ element: AXUIElement, key: String) -> CGSize? {
        var value: CFTypeRef?
        var size = CGSize.zero
        guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success,
              let rawValue = value,
              CFGetTypeID(rawValue) == AXValueGetTypeID(),
              let axValue = rawValue as! AXValue?,
              AXValueGetValue(axValue, .cgSize, &size) else { return nil }
        return size
    }

    nonisolated private static func elementAttribute(_ element: AXUIElement, key: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success,
              let rawValue = value,
              CFGetTypeID(rawValue) == AXUIElementGetTypeID() else { return nil }
        return (rawValue as! AXUIElement?)
    }

    private func displayID(containing rect: CGRect) -> CGDirectDisplayID {
        let point = CGPoint(x: rect.midX, y: rect.midY)
        let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main
        return (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    private func windowID(ownerPID: pid_t, axRect: CGRect) -> CGWindowID? {
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[CFString: Any]] else { return nil }
        return windows.first { window in
            guard (window[kCGWindowOwnerPID] as? NSNumber)?.int32Value == ownerPID,
                  let boundsDictionary = window[kCGWindowBounds] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary) else { return false }
            return bounds.intersects(axRect)
        }.flatMap { ($0[kCGWindowNumber] as? NSNumber)?.uint32Value }
    }

    private func isFinite(_ point: CGPoint) -> Bool {
        point.x.isFinite && point.y.isFinite
    }

    private func isFinite(_ size: CGSize) -> Bool {
        size.width.isFinite && size.height.isFinite
    }
}
