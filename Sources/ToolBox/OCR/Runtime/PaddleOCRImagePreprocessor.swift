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

enum PaddleOCRImagePreprocessor {
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
}
