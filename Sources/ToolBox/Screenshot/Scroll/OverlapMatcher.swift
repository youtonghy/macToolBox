import Foundation

struct OverlapMatcher {
    private let configuration: ScrollMatchingConfiguration

    init(configuration: ScrollMatchingConfiguration = ScrollMatchingConfiguration()) {
        self.configuration = configuration
    }

    func match(
        previous: LumaFrame,
        current: LumaFrame,
        mask: StableContentMask = .empty
    ) throws -> OverlapMatch {
        guard previous.width == current.width, previous.height == current.height else {
            throw ScrollCaptureError.frameDimensionsChanged
        }
        let noMovementError = try error(
            first: previous,
            second: current,
            firstStartRow: 0,
            secondStartRow: 0,
            rowCount: previous.height,
            mask: .empty
        )
        if noMovementError <= 0.001 {
            return OverlapMatch(
                classification: .noMovement,
                overlapRowCount: previous.height,
                newRowCount: 0,
                confidence: confidence(best: noMovementError, second: configuration.maximumNormalizedError),
                normalizedError: noMovementError
            )
        }
        guard texture(of: previous, mask: mask) >= configuration.minimumTexture else {
            return lowConfidence()
        }

        let maximumOffset = min(
            configuration.maximumOffsetRows,
            previous.height - configuration.minimumOverlapRows
        )
        guard maximumOffset >= 1 else { throw ScrollCaptureError.insufficientComparableContent }

        let forward = try candidates(
            previous: previous,
            current: current,
            maximumOffset: maximumOffset,
            direction: .forward,
            mask: mask
        )
        let reverse = try candidates(
            previous: previous,
            current: current,
            maximumOffset: maximumOffset,
            direction: .reverse,
            mask: mask
        )
        guard let bestForward = forward.first, let bestReverse = reverse.first else {
            throw ScrollCaptureError.insufficientComparableContent
        }

        let chosenDirection: OverlapClassification
        let chosen: Candidate
        let candidatesForDirection: [Candidate]
        if bestForward.error <= bestReverse.error {
            chosenDirection = .forward
            chosen = bestForward
            candidatesForDirection = forward
        } else {
            chosenDirection = .reverse
            chosen = bestReverse
            candidatesForDirection = reverse
        }
        let secondError = candidatesForDirection.dropFirst().first?.error ?? 1
        let margin = secondError - chosen.error
        guard chosen.error <= configuration.maximumNormalizedError,
              margin >= configuration.minimumConfidenceMargin
        else {
            return lowConfidence(error: chosen.error)
        }

        let overlap = previous.height - chosen.offset
        return OverlapMatch(
            classification: chosenDirection,
            overlapRowCount: overlap,
            newRowCount: chosenDirection == .forward ? chosen.offset : 0,
            confidence: confidence(best: chosen.error, second: secondError),
            normalizedError: chosen.error
        )
    }

    private func candidates(
        previous: LumaFrame,
        current: LumaFrame,
        maximumOffset: Int,
        direction: Direction,
        mask: StableContentMask
    ) throws -> [Candidate] {
        try (1...maximumOffset).map { offset in
            let errorValue: Double
            switch direction {
            case .forward:
                errorValue = try error(
                    first: previous,
                    second: current,
                    firstStartRow: offset,
                    secondStartRow: 0,
                    rowCount: previous.height - offset,
                    mask: mask
                )
            case .reverse:
                errorValue = try error(
                    first: previous,
                    second: current,
                    firstStartRow: 0,
                    secondStartRow: offset,
                    rowCount: previous.height - offset,
                    mask: mask
                )
            }
            return Candidate(offset: offset, error: errorValue)
        }.sorted {
            if $0.error == $1.error { return $0.offset < $1.offset }
            return $0.error < $1.error
        }
    }

    private func error(
        first: LumaFrame,
        second: LumaFrame,
        firstStartRow: Int,
        secondStartRow: Int,
        rowCount: Int,
        mask: StableContentMask
    ) throws -> Double {
        var differences: [Int] = []
        differences.reserveCapacity(rowCount * first.width)
        for relativeY in 0..<rowCount {
            let firstY = firstStartRow + relativeY
            let secondY = secondStartRow + relativeY
            guard mask.includes(row: firstY), mask.includes(row: secondY) else { continue }
            for x in 0..<first.width {
                differences.append(abs(Int(first[x, firstY]) - Int(second[x, secondY])))
            }
        }
        guard differences.count >= first.width * configuration.minimumOverlapRows / 2 else {
            throw ScrollCaptureError.insufficientComparableContent
        }
        differences.sort()
        let dropCount = Int(Double(differences.count) * configuration.outlierFraction)
        let kept = differences.prefix(max(1, differences.count - dropCount))
        return Double(kept.reduce(0, +)) / Double(kept.count) / 255
    }

    private func texture(of frame: LumaFrame, mask: StableContentMask) -> Double {
        var total = 0
        var count = 0
        for y in 0..<frame.height where mask.includes(row: y) {
            for x in 1..<frame.width {
                total += abs(Int(frame[x, y]) - Int(frame[x - 1, y]))
                count += 1
            }
            if y > 0, mask.includes(row: y - 1) {
                for x in 0..<frame.width {
                    total += abs(Int(frame[x, y]) - Int(frame[x, y - 1]))
                    count += 1
                }
            }
        }
        guard count > 0 else { return 0 }
        return Double(total) / Double(count) / 255
    }

    private func confidence(best: Double, second: Double) -> Double {
        let absolute = max(0, 1 - best / max(configuration.maximumNormalizedError, .ulpOfOne))
        let separation = min(1, max(0, second - best) / 0.05)
        return absolute * separation
    }

    private func lowConfidence(error: Double = 1) -> OverlapMatch {
        OverlapMatch(
            classification: .lowConfidence,
            overlapRowCount: 0,
            newRowCount: 0,
            confidence: 0,
            normalizedError: error
        )
    }

    private enum Direction { case forward, reverse }
    private struct Candidate {
        let offset: Int
        let error: Double
    }
}
