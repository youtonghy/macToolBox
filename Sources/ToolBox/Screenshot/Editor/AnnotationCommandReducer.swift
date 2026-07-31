import CoreGraphics
import Foundation

enum AnnotationCommandReducer {
    static func reduce(state: inout AnnotationEditorState, command: AnnotationCommand) throws {
        switch command {
        case .undo:
            guard let prior = state.undoStack.popLast() else { throw AnnotationError.historyUnavailable }
            state.redoStack.append(state.document.annotations)
            state.document.annotations = prior
        case .redo:
            guard let next = state.redoStack.popLast() else { throw AnnotationError.historyUnavailable }
            state.undoStack.append(state.document.annotations)
            trimHistory(&state.undoStack, limit: state.historyLimit)
            state.document.annotations = next
        default:
            let before = state.document.annotations
            switch command {
            case let .add(item):
                try validate(item, in: state.document)
                state.document.annotations.append(item)
            case let .update(item):
                try validate(item, in: state.document)
                guard let index = state.document.annotations.firstIndex(where: { $0.id == item.id }) else {
                    throw AnnotationError.unknownAnnotation
                }
                state.document.annotations[index] = item
            case let .delete(id):
                guard let index = state.document.annotations.firstIndex(where: { $0.id == id }) else {
                    throw AnnotationError.unknownAnnotation
                }
                state.document.annotations.remove(at: index)
            case let .reorder(id, target):
                guard let source = state.document.annotations.firstIndex(where: { $0.id == id }) else {
                    throw AnnotationError.unknownAnnotation
                }
                guard state.document.annotations.indices.contains(target) else {
                    throw AnnotationError.invalidIndex
                }
                let item = state.document.annotations.remove(at: source)
                state.document.annotations.insert(item, at: target)
            case .undo, .redo:
                break
            }
            state.undoStack.append(before)
            trimHistory(&state.undoStack, limit: state.historyLimit)
            state.redoStack.removeAll()
        }
    }

    private static func validate(_ item: ScreenshotAnnotation, in document: ScreenshotDocument) throws {
        try validate(item.style)
        guard item.transform.isFinite, abs(item.transform.determinant) > .ulpOfOne else {
            throw AnnotationError.invalidGeometry
        }

        let bounds = CGRect(origin: .zero, size: document.baseImage.pixelSize)
        switch item.payload {
        case let .rectangle(rect), let .ellipse(rect):
            try validate(rect: rect, in: bounds)
        case let .line(start, end):
            try validate(points: [start, end], in: bounds, minimumCount: 2)
        case let .arrow(start, end, headLength):
            guard headLength.isFinite, headLength > 0 else { throw AnnotationError.invalidGeometry }
            try validate(points: [start, end], in: bounds, minimumCount: 2)
        case let .stroke(points, _):
            try validate(points: points, in: bounds, minimumCount: 1)
        case let .text(text):
            guard !text.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !text.fontName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  text.fontSize.isFinite,
                  text.fontSize > 0
            else {
                throw AnnotationError.invalidText
            }
            try validate(points: [text.origin], in: bounds, minimumCount: 1)
        case let .mosaic(rect, blockSize):
            guard blockSize > 0 else { throw AnnotationError.invalidGeometry }
            try validate(rect: rect, in: bounds)
        case let .numberedMarker(center, number):
            guard number > 0 else { throw AnnotationError.invalidGeometry }
            try validate(points: [center], in: bounds, minimumCount: 1)
        }
    }

    private static func validate(_ style: AnnotationStyle) throws {
        let components = [
            style.color.red,
            style.color.green,
            style.color.blue,
            style.color.alpha,
            style.opacity,
        ]
        guard style.lineWidth.isFinite,
              style.lineWidth > 0,
              components.allSatisfy({ $0.isFinite && (0...1).contains($0) })
        else {
            throw AnnotationError.invalidStyle
        }
    }

    private static func validate(rect: CGRect, in bounds: CGRect) throws {
        guard rect.isFinite,
              rect.width > 0,
              rect.height > 0,
              bounds.contains(rect)
        else {
            throw AnnotationError.invalidGeometry
        }
    }

    private static func validate(points: [CGPoint], in bounds: CGRect, minimumCount: Int) throws {
        guard points.count >= minimumCount,
              points.allSatisfy({ $0.isFinite && bounds.contains($0) })
        else {
            throw AnnotationError.invalidGeometry
        }
    }

    private static func trimHistory(_ history: inout [[ScreenshotAnnotation]], limit: Int) {
        if history.count > limit {
            history.removeFirst(history.count - limit)
        }
    }
}

private extension CGPoint {
    var isFinite: Bool {
        x.isFinite && y.isFinite
    }
}

private extension CGRect {
    var isFinite: Bool {
        origin.isFinite && width.isFinite && height.isFinite
    }
}

private extension CGAffineTransform {
    var isFinite: Bool {
        [a, b, c, d, tx, ty].allSatisfy(\.isFinite)
    }

    var determinant: CGFloat {
        a * d - b * c
    }
}
