import AppKit
import Combine
import Foundation
import Testing

@testable import ToolBoxCore

private actor ControlledImageBatches {
    private var nextID = 0
    private var completions: [Int: CheckedContinuation<[ImageJobResult], Never>] = [:]
    private var observers: [Int: CheckedContinuation<Void, Never>] = [:]
    private var progressCallbacks: [Int: ImageToolsPanelModel.Progress] = [:]

    func process(_ progress: ImageToolsPanelModel.Progress?) async -> [ImageJobResult] {
        let id = nextID
        nextID += 1
        progressCallbacks[id] = progress
        return await withCheckedContinuation { continuation in
            completions[id] = continuation
            observers.removeValue(forKey: id)?.resume()
        }
    }

    func started(_ id: Int) async {
        if completions[id] != nil { return }
        await withCheckedContinuation { observers[id] = $0 }
    }

    func complete(_ id: Int, results: [ImageJobResult]) {
        completions.removeValue(forKey: id)?.resume(returning: results)
    }

    func report(_ id: Int, completed: Int) {
        progressCallbacks[id]?(completed, 10)
    }
}

@MainActor
struct ImageToolsPanelModelTests {
    private let source = URL(fileURLWithPath: "/tmp/toolbox-panel-test.jpg")

    private func idle(_ model: ImageToolsPanelModel) async {
        for await running in model.$isRunning.values {
            if !running { return }
        }
    }

    @Test func switchingBackToCompressionDoesNotConvert() {
        let model = ImageToolsPanelModel()
        model.switchMode(.convert)
        model.outputFormat = .png
        #expect(model.jobOptions.outputFormat == .png)
        model.switchMode(.compress)
        #expect(model.jobOptions.outputFormat == nil)
        model.switchMode(.convert)
        #expect(model.jobOptions.outputFormat == .png)
    }

    @Test func cancellationDrainsCommitAndKeepsCompletedResults() async {
        let gate = ControlledImageBatches()
        let model = ImageToolsPanelModel(processor: { _, _, progress in await gate.process(progress) })
        model.addURLs([source, URL(fileURLWithPath: "/tmp/toolbox-panel-second.jpg")])
        model.run()
        await gate.started(0)
        model.addURLs([URL(fileURLWithPath: "/tmp/ignored.jpg")])
        model.removeURLs(at: IndexSet(integer: 0))
        model.clearAll()
        model.switchMode(.convert)
        #expect(model.urls.count == 2)
        #expect(model.mode == .compress)
        model.cancelRunningTask()
        #expect(model.isRunning)
        #expect(!model.canRun)
        await gate.complete(0, results: [ImageJobResult(source: source, outcome: .replaced(originalBytes: 20, resultBytes: 10, format: .jpeg))])
        await idle(model)
        #expect(model.rows[0].isPositive)
        #expect(!model.rows[1].isPositive)
        #expect(model.rows[1].status == L10n.string("未开始（已取消）"))
        #expect(model.summaryLine?.contains(L10n.string("已取消")) == true)
        #expect(model.canRun)

        // A late callback from the cancelled batch cannot overwrite the next run.
        model.run()
        await gate.started(1)
        await gate.report(0, completed: 999)
        await gate.complete(1, results: [])
        await idle(model)
        #expect(model.progressCompleted != 999)
    }

    @Test func onlyOwningWindowCloseCancels() async {
        let gate = ControlledImageBatches()
        let model = ImageToolsPanelModel(processor: { _, _, progress in await gate.process(progress) })
        let owner = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: true)
        let other = NSWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: true)
        model.window = owner
        model.addURLs([source])
        model.run()
        await gate.started(0)
        model.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: other))
        #expect(!model.cancellationRequested)
        model.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: owner))
        #expect(model.cancellationRequested)
        await gate.complete(0, results: [])
        await idle(model)
    }
}
