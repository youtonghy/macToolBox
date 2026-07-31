import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class ScreenshotPreviewModel: ObservableObject {
    let image: CGImage
    @Published var errorMessage: String?
    var onClose: () -> Void = {}

    init(image: CGImage) {
        self.image = image
    }

    func copy() {
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            errorMessage = "无法生成 PNG 数据"
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setData(png, forType: .png) else {
            errorMessage = "无法写入剪贴板"
            return
        }
        if let tiff = bitmap.representation(using: .tiff, properties: [:]) {
            pasteboard.setData(tiff, forType: .tiff)
        }
        errorMessage = nil
    }

    func save() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "ToolBox Screenshot.png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            errorMessage = "无法生成 PNG 数据"
            return
        }
        do {
            try data.write(to: url, options: .atomic)
            errorMessage = nil
        } catch {
            errorMessage = "保存失败：\(error.localizedDescription)"
        }
    }
}

struct ScreenshotPreviewView: View {
    @ObservedObject var model: ScreenshotPreviewModel

    var body: some View {
        VStack(spacing: 12) {
            ScrollView([.horizontal, .vertical]) {
                Image(nsImage: NSImage(cgImage: model.image, size: .zero))
                    .resizable()
                    .scaledToFit()
            }
            .frame(minWidth: 560, minHeight: 360)
            .background(Color(nsColor: .windowBackgroundColor))

            HStack(spacing: 10) {
                if let error = model.errorMessage {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
                Spacer()
                Button("复制", systemImage: "doc.on.doc") { model.copy() }
                Button("保存", systemImage: "square.and.arrow.down") { model.save() }
                Button("关闭") { model.onClose() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(14)
    }
}

@MainActor
final class ScreenshotPreviewController: NSObject, NSWindowDelegate {
    private var windowController: NSWindowController?
    var onClose: () -> Void

    init(onClose: @escaping () -> Void = {}) {
        self.onClose = onClose
    }

    func show(image: CGImage) {
        close()
        let model = ScreenshotPreviewModel(image: image)
        model.onClose = { [weak self] in self?.close() }
        let hosting = NSHostingController(rootView: ScreenshotPreviewView(model: model))
        let window = NSWindow(contentViewController: hosting)
        window.title = "截图预览"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 760, height: 560))
        window.center()
        window.delegate = self
        let controller = NSWindowController(window: window)
        windowController = controller
        NSApp.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }

    func bringForward() {
        windowController?.window?.makeKeyAndOrderFront(nil)
    }

    func close() {
        guard let window = windowController?.window else { return }
        window.delegate = nil
        windowController = nil
        window.close()
        onClose()
    }

    func windowWillClose(_ notification: Notification) {
        windowController = nil
        onClose()
    }
}
