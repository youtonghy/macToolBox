import CoreGraphics
import CoreText
import Foundation

enum AnnotationRenderError: Error, Equatable {
    case invalidDimensions
    case invalidBand
    case bandTooLarge
    case contextCreationFailed
    case imageCreationFailed
    case exportFailed
    case fileMappingFailed
}

struct AnnotationRenderer {
    static let defaultMaximumBandBytes = 16 * 1_024 * 1_024

    let maximumBandBytes: Int

    init(maximumBandBytes: Int = defaultMaximumBandBytes) {
        self.maximumBandBytes = max(4, maximumBandBytes)
    }

    func render(document: ScreenshotDocument) throws -> CGImage {
        let bounds = try documentBounds(document)
        return try renderBand(document: document, pixelRect: bounds)
    }

    func renderBand(document: ScreenshotDocument, pixelRect: CGRect) throws -> CGImage {
        let documentBounds = try documentBounds(document)
        guard pixelRect.isIntegral,
              pixelRect.width > 0,
              pixelRect.height > 0,
              documentBounds.contains(pixelRect)
        else {
            throw AnnotationRenderError.invalidBand
        }

        let width = Int(pixelRect.width)
        let height = Int(pixelRect.height)
        guard let byteCount = multipliedWithoutOverflow(width, height, 4),
              byteCount <= maximumBandBytes
        else {
            throw AnnotationRenderError.bandTooLarge
        }
        guard let context = makeContext(width: width, height: height) else {
            throw AnnotationRenderError.contextCreationFailed
        }

        let base = try document.baseImage.copyPixels(in: pixelRect)
        configureTopLeftCoordinates(context, height: height, pixelRect: pixelRect)
        context.interpolationQuality = .high
        context.draw(base, in: pixelRect)

        for annotation in document.annotations {
            try draw(annotation, source: document.baseImage, visiblePixelRect: pixelRect, in: context)
        }

        guard let image = context.makeImage() else {
            throw AnnotationRenderError.imageCreationFailed
        }
        return image
    }

    func bandHeight(forWidth width: Int) throws -> Int {
        guard width > 0,
              let bytesPerRow = multipliedWithoutOverflow(width, 4),
              bytesPerRow <= maximumBandBytes
        else {
            throw AnnotationRenderError.bandTooLarge
        }
        return max(1, maximumBandBytes / bytesPerRow)
    }

    private func documentBounds(_ document: ScreenshotDocument) throws -> CGRect {
        let size = document.baseImage.pixelSize
        guard size.width.isFinite,
              size.height.isFinite,
              size.width > 0,
              size.height > 0,
              size.width.rounded(.towardZero) == size.width,
              size.height.rounded(.towardZero) == size.height,
              size.width <= CGFloat(Int.max),
              size.height <= CGFloat(Int.max)
        else {
            throw AnnotationRenderError.invalidDimensions
        }
        return CGRect(origin: .zero, size: size)
    }

    private func configureTopLeftCoordinates(_ context: CGContext, height: Int, pixelRect: CGRect) {
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.translateBy(x: -pixelRect.minX, y: -pixelRect.minY)
    }

    private func draw(
        _ annotation: ScreenshotAnnotation,
        source: ScreenshotImageSource,
        visiblePixelRect: CGRect,
        in context: CGContext
    ) throws {
        context.saveGState()
        defer { context.restoreGState() }
        context.concatenate(annotation.transform)
        configure(annotation.style, in: context)

        switch annotation.payload {
        case let .rectangle(rect):
            context.stroke(rect)
        case let .ellipse(rect):
            context.strokeEllipse(in: rect)
        case let .line(start, end):
            drawLine(from: start, to: end, in: context)
        case let .arrow(start, end, headLength):
            drawArrow(from: start, to: end, headLength: headLength, in: context)
        case let .stroke(points, isHighlighter):
            if isHighlighter {
                context.setAlpha(min(annotation.style.opacity, 0.35))
            }
            drawStroke(points, in: context)
        case let .text(text):
            drawText(text, style: annotation.style, in: context)
        case let .mosaic(rect, blockSize):
            try drawMosaic(
                rect: rect,
                blockSize: blockSize,
                source: source,
                visiblePixelRect: visiblePixelRect.applying(annotation.transform.inverted()),
                in: context
            )
        case let .numberedMarker(center, number):
            drawMarker(center: center, number: number, style: annotation.style, in: context)
        }
    }

    private func configure(_ style: AnnotationStyle, in context: CGContext) {
        let color = CGColor(
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
            components: [style.color.red, style.color.green, style.color.blue, style.color.alpha]
        )!
        context.setStrokeColor(color)
        context.setFillColor(color)
        context.setLineWidth(style.lineWidth)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.setAlpha(style.opacity)
    }

    private func drawLine(from start: CGPoint, to end: CGPoint, in context: CGContext) {
        context.beginPath()
        context.move(to: start)
        context.addLine(to: end)
        context.strokePath()
    }

    private func drawArrow(
        from start: CGPoint,
        to end: CGPoint,
        headLength: CGFloat,
        in context: CGContext
    ) {
        drawLine(from: start, to: end, in: context)
        let angle = atan2(end.y - start.y, end.x - start.x)
        let spread = CGFloat.pi / 6
        let first = CGPoint(
            x: end.x - headLength * cos(angle - spread),
            y: end.y - headLength * sin(angle - spread)
        )
        let second = CGPoint(
            x: end.x - headLength * cos(angle + spread),
            y: end.y - headLength * sin(angle + spread)
        )
        context.beginPath()
        context.move(to: first)
        context.addLine(to: end)
        context.addLine(to: second)
        context.strokePath()
    }

    private func drawStroke(_ points: [CGPoint], in context: CGContext) {
        guard let first = points.first else { return }
        context.beginPath()
        context.move(to: first)
        for point in points.dropFirst() {
            context.addLine(to: point)
        }
        if points.count == 1 {
            context.addLine(to: CGPoint(x: first.x + 0.01, y: first.y))
        }
        context.strokePath()
    }

    private func drawText(_ text: TextAnnotation, style: AnnotationStyle, in context: CGContext) {
        let font = CTFontCreateWithName(text.fontName as CFString, text.fontSize, nil)
        let color = CGColor(
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
            components: [style.color.red, style.color.green, style.color.blue, style.color.alpha]
        )!
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(
                string: text.text,
                attributes: [
                    NSAttributedString.Key(kCTFontAttributeName as String): font,
                    NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
                ]
            )
        )
        context.saveGState()
        context.translateBy(x: text.origin.x, y: text.origin.y + text.fontSize)
        context.scaleBy(x: 1, y: -1)
        context.textPosition = .zero
        context.setAlpha(style.opacity)
        CTLineDraw(line, context)
        context.restoreGState()
    }

    private func drawMosaic(
        rect: CGRect,
        blockSize: Int,
        source: ScreenshotImageSource,
        visiblePixelRect: CGRect,
        in context: CGContext
    ) throws {
        context.saveGState()
        defer { context.restoreGState() }
        context.clip(to: rect)
        context.interpolationQuality = .none
        let step = CGFloat(blockSize)
        let visible = rect.intersection(visiblePixelRect)
        guard !visible.isNull, !visible.isEmpty else { return }
        let firstColumn = floor((visible.minX - rect.minX) / step)
        let firstRow = floor((visible.minY - rect.minY) / step)
        var y = rect.minY + firstRow * step
        while y < visible.maxY {
            var x = rect.minX + firstColumn * step
            while x < visible.maxX {
                let block = CGRect(
                    x: x,
                    y: y,
                    width: min(step, rect.maxX - x),
                    height: min(step, rect.maxY - y)
                )
                let sampleX = min(source.pixelSize.width - 1, max(0, floor(block.midX)))
                let sampleY = min(source.pixelSize.height - 1, max(0, floor(block.midY)))
                let sample = try source.copyPixels(in: CGRect(x: sampleX, y: sampleY, width: 1, height: 1))
                context.draw(sample, in: block)
                x += step
            }
            y += step
        }
    }

    private func drawMarker(
        center: CGPoint,
        number: Int,
        style: AnnotationStyle,
        in context: CGContext
    ) {
        let radius = max(10, style.lineWidth * 3)
        let circle = CGRect(
            x: center.x - radius,
            y: center.y - radius,
            width: radius * 2,
            height: radius * 2
        )
        context.fillEllipse(in: circle)
        let label = TextAnnotation(
            text: String(number),
            origin: CGPoint(x: center.x - radius / 2, y: center.y - radius * 0.7),
            fontName: "Helvetica-Bold",
            fontSize: radius * 1.2
        )
        let white = AnnotationStyle(
            color: AnnotationColor(red: 1, green: 1, blue: 1, alpha: 1),
            lineWidth: style.lineWidth,
            opacity: style.opacity
        )
        drawText(label, style: white, in: context)
    }

    private func makeContext(width: Int, height: Int) -> CGContext? {
        CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    }

    private func multipliedWithoutOverflow(_ values: Int...) -> Int? {
        values.reduce(1) { partial, value in
            let result = partial.multipliedReportingOverflow(by: value)
            return result.overflow ? 0 : result.partialValue
        }.nonzero
    }
}

private extension CGRect {
    var isIntegral: Bool {
        minX.isFinite
            && minY.isFinite
            && width.isFinite
            && height.isFinite
            && minX.rounded(.towardZero) == minX
            && minY.rounded(.towardZero) == minY
            && width.rounded(.towardZero) == width
            && height.rounded(.towardZero) == height
    }
}

private extension Int {
    var nonzero: Int? { self == 0 ? nil : self }
}
