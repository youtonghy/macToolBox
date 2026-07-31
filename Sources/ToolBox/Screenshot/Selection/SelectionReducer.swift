import CoreGraphics

enum SelectionReducer {
    static func reduce(state: inout SelectionSessionState, action: SelectionAction) throws {
        switch action {
        case let .click(candidate, additive):
            guard isValid(candidate.globalRect) else { throw SelectionError.invalidRegion }
            let snapshot = SelectedRegionSnapshot(candidate: candidate)
            if additive {
                var regions = state.selectedRegions
                if let index = regions.firstIndex(where: { $0.candidateKey == candidate.candidateKey }) {
                    regions.remove(at: index)
                } else {
                    regions.append(snapshot)
                }
                state.replaceSelection(with: regions, manualRegion: nil)
            } else {
                state.replaceSelection(with: [snapshot], manualRegion: nil)
            }

        case .deleteLast:
            guard !state.selectedRegions.isEmpty else { return }
            state.replaceSelection(with: Array(state.selectedRegions.dropLast()), manualRegion: nil)

        case .undo:
            state.restoreUndo()

        case let .manualDrag(rect):
            guard isValid(rect) else { throw SelectionError.invalidRegion }
            state.replaceSelection(with: [], manualRegion: rect)

        case .confirm, .confirmScroll:
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
}
