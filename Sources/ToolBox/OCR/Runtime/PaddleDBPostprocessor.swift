import CoreGraphics
import Foundation

struct PaddleOCRDetection: Equatable, Sendable {
    let bounds: CGRect
    let score: Float
}

struct PaddleDBPostprocessor: Sendable {
    let threshold: Float
    let boxThreshold: Float
    let maxCandidates: Int
    let unclipRatio: Float

    func process(
        probabilities: [Float],
        width: Int,
        height: Int,
        originalSize: CGSize
    ) -> [PaddleOCRDetection] {
        guard width > 0, height > 0, probabilities.count >= width * height else { return [] }
        var visited = [Bool](repeating: false, count: width * height)
        var detections: [PaddleOCRDetection] = []
        detections.reserveCapacity(min(maxCandidates, 128))

        for seed in 0..<(width * height) {
            guard !visited[seed], probabilities[seed] > threshold else { continue }
            var queue = [seed]
            visited[seed] = true
            var cursor = 0
            var minimumX = seed % width
            var maximumX = minimumX
            var minimumY = seed / width
            var maximumY = minimumY
            var score: Float = 0
            var count = 0
            while cursor < queue.count {
                let index = queue[cursor]
                cursor += 1
                let x = index % width
                let y = index / width
                minimumX = min(minimumX, x)
                maximumX = max(maximumX, x)
                minimumY = min(minimumY, y)
                maximumY = max(maximumY, y)
                score += probabilities[index]
                count += 1
                for neighbor in Self.neighbors(x: x, y: y, width: width, height: height) {
                    guard !visited[neighbor], probabilities[neighbor] > threshold else { continue }
                    visited[neighbor] = true
                    queue.append(neighbor)
                }
            }
            let average = score / Float(max(1, count))
            let componentWidth = maximumX - minimumX + 1
            let componentHeight = maximumY - minimumY + 1
            guard average >= boxThreshold,
                  componentWidth >= 2,
                  componentHeight >= 2,
                  detections.count < maxCandidates
            else { continue }
            let base = CGRect(
                x: CGFloat(minimumX),
                y: CGFloat(minimumY),
                width: CGFloat(componentWidth),
                height: CGFloat(componentHeight)
            )
            let horizontalExpansion = base.width * CGFloat(max(0, unclipRatio - 1)) / 2
            let verticalExpansion = base.height * CGFloat(max(0, unclipRatio - 1)) / 2
            let expanded = base.insetBy(dx: -horizontalExpansion, dy: -verticalExpansion)
                .intersection(CGRect(x: 0, y: 0, width: width, height: height))
            let mapped = CGRect(
                x: expanded.minX * originalSize.width / CGFloat(width),
                y: expanded.minY * originalSize.height / CGFloat(height),
                width: expanded.width * originalSize.width / CGFloat(width),
                height: expanded.height * originalSize.height / CGFloat(height)
            )
            detections.append(PaddleOCRDetection(bounds: mapped, score: average))
        }
        return detections.sorted {
            let tolerance = max($0.bounds.height, $1.bounds.height) * 0.5
            if abs($0.bounds.midY - $1.bounds.midY) > tolerance {
                return $0.bounds.minY < $1.bounds.minY
            }
            return $0.bounds.minX < $1.bounds.minX
        }
    }

    private static func neighbors(x: Int, y: Int, width: Int, height: Int) -> [Int] {
        var result: [Int] = []
        result.reserveCapacity(4)
        if x > 0 { result.append(y * width + x - 1) }
        if x + 1 < width { result.append(y * width + x + 1) }
        if y > 0 { result.append((y - 1) * width + x) }
        if y + 1 < height { result.append((y + 1) * width + x) }
        return result
    }
}
