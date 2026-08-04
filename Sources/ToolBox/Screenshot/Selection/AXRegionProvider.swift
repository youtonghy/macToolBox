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

struct AXLookupRequest: Equatable, Sendable {
    let point: CGPoint
    let targetPID: pid_t?
    let timeout: TimeInterval
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

private final class AXLookupJob: @unchecked Sendable {
    private let request: AXLookupRequest
    private let lookup: AXRegionProvider.Lookup
    private var continuation: CheckedContinuation<AXLookupResult, Never>?
    private let lock = NSLock()
    private var isCancelled = false

    init(
        request: AXLookupRequest,
        lookup: @escaping AXRegionProvider.Lookup,
        continuation: CheckedContinuation<AXLookupResult, Never>
    ) {
        self.request = request
        self.lookup = lookup
        self.continuation = continuation
    }

    func cancel() {
        lock.lock()
        isCancelled = true
        lock.unlock()
    }

    func run() {
        lock.lock()
        let cancelled = isCancelled
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: cancelled ? .failure(.unavailable) : lookup(request))
    }
}

@MainActor
final class AXRegionProvider {
    typealias Lookup = @Sendable (AXLookupRequest) -> AXLookupResult

    private let ownPID: pid_t
    private let primaryScreenTop: () -> CGFloat
    private let visibleScreenFrames: () -> [CGRect]
    private let currentGeneration: (() -> UInt64)?
    private let lookup: Lookup
    private let queue = DispatchQueue(label: "ToolBox.AXRegionProvider")
    private var pendingLookup: AXLookupJob?

    init(
        ownPID: pid_t = ProcessInfo.processInfo.processIdentifier,
        primaryScreenTop: @escaping () -> CGFloat = {
            NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.maxY
                ?? NSScreen.screens.first?.frame.maxY
                ?? 0
        },
        visibleScreenFrames: @escaping () -> [CGRect] = { NSScreen.screens.map(\.frame) },
        currentGeneration: (() -> UInt64)? = nil,
        lookup: Lookup? = nil
    ) {
        self.ownPID = ownPID
        self.primaryScreenTop = primaryScreenTop
        self.visibleScreenFrames = visibleScreenFrames
        self.currentGeneration = currentGeneration
        self.lookup = lookup ?? { request in
            AXRegionProvider.systemLookup(request: request)
        }
    }

    func regions(
        at point: CGPoint,
        generation: UInt64,
        targetWindow: SelectionCandidate? = nil
    ) async throws -> [SelectionCandidate] {
        let screenTop = primaryScreenTop()
        let screenFrames = visibleScreenFrames()
        let axPoint = CGPoint(x: point.x, y: screenTop - point.y)
        let request = AXLookupRequest(
            point: axPoint,
            targetPID: targetWindow?.ownerPID,
            timeout: 0.10
        )
        let result = await withCheckedContinuation { continuation in
            let job = AXLookupJob(request: request, lookup: lookup, continuation: continuation)
            pendingLookup?.cancel()
            pendingLookup = job
            queue.async { job.run() }
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

        var candidates = records.compactMap { record -> SelectionCandidate? in
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
            guard screenFrames.isEmpty || screenFrames.contains(where: { $0.intersects(rect) }) else {
                return nil
            }
            return SelectionCandidate(
                providerIdentity: "ax",
                source: .accessibility,
                ownerPID: record.ownerPID,
                windowID: targetWindow?.ownerPID == record.ownerPID ? targetWindow?.windowID : nil,
                displayID: displayID(containing: rect),
                topologyGeneration: generation,
                role: record.role,
                title: record.title,
                hierarchyIndex: record.hierarchyIndex,
                globalRect: rect
            )
        }

        if let targetWindow {
            candidates.removeAll { candidate in
                approximatelyEqual(candidate.globalRect, targetWindow.globalRect)
            }
            candidates.append(targetWindow)
        }
        return candidates
    }

    nonisolated private static func systemLookup(request: AXLookupRequest) -> AXLookupResult {
        guard AXIsProcessTrusted() else { return .failure(.permissionDenied) }
        let root = request.targetPID.map(AXUIElementCreateApplication) ?? AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(root, Float(request.timeout))
        var hit: AXUIElement?
        let hitError = AXUIElementCopyElementAtPosition(
            root,
            Float(request.point.x),
            Float(request.point.y),
            &hit
        )
        guard hitError == .success, var current = hit else {
            return .failure(hitError == .cannotComplete ? .timeout : .unavailable)
        }

        var records: [AXRegionRecord] = []
        for index in 0..<32 {
            AXUIElementSetMessagingTimeout(current, Float(request.timeout))
            let attributes = attributeSnapshot(current)
            var pid = request.targetPID ?? 0
            if request.targetPID == nil {
                _ = AXUIElementGetPid(current, &pid)
            }
            if let position = attributes.position, let size = attributes.size {
                records.append(AXRegionRecord(
                    ownerPID: pid,
                    role: attributes.role,
                    title: attributes.title,
                    position: position,
                    size: size,
                    hierarchyIndex: index
                ))
            }
            guard let parent = attributes.parent else { break }
            current = parent
        }
        return .success(records)
    }

    nonisolated private struct AttributeSnapshot {
        let position: CGPoint?
        let size: CGSize?
        let role: String?
        let title: String?
        let parent: AXUIElement?
    }

    nonisolated private static func attributeSnapshot(_ element: AXUIElement) -> AttributeSnapshot {
        let names = [
            kAXPositionAttribute,
            kAXSizeAttribute,
            kAXRoleAttribute,
            kAXTitleAttribute,
            kAXParentAttribute,
        ] as CFArray
        var values: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(element, names, [], &values) == .success,
              let attributes = values as? [Any],
              attributes.count == 5 else {
            return AttributeSnapshot(position: nil, size: nil, role: nil, title: nil, parent: nil)
        }
        return AttributeSnapshot(
            position: pointValue(attributes[0]),
            size: sizeValue(attributes[1]),
            role: attributes[2] as? String,
            title: attributes[3] as? String,
            parent: elementValue(attributes[4])
        )
    }

    nonisolated private static func pointValue(_ value: Any) -> CGPoint? {
        var point = CGPoint.zero
        let rawValue = value as CFTypeRef
        guard
              CFGetTypeID(rawValue) == AXValueGetTypeID(),
              let axValue = rawValue as! AXValue?,
              AXValueGetValue(axValue, .cgPoint, &point) else { return nil }
        return point
    }

    nonisolated private static func sizeValue(_ value: Any) -> CGSize? {
        var size = CGSize.zero
        let rawValue = value as CFTypeRef
        guard
              CFGetTypeID(rawValue) == AXValueGetTypeID(),
              let axValue = rawValue as! AXValue?,
              AXValueGetValue(axValue, .cgSize, &size) else { return nil }
        return size
    }

    nonisolated private static func elementValue(_ value: Any) -> AXUIElement? {
        let rawValue = value as CFTypeRef
        guard
              CFGetTypeID(rawValue) == AXUIElementGetTypeID() else { return nil }
        return (rawValue as! AXUIElement?)
    }

    private func displayID(containing rect: CGRect) -> CGDirectDisplayID {
        let point = CGPoint(x: rect.midX, y: rect.midY)
        let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main
        return (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }

    private func approximatelyEqual(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.minX - rhs.minX) <= 1
            && abs(lhs.minY - rhs.minY) <= 1
            && abs(lhs.width - rhs.width) <= 1
            && abs(lhs.height - rhs.height) <= 1
    }

    private func isFinite(_ point: CGPoint) -> Bool {
        point.x.isFinite && point.y.isFinite
    }

    private func isFinite(_ size: CGSize) -> Bool {
        size.width.isFinite && size.height.isFinite
    }
}
