import Darwin
import Foundation

final class PowerSamplingEngine {
    private let queue = DispatchQueue(label: "com.youtonghy.toolbox.power-engine")
    private let makeProcess: () -> Process
    private let leaseDuration: TimeInterval
    private let processTimeout: TimeInterval
    private var timer: DispatchSourceTimer?
    private var process: Process?
    private var parser = PowermetricsParser()
    private var latest: AuthorizedPowerReading?
    private var failure: PowerSamplingFailure?
    private var lastPoll = Date.distantPast
    private var startedAt = Date.distantPast
    private var retryAfter = Date.distantPast
    private var stopped = false
    private var terminating = false
    private var producedReport = false
    private var outputEnded = false

    init(
        leaseDuration: TimeInterval = 6,
        processTimeout: TimeInterval = 10,
        makeProcess: @escaping () -> Process = PowerSamplingEngine.systemProcess
    ) {
        self.leaseDuration = leaseDuration
        self.processTimeout = processTimeout
        self.makeProcess = makeProcess
    }

    static func systemProcess() -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/powermetrics")
        // Bounded batches also limit a child's lifetime if this helper crashes.
        process.arguments = ["--samplers", "cpu_power", "-f", "text", "-b", "1", "-i", "1000", "-n", "5"]
        process.environment = ["PATH": "/usr/bin:/bin", "LANG": "C", "LC_ALL": "C"]
        process.currentDirectoryURL = URL(fileURLWithPath: "/")
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        return process
    }

    func poll(_ reply: @escaping (PowerSamplingResponse) -> Void) {
        queue.async {
            guard !self.stopped else {
                reply(PowerSamplingResponse(failure: .stopped))
                return
            }
            let now = Date()
            self.lastPoll = now
            if self.process == nil, now >= self.retryAfter { self.launch() }
            let reading = self.latest.flatMap { $0.isFresh(at: now) ? $0 : nil }
            reply(PowerSamplingResponse(reading: reading, failure: reading == nil ? self.failure : nil))
        }
    }

    func stop(_ completion: @escaping () -> Void = {}) {
        queue.async {
            self.stopped = true
            self.latest = nil
            self.timer?.cancel()
            self.timer = nil
            self.terminateProcess()
            completion()
        }
    }

    private func launch() {
        let child = makeProcess()
        let output = Pipe()
        child.standardOutput = output
        parser = PowermetricsParser()
        producedReport = false
        outputEnded = false
        child.terminationHandler = { [weak self] child in
            self?.queue.async { [weak self] in self?.finishIfReady(child) }
        }
        do {
            try child.run()
        } catch {
            failure = .samplingFailed
            retryAfter = Date().addingTimeInterval(5)
            return
        }
        output.fileHandleForWriting.closeFile()
        process = child
        startedAt = Date()
        failure = nil
        if timer == nil {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 0.25, repeating: 0.25)
            timer.setEventHandler { [weak self] in self?.checkDeadline() }
            self.timer = timer
            timer.resume()
        }
        // One reader owns the pipe through EOF; report bytes are always handled
        // before completion, including the final report of each bounded batch.
        DispatchQueue.global(qos: .utility).async { [weak self] in
            while true {
                let data = output.fileHandleForReading.availableData
                if data.isEmpty { break }
                self?.queue.async { [weak self] in
                    guard let self, !self.stopped, self.process === child else { return }
                    if let reading = self.parser.append(data).last {
                        self.latest = reading
                        self.producedReport = true
                    }
                }
            }
            output.fileHandleForReading.closeFile()
            self?.queue.async { [weak self] in
                guard let self, self.process === child else { return }
                self.outputEnded = true
                self.finishIfReady(child)
            }
        }
    }

    // EOF and process termination can arrive in either order. Never block a
    // worker in waitUntilExit: its run-loop wait can outlive the child.
    private func finishIfReady(_ child: Process) {
        guard process === child, outputEnded, !child.isRunning else { return }
        process = nil
        terminating = false
        child.terminationHandler = nil
        if child.terminationStatus != 0 || !producedReport {
            latest = nil
            failure = .samplingFailed
            retryAfter = Date().addingTimeInterval(5)
        }
    }

    private func checkDeadline() {
        // Also reconcile completed children if the termination callback is late.
        if let child = process { finishIfReady(child) }
        let now = Date()
        if now.timeIntervalSince(lastPoll) > leaseDuration {
            latest = nil
            timer?.cancel()
            timer = nil
            terminateProcess()
        } else if process != nil, now.timeIntervalSince(startedAt) > processTimeout {
            latest = nil
            failure = .samplingFailed
            terminateProcess()
        }
    }

    private func terminateProcess() {
        guard !terminating, let child = process, child.isRunning else { return }
        terminating = true
        child.terminate()
        queue.asyncAfter(deadline: .now() + 1) {
            if child.isRunning { kill(child.processIdentifier, SIGKILL) }
        }
    }
}
