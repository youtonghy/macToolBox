import Foundation

enum OCRWorkerExecutableLocatorError: Error, Equatable {
    case missingWorker
    case invalidWorker
    case unsupportedInterpreter
}

struct OCRWorkerExecutable: Equatable, Sendable {
    let executableURL: URL
    let arguments: [String]
}

struct OCRWorkerExecutableLocator {
    private let bundle: Bundle
    private let explicitURL: URL?
    private let environment: [String: String]
    private let allowEnvironmentOverride: Bool

    init(
        bundle: Bundle = .main,
        explicitURL: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        allowEnvironmentOverride: Bool = false
    ) {
        self.bundle = bundle
        self.explicitURL = explicitURL
        self.environment = environment
        self.allowEnvironmentOverride = allowEnvironmentOverride
    }

    func locate() throws -> OCRWorkerExecutable {
        var candidates = [
            explicitURL,
            bundle.url(forResource: "ToolBoxOCRWorker", withExtension: nil),
            bundle.url(forResource: "toolbox_ocr_worker", withExtension: "py"),
            bundle.url(
                forResource: "toolbox_ocr_worker",
                withExtension: "py",
                subdirectory: "ToolBoxOCRWorker"
            ),
        ].compactMap { $0 }
        if allowEnvironmentOverride,
           let override = environment["TOOLBOX_OCR_WORKER"] {
            candidates.insert(URL(fileURLWithPath: override), at: 1)
        }

        for candidate in candidates {
            let url = candidate.standardizedFileURL
            guard isRegularFile(url), !isSymlink(url) else { continue }
            if url.pathExtension.lowercased() == "py" {
                let interpreter = bundledPythonInterpreter()
                    ?? (allowEnvironmentOverride ? pythonInterpreter() : nil)
                guard let interpreter else {
                    throw OCRWorkerExecutableLocatorError.unsupportedInterpreter
                }
                return OCRWorkerExecutable(
                    executableURL: interpreter,
                    arguments: [url.path]
                )
            }
            guard FileManager.default.isExecutableFile(atPath: url.path) else { continue }
            return OCRWorkerExecutable(executableURL: url, arguments: [])
        }
        throw OCRWorkerExecutableLocatorError.missingWorker
    }

    private func pythonInterpreter() -> URL? {
        var candidates = [
            URL(fileURLWithPath: "/usr/bin/python3"),
            URL(fileURLWithPath: "/opt/homebrew/bin/python3"),
            URL(fileURLWithPath: "/usr/local/bin/python3"),
        ]
        if allowEnvironmentOverride,
           let configured = environment["TOOLBOX_OCR_PYTHON"] {
            candidates.insert(URL(fileURLWithPath: configured), at: 0)
        }
        return candidates.first {
            isRegularFile($0) && !isSymlink($0) && FileManager.default.isExecutableFile(atPath: $0.path)
        }
    }

    private func bundledPythonInterpreter() -> URL? {
        let candidates = [
            bundle.url(forResource: "python3", withExtension: nil, subdirectory: "ToolBoxOCRWorker/bin"),
            bundle.url(forResource: "python3", withExtension: nil, subdirectory: "bin"),
            bundle.url(forResource: "python3", withExtension: nil, subdirectory: "ocr-worker-runtime/bin"),
        ].compactMap { $0 }
        return candidates.first {
            isRegularFile($0) && !isSymlink($0) && FileManager.default.isExecutableFile(atPath: $0.path)
        }
    }

    private func isRegularFile(_ url: URL) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
              values.isRegularFile == true
        else { return false }
        return true
    }

    private func isSymlink(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true
    }
}
