import CoreGraphics
import Foundation

struct ScreenshotEditorPreview: @unchecked Sendable {
    let baseImage: CGImage
    let scale: CGFloat
}

struct ScreenshotEditorPreviewBuilder: Sendable {
    let maximumPixelDimension: Int
    let maximumBandBytes: Int

    init(
        maximumPixelDimension: Int = 2_048,
        maximumBandBytes: Int = AnnotationRenderer.defaultMaximumBandBytes
    ) {
        self.maximumPixelDimension = max(64, maximumPixelDimension)
        self.maximumBandBytes = max(4, maximumBandBytes)
    }

    func makeBasePreview(document: ScreenshotDocument) throws -> ScreenshotEditorPreview {
        let dimensions = try ScreenshotPixelDimensions(size: document.baseImage.pixelSize)
        let scale = min(
            1,
            CGFloat(maximumPixelDimension) / CGFloat(max(dimensions.width, dimensions.height))
        )
        let width = max(1, Int((CGFloat(dimensions.width) * scale).rounded()))
        let height = max(1, Int((CGFloat(dimensions.height) * scale).rounded()))
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw AnnotationRenderError.contextCreationFailed
        }
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scale, y: -scale)
        context.interpolationQuality = .medium

        let sourceBandHeight = max(1, maximumBandBytes / dimensions.bytesPerRow)
        var y = 0
        while y < dimensions.height {
            try Task.checkCancellation()
            let bandHeight = min(sourceBandHeight, dimensions.height - y)
            let rect = CGRect(x: 0, y: y, width: dimensions.width, height: bandHeight)
            let band = try document.baseImage.copyPixels(in: rect)
            context.draw(band, in: rect)
            y += bandHeight
        }
        guard let image = context.makeImage() else {
            throw AnnotationRenderError.imageCreationFailed
        }
        return ScreenshotEditorPreview(baseImage: image, scale: scale)
    }

    func render(document: ScreenshotDocument, preview: ScreenshotEditorPreview) throws -> CGImage {
        let scaled = ScreenshotDocument(
            baseImage: CGImageScreenshotSource(image: preview.baseImage),
            annotations: document.annotations.map { scaledAnnotation($0, by: preview.scale) }
        )
        return try AnnotationRenderer(maximumBandBytes: maximumBandBytes).render(document: scaled)
    }

    private func scaledAnnotation(_ annotation: ScreenshotAnnotation, by scale: CGFloat) -> ScreenshotAnnotation {
        var result = annotation
        result.payload = scaledPayload(annotation.payload, by: scale)
        result.style.lineWidth *= scale
        result.transform = CGAffineTransform(
            a: annotation.transform.a,
            b: annotation.transform.b,
            c: annotation.transform.c,
            d: annotation.transform.d,
            tx: annotation.transform.tx * scale,
            ty: annotation.transform.ty * scale
        )
        return result
    }

    private func scaledPayload(
        _ payload: ScreenshotAnnotationPayload,
        by scale: CGFloat
    ) -> ScreenshotAnnotationPayload {
        func point(_ value: CGPoint) -> CGPoint {
            CGPoint(x: value.x * scale, y: value.y * scale)
        }
        func rect(_ value: CGRect) -> CGRect {
            CGRect(x: value.minX * scale, y: value.minY * scale, width: value.width * scale, height: value.height * scale)
        }
        switch payload {
        case let .rectangle(value): return .rectangle(rect(value))
        case let .ellipse(value): return .ellipse(rect(value))
        case let .line(start, end): return .line(start: point(start), end: point(end))
        case let .arrow(start, end, headLength):
            return .arrow(start: point(start), end: point(end), headLength: headLength * scale)
        case let .stroke(points, isHighlighter):
            return .stroke(points: points.map(point), isHighlighter: isHighlighter)
        case let .text(value):
            return .text(TextAnnotation(
                text: value.text,
                origin: point(value.origin),
                fontName: value.fontName,
                fontSize: value.fontSize * scale
            ))
        case let .mosaic(value, blockSize):
            return .mosaic(rect: rect(value), blockSize: max(1, Int((CGFloat(blockSize) * scale).rounded())))
        case let .numberedMarker(center, number):
            return .numberedMarker(center: point(center), number: number)
        }
    }
}
