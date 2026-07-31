import CoreGraphics
import Foundation

enum PaddleOCRTilePlannerError: Error, Equatable {
    case invalidConfiguration
}

struct PaddleOCRTilePlanner: Sendable {
    let maximumSide: Int
    let overlap: Int

    init(maximumSide: Int = 1_280, overlap: Int = 96) throws {
        guard maximumSide > 0, overlap >= 0, overlap < maximumSide else {
            throw PaddleOCRTilePlannerError.invalidConfiguration
        }
        self.maximumSide = maximumSide
        self.overlap = overlap
    }

    func tiles(for size: CGSize) -> [CGRect] {
        guard size.width.isFinite,
              size.height.isFinite,
              size.width > 0,
              size.height > 0
        else { return [] }
        let width = Int(ceil(size.width))
        let height = Int(ceil(size.height))
        let xOffsets = offsets(length: width)
        let yOffsets = offsets(length: height)
        return yOffsets.flatMap { y in
            xOffsets.map { x in
                CGRect(
                    x: x,
                    y: y,
                    width: min(maximumSide, width - x),
                    height: min(maximumSide, height - y)
                )
            }
        }
    }

    private func offsets(length: Int) -> [Int] {
        guard length > maximumSide else { return [0] }
        let stride = maximumSide - overlap
        var result = [0]
        while let current = result.last, current + maximumSide < length {
            let next = min(current + stride, length - maximumSide)
            guard next > current else { break }
            result.append(next)
        }
        return result
    }
}
