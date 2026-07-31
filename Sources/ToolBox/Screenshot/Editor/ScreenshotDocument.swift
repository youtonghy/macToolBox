struct ScreenshotDocument {
    let baseImage: ScreenshotImageSource
    var annotations: [ScreenshotAnnotation]

    init(baseImage: ScreenshotImageSource, annotations: [ScreenshotAnnotation] = []) {
        self.baseImage = baseImage
        self.annotations = annotations
    }
}

struct AnnotationEditorState {
    var document: ScreenshotDocument
    let historyLimit: Int
    var undoStack: [[ScreenshotAnnotation]] = []
    var redoStack: [[ScreenshotAnnotation]] = []

    init(document: ScreenshotDocument, historyLimit: Int = 100) {
        self.document = document
        self.historyLimit = max(1, historyLimit)
    }
}

enum AnnotationCommand: Equatable {
    case add(ScreenshotAnnotation)
    case update(ScreenshotAnnotation)
    case delete(UUID)
    case reorder(id: UUID, to: Int)
    case undo
    case redo
}
