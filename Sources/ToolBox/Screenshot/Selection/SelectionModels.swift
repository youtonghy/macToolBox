import CoreGraphics
import Foundation

enum SelectionSource: String, Equatable, Sendable {
    case accessibility
    case window
    case display
}

enum SelectionCaptureMode: Equatable, Sendable {
    case staticCapture
    case scrollCapture
}

struct SelectionCandidate: Equatable, Sendable {
    let providerIdentity: String
    let source: SelectionSource
    let ownerPID: pid_t?
    let windowID: CGWindowID?
    let displayID: CGDirectDisplayID
    let topologyGeneration: UInt64
    let role: String?
    let title: String?
    let hierarchyIndex: Int
    let globalRect: CGRect

    var candidateKey: String {
        let rectKey = [globalRect.minX, globalRect.minY, globalRect.width, globalRect.height]
            .map { String(Double(($0 * 4).rounded() / 4).bitPattern, radix: 16) }
            .joined(separator: ":")
        return [
            providerIdentity,
            ownerPID.map(String.init) ?? "-",
            windowID.map(String.init) ?? "-",
            role ?? "-",
            String(hierarchyIndex),
            rectKey,
        ].joined(separator: "|")
    }
}

struct SelectedRegionSnapshot: Equatable, Identifiable, Sendable {
    let id: UUID
    let candidateKey: String
    let source: SelectionSource
    let ownerPID: pid_t?
    let windowID: CGWindowID?
    let displayID: CGDirectDisplayID
    let topologyGeneration: UInt64
    let role: String?
    let title: String?
    let globalRect: CGRect

    init(candidate: SelectionCandidate, id: UUID = UUID()) {
        self.id = id
        candidateKey = candidate.candidateKey
        source = candidate.source
        ownerPID = candidate.ownerPID
        windowID = candidate.windowID
        displayID = candidate.displayID
        topologyGeneration = candidate.topologyGeneration
        role = candidate.role
        title = candidate.title
        globalRect = candidate.globalRect
    }
}

struct SelectionSessionState: Equatable, Sendable {
    var hoveredCandidate: SelectionCandidate?
    private(set) var captureMode: SelectionCaptureMode
    private(set) var selectedRegions: [SelectedRegionSnapshot]
    private(set) var manualRegion: CGRect?
    private(set) var captureBounds: CGRect?
    private var undoStack: [ValueSnapshot]

    static let empty = SelectionSessionState(
        hoveredCandidate: nil,
        captureMode: .staticCapture,
        selectedRegions: [],
        manualRegion: nil,
        captureBounds: nil,
        undoStack: []
    )

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.hoveredCandidate == rhs.hoveredCandidate
            && lhs.captureMode == rhs.captureMode
            && lhs.selectedRegions == rhs.selectedRegions
            && lhs.manualRegion == rhs.manualRegion
            && lhs.captureBounds == rhs.captureBounds
    }

    mutating func replaceSelection(with regions: [SelectedRegionSnapshot], manualRegion: CGRect?) {
        undoStack.append(currentValue)
        selectedRegions = regions
        self.manualRegion = manualRegion
        recomputeBounds()
    }

    mutating func setCaptureMode(_ mode: SelectionCaptureMode) {
        captureMode = mode
    }

    mutating func restoreUndo() {
        guard let value = undoStack.popLast() else { return }
        selectedRegions = value.selectedRegions
        manualRegion = value.manualRegion
        captureBounds = value.captureBounds
    }

    private var currentValue: ValueSnapshot {
        ValueSnapshot(
            selectedRegions: selectedRegions,
            manualRegion: manualRegion,
            captureBounds: captureBounds
        )
    }

    private mutating func recomputeBounds() {
        captureBounds = selectedRegions
            .map(\.globalRect)
            .reduce(nil) { partial, rect in partial.map { $0.union(rect) } ?? rect }
            ?? manualRegion
    }

    private struct ValueSnapshot: Equatable, Sendable {
        let selectedRegions: [SelectedRegionSnapshot]
        let manualRegion: CGRect?
        let captureBounds: CGRect?
    }
}

enum SelectionAction: Equatable, Sendable {
    case click(SelectionCandidate, additive: Bool)
    case cycleCandidate(Int)
    case setCaptureMode(SelectionCaptureMode)
    case deleteLast
    case undo
    case manualDrag(CGRect)
    case adjustRegion(CGRect)
    case confirm
}

enum SelectionError: Error, Equatable {
    case invalidRegion
    case emptySelection
    case disconnectedRegion
}
