import CoreGraphics
import Foundation

enum PaddleOCRImagePreprocessorError: Error, Equatable {
    case invalidImage
    case rasterizationFailed
}

struct PaddleOCRTensor: Equatable, Sendable {
    let data: [Float]
    let shape: [Int64]
}

struct PaddleOCRDetectionInput: Sendable {
    let tensor: PaddleOCRTensor
    let originalSize: CGSize
}

struct PaddleOCRRasterizedImage: Sendable {
    let pixels: [UInt8]
    let width: Int
    let height: Int
}

enum PaddleOCRImagePreprocessor {
    static func perspectiveCrop(
        image: CGImage,
        quadrilateral: [CGPoint]
    ) throws -> CGImage {
        try perspectiveCrop(source: rasterizedImage(image: image), quadrilateral: quadrilateral)
    }

    static func rasterizedImage(image: CGImage) throws -> PaddleOCRRasterizedImage {
        guard image.width > 0, image.height > 0 else {
            throw PaddleOCRImagePreprocessorError.invalidImage
        }
        return PaddleOCRRasterizedImage(
            pixels: try rasterize(image: image, width: image.width, height: image.height),
            width: image.width,
            height: image.height
        )
    }

    static func perspectiveCrop(
        source: PaddleOCRRasterizedImage,
        quadrilateral: [CGPoint]
    ) throws -> CGImage {
        guard source.width > 0, source.height > 0, quadrilateral.count == 4 else {
            throw PaddleOCRImagePreprocessorError.invalidImage
        }
        guard isValidQuadrilateral(quadrilateral) else {
            throw PaddleOCRImagePreprocessorError.invalidImage
        }
        let points = orderedQuadrilateral(quadrilateral)
        let width = max(1, Int(round(max(distance(points[0], points[1]), distance(points[3], points[2])))))
        let height = max(1, Int(round(max(distance(points[0], points[3]), distance(points[1], points[2])))))
        var output = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            let v = height == 1 ? 0 : CGFloat(y) / CGFloat(height - 1)
            for x in 0..<width {
                let u = width == 1 ? 0 : CGFloat(x) / CGFloat(width - 1)
                let top = points[0] * (1 - u) + points[1] * u
                let bottom = points[3] * (1 - u) + points[2] * u
                let sourcePoint = top * (1 - v) + bottom * v
                let targetIndex = (y * width + x) * 4
                for channel in 0..<3 {
                    output[targetIndex + channel] = bilinearSample(
                        source.pixels,
                        width: source.width,
                        height: source.height,
                        point: sourcePoint,
                        channel: channel
                    )
                }
                output[targetIndex + 3] = 255
            }
        }
        let data = Data(output) as CFData
        guard let provider = CGDataProvider(data: data),
              let result = CGImage(
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bitsPerPixel: 32,
                  bytesPerRow: width * 4,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: false,
                  intent: .defaultIntent
              ) else {
            throw PaddleOCRImagePreprocessorError.rasterizationFailed
        }
        return result
    }

    static func detectionTensor(
        image: CGImage,
        maximumSide: Int = 1280
    ) throws -> PaddleOCRDetectionInput {
        guard image.width > 0, image.height > 0 else {
            throw PaddleOCRImagePreprocessorError.invalidImage
        }
        let scale = min(1, CGFloat(maximumSide) / CGFloat(max(image.width, image.height)))
        let width = max(32, roundedToStride(Int((CGFloat(image.width) * scale).rounded()), 32))
        let height = max(32, roundedToStride(Int((CGFloat(image.height) * scale).rounded()), 32))
        let pixels = try rasterize(image: image, width: width, height: height)
        let means: [Float] = [0.485, 0.456, 0.406]
        let standardDeviations: [Float] = [0.229, 0.224, 0.225]
        let channelSize = width * height
        var data = [Float](repeating: 0, count: channelSize * 3)
        for pixel in 0..<channelSize {
            let source = pixel * 4
            let values = [pixels[source + 2], pixels[source + 1], pixels[source]]
            for channel in 0..<3 {
                data[channel * channelSize + pixel] =
                    (Float(values[channel]) / 255 - means[channel]) / standardDeviations[channel]
            }
        }
        return PaddleOCRDetectionInput(
            tensor: PaddleOCRTensor(data: data, shape: [1, 3, Int64(height), Int64(width)]),
            originalSize: CGSize(width: image.width, height: image.height)
        )
    }

    static func recognitionTensor(
        image: CGImage,
        imageHeight: Int,
        defaultWidth: Int,
        maximumWidth: Int = 3200
    ) throws -> PaddleOCRTensor {
        guard image.width > 0, image.height > 0, imageHeight > 0, defaultWidth > 0 else {
            throw PaddleOCRImagePreprocessorError.invalidImage
        }
        let contentWidth = min(
            maximumWidth,
            max(1, Int(ceil(CGFloat(imageHeight) * CGFloat(image.width) / CGFloat(image.height))))
        )
        let canvasWidth = min(maximumWidth, max(defaultWidth, contentWidth))
        let pixels = try rasterize(image: image, width: contentWidth, height: imageHeight)
        let targetChannelSize = imageHeight * canvasWidth
        var data = [Float](repeating: 0, count: 3 * targetChannelSize)
        for y in 0..<imageHeight {
            for x in 0..<contentWidth {
                let pixel = y * contentWidth + x
                let source = pixel * 4
                let target = y * canvasWidth + x
                data[target] = Float(pixels[source + 2]) / 127.5 - 1
                data[targetChannelSize + target] = Float(pixels[source + 1]) / 127.5 - 1
                data[2 * targetChannelSize + target] = Float(pixels[source]) / 127.5 - 1
            }
        }
        return PaddleOCRTensor(
            data: data,
            shape: [1, 3, Int64(imageHeight), Int64(canvasWidth)]
        )
    }

    private static func rasterize(image: CGImage, width: Int, height: Int) throws -> [UInt8] {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                  data: &pixels,
                  width: width,
                  height: height,
                  bitsPerComponent: 8,
                  bytesPerRow: width * 4,
                  space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              )
        else { throw PaddleOCRImagePreprocessorError.rasterizationFailed }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return pixels
    }

    private static func roundedToStride(_ value: Int, _ stride: Int) -> Int {
        max(stride, Int((Double(value) / Double(stride)).rounded()) * stride)
    }

    private static func orderedQuadrilateral(_ points: [CGPoint]) -> [CGPoint] {
        let center = points.reduce(CGPoint.zero, +) / CGFloat(points.count)
        let aroundCenter = points.sorted {
            atan2($0.y - center.y, $0.x - center.x) < atan2($1.y - center.y, $1.x - center.x)
        }
        let topLeftIndex = aroundCenter.indices.min {
            aroundCenter[$0].x + aroundCenter[$0].y < aroundCenter[$1].x + aroundCenter[$1].y
        }!
        var ordered = (0..<aroundCenter.count).map {
            aroundCenter[(topLeftIndex + $0) % aroundCenter.count]
        }
        if ordered[1].x < ordered[3].x {
            ordered = [ordered[0], ordered[3], ordered[2], ordered[1]]
        }
        return ordered
    }

    private static func distance(_ lhs: CGPoint, _ rhs: CGPoint) -> CGFloat {
        hypot(lhs.x - rhs.x, lhs.y - rhs.y)
    }

    private static func isValidQuadrilateral(_ points: [CGPoint]) -> Bool {
        guard points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return false }
        var orientation: CGFloat = 0
        for index in points.indices {
            let a = points[index]
            let b = points[(index + 1) % points.count]
            let c = points[(index + 2) % points.count]
            let cross = (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x)
            if abs(cross) < 0.001 { return false }
            if orientation == 0 { orientation = cross }
            else if orientation * cross < 0 { return false }
        }
        return abs(polygonArea(points)) > 0.001
    }

    private static func polygonArea(_ points: [CGPoint]) -> CGFloat {
        abs(points.enumerated().reduce(CGFloat.zero) { result, item in
            let next = points[(item.offset + 1) % points.count]
            return result + item.element.x * next.y - item.element.y * next.x
        }) / 2
    }

    private static func bilinearSample(
        _ pixels: [UInt8],
        width: Int,
        height: Int,
        point: CGPoint,
        channel: Int
    ) -> UInt8 {
        let x = min(CGFloat(width - 1), max(0, point.x))
        let y = min(CGFloat(height - 1), max(0, point.y))
        let x0 = Int(floor(x))
        let y0 = Int(floor(y))
        let x1 = min(width - 1, x0 + 1)
        let y1 = min(height - 1, y0 + 1)
        let xWeight = x - CGFloat(x0)
        let yWeight = y - CGFloat(y0)
        func value(_ sampleX: Int, _ sampleY: Int) -> CGFloat {
            CGFloat(pixels[(sampleY * width + sampleX) * 4 + channel])
        }
        let top = value(x0, y0) * (1 - xWeight) + value(x1, y0) * xWeight
        let bottom = value(x0, y1) * (1 - xWeight) + value(x1, y1) * xWeight
        return UInt8(clamping: Int(round(top * (1 - yWeight) + bottom * yWeight)))
    }
}

private func + (lhs: CGPoint, rhs: CGPoint) -> CGPoint {
    CGPoint(x: lhs.x + rhs.x, y: lhs.y + rhs.y)
}

private func * (lhs: CGPoint, rhs: CGFloat) -> CGPoint {
    CGPoint(x: lhs.x * rhs, y: lhs.y * rhs)
}

private func / (lhs: CGPoint, rhs: CGFloat) -> CGPoint {
    CGPoint(x: lhs.x / rhs, y: lhs.y / rhs)
}
