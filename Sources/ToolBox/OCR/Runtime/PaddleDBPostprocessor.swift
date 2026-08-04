import CoreGraphics
import Foundation

struct PaddleOCRDetection: Equatable, Sendable {
    let polygon: [CGPoint]
    let score: Float

    var bounds: CGRect {
        polygon.reduce(CGRect.null) { result, point in
            result.union(CGRect(origin: point, size: .zero))
        }
    }
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
            var componentPixels: [CGPoint] = []
            while cursor < queue.count {
                let index = queue[cursor]
                cursor += 1
                let x = index % width
                let y = index / width
                componentPixels.append(CGPoint(x: x, y: y))
                if x > 0 { append(x: x - 1, y: y, width: width, probabilities: probabilities, visited: &visited, queue: &queue) }
                if x + 1 < width { append(x: x + 1, y: y, width: width, probabilities: probabilities, visited: &visited, queue: &queue) }
                if y > 0 { append(x: x, y: y - 1, width: width, probabilities: probabilities, visited: &visited, queue: &queue) }
                if y + 1 < height { append(x: x, y: y + 1, width: width, probabilities: probabilities, visited: &visited, queue: &queue) }
            }

            guard componentPixels.count >= 4, detections.count < maxCandidates else { continue }

            let contourPoints = componentPixels.lazy
                .filter { isBoundaryPixel($0, probabilities: probabilities, width: width, height: height, threshold: threshold) }
                .flatMap { pixelCorners($0) }
            let contour = convexHull(Array(contourPoints))
            guard contour.count >= 3 else { continue }
            let score = boxScore(contour, probabilities: probabilities, width: width, height: height)
            guard score >= boxThreshold else { continue }
            let box = minimumAreaQuadrilateral(contour)
            let expanded = unclip(box, ratio: unclipRatio)
            let mapped = expanded.map {
                CGPoint(
                    x: $0.x * originalSize.width / CGFloat(width),
                    y: $0.y * originalSize.height / CGFloat(height)
                )
            }
            detections.append(PaddleOCRDetection(polygon: mapped, score: score))
        }

        return detections.sorted {
            let lhs = $0.bounds
            let rhs = $1.bounds
            let tolerance = max(lhs.height, rhs.height) * 0.5
            if abs(lhs.midY - rhs.midY) > tolerance { return lhs.minY < rhs.minY }
            return lhs.minX < rhs.minX
        }
    }

    private func append(
        x: Int,
        y: Int,
        width: Int,
        probabilities: [Float],
        visited: inout [Bool],
        queue: inout [Int]
    ) {
        let index = y * width + x
        guard !visited[index], probabilities[index] > threshold else { return }
        visited[index] = true
        queue.append(index)
    }
}

private func boxScore(
    _ polygon: [CGPoint],
    probabilities: [Float],
    width: Int,
    height: Int
) -> Float {
    let bounds = polygon.reduce(CGRect.null) {
        $0.union(CGRect(origin: $1, size: .zero))
    }
    let minimumX = max(0, Int(floor(bounds.minX)))
    let maximumX = min(width - 1, Int(ceil(bounds.maxX)))
    let minimumY = max(0, Int(floor(bounds.minY)))
    let maximumY = min(height - 1, Int(ceil(bounds.maxY)))
    var total: Float = 0
    var count = 0
    for y in minimumY...maximumY {
        for x in minimumX...maximumX {
            guard point(CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5), isInside: polygon) else { continue }
            total += probabilities[y * width + x]
            count += 1
        }
    }
    return count > 0 ? total / Float(count) : 0
}

private func point(_ point: CGPoint, isInside polygon: [CGPoint]) -> Bool {
    var orientation: CGFloat = 0
    for index in polygon.indices {
        let start = polygon[index]
        let end = polygon[(index + 1) % polygon.count]
        let value = cross(end - start, point - start)
        if abs(value) < 0.0001 { continue }
        if orientation == 0 { orientation = value }
        else if orientation * value < 0 { return false }
    }
    return true
}

private func pixelCorners(_ point: CGPoint) -> [CGPoint] {
    [
        point,
        CGPoint(x: point.x + 1, y: point.y),
        CGPoint(x: point.x + 1, y: point.y + 1),
        CGPoint(x: point.x, y: point.y + 1),
    ]
}

private func isBoundaryPixel(
    _ point: CGPoint,
    probabilities: [Float],
    width: Int,
    height: Int,
    threshold: Float
) -> Bool {
    let x = Int(point.x)
    let y = Int(point.y)
    let neighbors = [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)]
    return neighbors.contains { neighborX, neighborY in
        neighborX < 0 || neighborY < 0 || neighborX >= width || neighborY >= height
            || probabilities[neighborY * width + neighborX] <= threshold
    }
}

private func convexHull(_ points: [CGPoint]) -> [CGPoint] {
    let sorted = points.sorted { lhs, rhs in
        lhs.x == rhs.x ? lhs.y < rhs.y : lhs.x < rhs.x
    }
    guard sorted.count > 1 else { return sorted }
    var lower: [CGPoint] = []
    for point in sorted {
        while lower.count >= 2,
              cross(lower[lower.count - 1] - lower[lower.count - 2], point - lower[lower.count - 1]) <= 0 {
            lower.removeLast()
        }
        lower.append(point)
    }
    var upper: [CGPoint] = []
    for point in sorted.reversed() {
        while upper.count >= 2,
              cross(upper[upper.count - 1] - upper[upper.count - 2], point - upper[upper.count - 1]) <= 0 {
            upper.removeLast()
        }
        upper.append(point)
    }
    lower.removeLast()
    upper.removeLast()
    return lower + upper
}

private func minimumAreaQuadrilateral(_ points: [CGPoint]) -> [CGPoint] {
    guard points.count >= 3 else { return points }
    var best = points
    var bestArea = CGFloat.greatestFiniteMagnitude
    for index in points.indices {
        let next = points[(index + 1) % points.count]
        let edge = next - points[index]
        let angle = -atan2(edge.y, edge.x)
        let rotated = points.map { rotate($0, by: angle) }
        guard let minX = rotated.map(\.x).min(), let maxX = rotated.map(\.x).max(),
              let minY = rotated.map(\.y).min(), let maxY = rotated.map(\.y).max() else { continue }
        let area = (maxX - minX) * (maxY - minY)
        guard area < bestArea else { continue }
        bestArea = area
        let corners = [
            CGPoint(x: minX, y: minY), CGPoint(x: maxX, y: minY),
            CGPoint(x: maxX, y: maxY), CGPoint(x: minX, y: maxY),
        ]
        best = corners.map { rotate($0, by: -angle) }
    }
    return best
}

private func unclip(_ polygon: [CGPoint], ratio: Float) -> [CGPoint] {
    guard polygon.count == 4, ratio > 0 else { return polygon }
    let signedArea = polygonArea(polygon)
    let perimeter = polygon.indices.reduce(CGFloat.zero) { result, index in
        result + distance(polygon[index], polygon[(index + 1) % polygon.count])
    }
    guard abs(signedArea) > 0.001, perimeter > 0 else { return polygon }
    let offset = abs(signedArea) * CGFloat(ratio) / perimeter
    let direction: CGFloat = signedArea > 0 ? 1 : -1
    let shiftedEdges = polygon.indices.map { index -> (CGPoint, CGPoint) in
        let start = polygon[index]
        let end = polygon[(index + 1) % polygon.count]
        let edge = end - start
        let length = max(0.001, hypot(edge.x, edge.y))
        let normal = CGPoint(x: edge.y / length, y: -edge.x / length) * direction * offset
        return (start + normal, end + normal)
    }
    return polygon.indices.map { index in
        let previous = shiftedEdges[(index + polygon.count - 1) % polygon.count]
        let current = shiftedEdges[index]
        return lineIntersection(previous.0, previous.1, current.0, current.1) ?? current.0
    }
}

private func polygonArea(_ polygon: [CGPoint]) -> CGFloat {
    polygon.indices.reduce(CGFloat.zero) { result, index in
        let next = polygon[(index + 1) % polygon.count]
        return result + polygon[index].x * next.y - polygon[index].y * next.x
    } / 2
}

private func distance(_ lhs: CGPoint, _ rhs: CGPoint) -> CGFloat {
    hypot(lhs.x - rhs.x, lhs.y - rhs.y)
}

private func lineIntersection(
    _ firstStart: CGPoint,
    _ firstEnd: CGPoint,
    _ secondStart: CGPoint,
    _ secondEnd: CGPoint
) -> CGPoint? {
    let firstDirection = firstEnd - firstStart
    let secondDirection = secondEnd - secondStart
    let denominator = cross(firstDirection, secondDirection)
    guard abs(denominator) > 0.0001 else { return nil }
    let t = cross(secondStart - firstStart, secondDirection) / denominator
    return firstStart + firstDirection * t
}

private func cross(_ lhs: CGPoint, _ rhs: CGPoint) -> CGFloat {
    lhs.x * rhs.y - lhs.y * rhs.x
}

private func rotate(_ point: CGPoint, by angle: CGFloat) -> CGPoint {
    let cosine = cos(angle)
    let sine = sin(angle)
    return CGPoint(x: point.x * cosine - point.y * sine, y: point.x * sine + point.y * cosine)
}

private func + (lhs: CGPoint, rhs: CGPoint) -> CGPoint {
    CGPoint(x: lhs.x + rhs.x, y: lhs.y + rhs.y)
}

private func - (lhs: CGPoint, rhs: CGPoint) -> CGPoint {
    CGPoint(x: lhs.x - rhs.x, y: lhs.y - rhs.y)
}

private func * (lhs: CGPoint, rhs: CGFloat) -> CGPoint {
    CGPoint(x: lhs.x * rhs, y: lhs.y * rhs)
}

private func / (lhs: CGPoint, rhs: CGFloat) -> CGPoint {
    CGPoint(x: lhs.x / rhs, y: lhs.y / rhs)
}
