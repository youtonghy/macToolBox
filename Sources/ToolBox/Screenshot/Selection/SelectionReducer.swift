import CoreGraphics

enum SelectionReducer {
    static func reduce(state: inout SelectionSessionState, action: SelectionAction) throws {
        switch action {
        case .cycleCandidate:
            return

        case let .click(candidate, additive):
            guard isValid(candidate.globalRect) else { throw SelectionError.invalidRegion }
            let snapshot = SelectedRegionSnapshot(candidate: candidate)
            if additive {
                var regions = state.selectedRegions
                if let index = regions.firstIndex(where: { $0.candidateKey == candidate.candidateKey }) {
                    regions.remove(at: index)
                    guard isConnected(regions) else { throw SelectionError.disconnectedRegion }
                } else {
                    guard regions.isEmpty || regions.contains(where: { touches($0.globalRect, candidate.globalRect) }) else {
                        throw SelectionError.disconnectedRegion
                    }
                    regions.append(snapshot)
                }
                state.replaceSelection(with: regions, manualRegion: nil)
            } else {
                state.replaceSelection(with: [snapshot], manualRegion: nil)
            }

        case let .setCaptureMode(mode):
            state.setCaptureMode(mode)

        case .deleteLast:
            guard !state.selectedRegions.isEmpty else { return }
            state.replaceSelection(with: Array(state.selectedRegions.dropLast()), manualRegion: nil)

        case .undo:
            state.restoreUndo()

        case let .manualDrag(rect):
            guard isValid(rect) else { throw SelectionError.invalidRegion }
            state.replaceSelection(with: [], manualRegion: rect)

        case let .adjustRegion(rect):
            guard isValid(rect) else { throw SelectionError.invalidRegion }
            state.replaceSelection(with: [], manualRegion: rect)

        case .confirm:
            guard state.captureBounds != nil else { throw SelectionError.emptySelection }
        }
    }

    private static func isValid(_ rect: CGRect) -> Bool {
        rect.origin.x.isFinite
            && rect.origin.y.isFinite
            && rect.width.isFinite
            && rect.height.isFinite
            && rect.width > 0
            && rect.height > 0
    }

    private static func isConnected(_ regions: [SelectedRegionSnapshot]) -> Bool {
        guard let first = regions.indices.first else { return true }
        var visited: Set<Int> = [first]
        var pending = [first]
        while let index = pending.popLast() {
            for candidateIndex in regions.indices where !visited.contains(candidateIndex) {
                guard touches(regions[index].globalRect, regions[candidateIndex].globalRect) else { continue }
                visited.insert(candidateIndex)
                pending.append(candidateIndex)
            }
        }
        return visited.count == regions.count
    }

    private static func touches(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        lhs.minX <= rhs.maxX
            && rhs.minX <= lhs.maxX
            && lhs.minY <= rhs.maxY
            && rhs.minY <= lhs.maxY
    }
}
