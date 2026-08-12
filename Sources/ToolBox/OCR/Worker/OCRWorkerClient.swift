import Darwin
import Foundation
import ImageIO

enum OCRWorkerClientError: Error, Equatable {
    case alreadyRunning
    case missingResult
    case taskMismatch
    case pipelineMismatch
    case variantMismatch
    case malformedUTF8
    case malformedJSON
    case lineTooLarge
    case outputTooLarge
    case workerExited(Int32)
    case workerFailed(String)
    case timedOut
    case executable(OCRWorkerExecutableLocatorError)
}

actor OCRWorkerRunning {
    static let maximumLineBytes = 8 * 1024 * 1024
    static let maximumOutputBytes = 32 * 1024 * 1024
    static let defaultTimeout: Duration = .seconds(120)

    private let executable: OCRWorkerExecutable
    private let timeout: Duration
    private let fileManager: FileManager
    private var activeProcess: Process?

    init(
        executable: OCRWorkerExecutable? = nil,
        locator: OCRWorkerExecutableLocator = OCRWorkerExecutableLocator(),
        timeout: Duration = OCRWorkerRunning.defaultTimeout,
        fileManager: FileManager = .default
    ) throws {
        do {
            self.executable = try executable ?? locator.locate()
        } catch let error as OCRWorkerExecutableLocatorError {
            throw OCRWorkerClientError.executable(error)
        }
        self.timeout = timeout
        self.fileManager = fileManager
    }

    func run(
        source: ScreenshotImageSource,
        selection: OCRModelSelection,
        modelDirectory: URL
    ) async throws -> OCRResult {
        guard activeProcess == nil else { throw OCRWorkerClientError.alreadyRunning }
        guard selection.isKnownVariant,
              [.ppStructureV3, .paddleOCRVL].contains(selection.pipeline)
        else { throw OCRWorkerProtocolError.unsupportedPipeline(selection.pipeline.rawValue) }

        let session = try makeSessionDirectory()
        defer { try? fileManager.removeItem(at: session) }
        let imageURL = session.appendingPathComponent("input.png")
        try ScreenshotPNGExporter().export(source: source, to: imageURL)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: imageURL.path)

        let taskID = UUID().uuidString.lowercased()
        let request = try OCRWorkerRequestEnvelope(
            taskID: taskID,
            pipeline: selection.pipeline,
            variantID: selection.variantID,
            imagePath: imageURL.lastPathComponent,
            modelDirectory: modelDirectory.standardizedFileURL.path
        )

        return try await withTaskCancellationHandler {
            try await perform(
                request: request,
                sessionDirectory: session,
                imageURL: imageURL
            )
        } onCancel: {
            Task { await self.shutdown() }
        }
    }

    func shutdown() {
        guard let process = activeProcess else { return }
        terminate(process)
        activeProcess = nil
    }

    private func perform(
        request: OCRWorkerRequestEnvelope,
        sessionDirectory: URL,
        imageURL: URL
    ) async throws -> OCRResult {
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let error = Pipe()
        process.executableURL = executable.executableURL
        process.arguments = executable.arguments
        process.currentDirectoryURL = sessionDirectory
        process.environment = Self.sanitizedEnvironment(sessionDirectory: sessionDirectory)
        process.standardInput = input
        process.standardOutput = output
        process.standardError = error
        activeProcess = process
        defer {
            activeProcess = nil
            if process.isRunning { terminate(process) }
            input.fileHandleForWriting.closeFile()
        }

        do {
            try process.run()
        } catch {
            throw OCRWorkerClientError.workerFailed(error.localizedDescription)
        }

        let requestData = try JSONEncoder().encode(request) + Data([0x0A])
        try input.fileHandleForWriting.write(contentsOf: requestData)

        let stdoutTask = Task.detached(priority: .userInitiated) {
            try Self.readLimited(output.fileHandleForReading)
        }
        let stderrTask = Task.detached(priority: .utility) {
            try Self.readLimited(error.fileHandleForReading)
        }
        let terminationTask = Task.detached(priority: .utility) {
            process.waitUntilExit()
            return process.terminationStatus
        }

        do {
            let collected = try await withThrowingTaskGroup(of: WorkerOutput.self) { group in
                group.addTask {
                    let status = await terminationTask.value
                    let stdout = try await stdoutTask.value
                    let stderr = try await stderrTask.value
                    return WorkerOutput(status: status, stdout: stdout, stderr: stderr)
                }
                group.addTask {
                    try await Task.sleep(for: self.timeout)
                    Self.terminateProcess(process)
                    Task {
                        try? await Task.sleep(for: .seconds(5))
                        Self.forceTerminate(process)
                    }
                    try? output.fileHandleForReading.close()
                    try? error.fileHandleForReading.close()
                    throw OCRWorkerClientError.timedOut
                }
                guard let first = try await group.next() else {
                    throw OCRWorkerClientError.missingResult
                }
                group.cancelAll()
                return first
            }
            return try parse(
                stdout: collected.stdout,
                stderr: collected.stderr,
                status: collected.status,
                request: request,
                imageSize: try imageSize(of: imageURL)
            )
        } catch is CancellationError {
            terminate(process)
            throw CancellationError()
        } catch OCRWorkerClientError.timedOut {
            terminate(process)
            throw OCRWorkerClientError.timedOut
        } catch {
            terminate(process)
            throw error
        }
    }

    private func parse(
        stdout: Data,
        stderr: Data,
        status: Int32,
        request: OCRWorkerRequestEnvelope,
        imageSize: CGSize
    ) throws -> OCRResult {
        guard stdout.count + stderr.count <= Self.maximumOutputBytes else {
            throw OCRWorkerClientError.outputTooLarge
        }
        guard let text = String(data: stdout, encoding: .utf8) else {
            throw OCRWorkerClientError.malformedUTF8
        }
        var result: OCRWorkerResultEnvelope?
        let decoder = JSONDecoder()
        for line in text.split(whereSeparator: \.isNewline) {
            let lineData = Data(line.utf8)
            guard lineData.count <= Self.maximumLineBytes else {
                throw OCRWorkerClientError.lineTooLarge
            }
            guard !lineData.isEmpty else { continue }
            if let error = try? decoder.decode(OCRWorkerErrorEnvelope.self, from: lineData) {
                guard error.taskID == request.taskID else { throw OCRWorkerClientError.taskMismatch }
                throw OCRWorkerClientError.workerFailed(error.message)
            }
            guard result == nil else { throw OCRWorkerProtocolError.duplicateTask }
            guard let decoded = try? decoder.decode(OCRWorkerResultEnvelope.self, from: lineData) else {
                throw OCRWorkerClientError.malformedJSON
            }
            guard decoded.taskID == request.taskID else { throw OCRWorkerClientError.taskMismatch }
            guard decoded.pipeline == request.pipeline else { throw OCRWorkerClientError.pipelineMismatch }
            guard decoded.variantID == request.variantID else { throw OCRWorkerClientError.variantMismatch }
            result = decoded
        }
        guard let result else {
            if status != 0 {
                let message = String(data: stderr, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                throw OCRWorkerClientError.workerFailed(message?.isEmpty == false ? message! : "worker exited \(status)")
            }
            throw OCRWorkerClientError.missingResult
        }
        return try OCRWorkerResultProjection.project(result, imageSize: imageSize)
    }

    private func imageSize(of url: URL) throws -> CGSize {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw OCRWorkerClientError.workerFailed("worker input image could not be read") }
        return CGSize(width: image.width, height: image.height)
    }

    private func makeSessionDirectory() throws -> URL {
        let root = fileManager.temporaryDirectory
        let session = root.appendingPathComponent("toolbox-ocr-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(
            at: session,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        return session
    }

    private func terminate(_ process: Process) {
        if process.isRunning { process.terminate() }
    }

    private static func terminateProcess(_ process: Process) {
        if process.isRunning { process.terminate() }
    }

    private static func forceTerminate(_ process: Process) {
        guard process.isRunning else { return }
        kill(process.processIdentifier, SIGKILL)
    }

    private static func sanitizedEnvironment(sessionDirectory: URL) -> [String: String] {
        let cacheDirectory = sessionDirectory
            .appendingPathComponent("paddlex-cache", isDirectory: true)
        return [
            "PATH": "/usr/bin:/bin",
            "HOME": NSHomeDirectory(),
            "TMPDIR": sessionDirectory.path,
            "LANG": "en_US.UTF-8",
            "PADDLE_PDX_CACHE_HOME": cacheDirectory.path,
            "HF_HUB_OFFLINE": "1",
            "TRANSFORMERS_OFFLINE": "1",
            "PADDLE_PDX_DISABLE_MODEL_SOURCE_CHECK": "True",
            "PYTHONDONTWRITEBYTECODE": "1",
            "PYTHONNOUSERSITE": "1",
        ]
    }

    private static func readLimited(_ handle: FileHandle) throws -> Data {
        var data = Data()
        var lineBytes = 0
        while true {
            let chunk = try handle.read(upToCount: 64 * 1024) ?? Data()
            if chunk.isEmpty { break }
            data.append(chunk)
            guard data.count <= maximumOutputBytes else { throw OCRWorkerClientError.outputTooLarge }
            for byte in chunk {
                if byte == 0x0A {
                    lineBytes = 0
                } else {
                    lineBytes += 1
                    guard lineBytes <= maximumLineBytes else {
                        throw OCRWorkerClientError.lineTooLarge
                    }
                }
            }
        }
        return data
    }

    private struct WorkerOutput: Sendable {
        let status: Int32
        let stdout: Data
        let stderr: Data
    }
}
