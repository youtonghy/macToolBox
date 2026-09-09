import Foundation

struct ScreenshotDocument: Sendable {
    let baseImage: ScreenshotImageSource
    var annotations: [ScreenshotAnnotation]

    init(baseImage: ScreenshotImageSource, annotations: [ScreenshotAnnotation] = []) {
        self.baseImage = topLeftScreenshotSource(baseImage)
        self.annotations = annotations
    }
}

struct AnnotationEditorState {
    var document: ScreenshotDocument
    let historyLimit: Int
    let pixelHistoryByteLimit: Int
    var undoStack: [[ScreenshotAnnotation]] = []
    var redoStack: [[ScreenshotAnnotation]] = []

    init(document: ScreenshotDocument, historyLimit: Int = 100, pixelHistoryByteLimit: Int = SimilarPixelEraser.maximumHistoryBytes) {
        self.document = document
        self.historyLimit = max(1, historyLimit)
        self.pixelHistoryByteLimit = max(4, pixelHistoryByteLimit)
    }
}

enum AnnotationCommand: Equatable {
    case setPixelEffect(ScreenshotAnnotation)
    case add(ScreenshotAnnotation)
    case update(ScreenshotAnnotation)
    case delete(UUID)
    case reorder(id: UUID, to: Int)
    case undo
    case redo
}
