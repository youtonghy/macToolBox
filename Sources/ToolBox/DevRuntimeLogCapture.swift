import Foundation
import OSLog

enum DevRuntimeLogCapturePolicy {
    static let maximumRetainedSessions = 10

    static func isEnabled(marketingVersion: String?) -> Bool {
        marketingVersion?.hasPrefix("DEV") == true
    }

    static func logStreamArguments(processID: Int32) -> [String] {
        [
            "stream",
            "--process", String(processID),
            "--level", "debug",
            "--style", "compact",
            "--color", "none",
        ]
    }

    static func sessionFileName(
        date: Date,
        processID: Int32,
        timeZone: TimeZone = .current
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "ToolBox-\(formatter.string(from: date))-pid\(processID).log"
    }

    static func filesToRemoveBeforeNewSession(
        from files: [URL],
        maximumRetainedSessions: Int = maximumRetainedSessions
    ) -> [URL] {
        let sessionLogs = files
            .filter { $0.lastPathComponent.hasPrefix("ToolBox-") && $0.pathExtension == "log" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let existingFilesToKeep = max(0, maximumRetainedSessions - 1)
        return Array(sessionLogs.dropLast(existingFilesToKeep))
    }
}

@MainActor
final class DevRuntimeLogCapture {
    static let shared = DevRuntimeLogCapture()

    private static let watchdogScript = """
    target_pid="$1"
    output_path="$2"
    shift 2
    /usr/bin/log "$@" >> "$output_path" 2>&1 &
    stream_pid=$!
    cleanup() {
        kill "$stream_pid" 2>/dev/null || true
        wait "$stream_pid" 2>/dev/null || true
    }
    trap cleanup EXIT HUP INT TERM
    while kill -0 "$target_pid" 2>/dev/null; do
        /bin/sleep 1
    done
    """

    private let logger = Logger(subsystem: "ToolBox", category: "DevRuntimeLogCapture")
    private var watchdog: Process?
    private(set) var logFileURL: URL?

    func start(
        bundle: Bundle = .main,
        processInfo: ProcessInfo = .processInfo,
        fileManager: FileManager = .default,
        date: Date = Date()
    ) {
        guard watchdog == nil else { return }
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        guard DevRuntimeLogCapturePolicy.isEnabled(marketingVersion: version) else { return }

        do {
            let directory = try logDirectory(fileManager: fileManager)
            try pruneOldSessions(in: directory, fileManager: fileManager)
            let processID = processInfo.processIdentifier
            let fileURL = directory.appendingPathComponent(
                DevRuntimeLogCapturePolicy.sessionFileName(date: date, processID: processID)
            )
            try sessionHeader(
                version: version ?? "unknown",
                build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
                processID: processID,
                executablePath: bundle.executablePath ?? "unknown",
                date: date
            ).write(to: fileURL, atomically: true, encoding: .utf8)

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = [
                "-c",
                Self.watchdogScript,
                "toolbox-dev-log-watchdog",
                String(processID),
                fileURL.path,
            ] + DevRuntimeLogCapturePolicy.logStreamArguments(processID: processID)
            try process.run()
            watchdog = process
            logFileURL = fileURL
            logger.notice("DEV runtime logging started: \(fileURL.path, privacy: .public)")
        } catch {
            watchdog = nil
            logFileURL = nil
            logger.error("Failed to start DEV runtime logging: \(String(describing: error), privacy: .public)")
        }
    }

    func stop() {
        guard let watchdog else { return }
        self.watchdog = nil
        logger.notice("Stopping DEV runtime logging")
        if watchdog.isRunning {
            watchdog.terminate()
        }
    }

    private func logDirectory(fileManager: FileManager) throws -> URL {
        let library = try fileManager.url(
            for: .libraryDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = library
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("ToolBox", isDirectory: true)
            .appendingPathComponent("DEV", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func pruneOldSessions(in directory: URL, fileManager: FileManager) throws {
        let files = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        for file in DevRuntimeLogCapturePolicy.filesToRemoveBeforeNewSession(from: files) {
            do {
                try fileManager.removeItem(at: file)
            } catch {
                logger.error(
                    "Failed to remove old DEV runtime log \(file.path, privacy: .public): \(String(describing: error), privacy: .public)"
                )
            }
        }
    }

    private func sessionHeader(
        version: String,
        build: String,
        processID: Int32,
        executablePath: String,
        date: Date
    ) -> String {
        """
        ToolBox DEV runtime log
        started=\(ISO8601DateFormatter().string(from: date))
        version=\(version)
        build=\(build)
        pid=\(processID)
        executable=\(executablePath)

        """
    }
}
