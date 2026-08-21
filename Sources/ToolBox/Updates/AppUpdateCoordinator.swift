import AppKit
import Combine
import Foundation
import OSLog

@MainActor
final class AppUpdateCoordinator: ObservableObject {
    @Published var channel: AppUpdateChannel {
        didSet {
            defaults.set(channel.rawValue, forKey: Keys.channel)
            checkForUpdates(userInitiated: false)
        }
    }
    @Published var automaticallyChecks: Bool {
        didSet {
            defaults.set(automaticallyChecks, forKey: Keys.automaticallyChecks)
            if automaticallyChecks { checkForUpdates(userInitiated: false) }
        }
    }
    @Published var automaticallyDownloads: Bool {
        didSet { defaults.set(automaticallyDownloads, forKey: Keys.automaticallyDownloads) }
    }
    @Published private(set) var state: AppUpdateState = .idle
    @Published private(set) var latestRelease: AppRelease?

    let currentVersion: String
    var isDevelopmentBuild: Bool { AppUpdatePolicy.isDevelopmentVersion(currentVersion) }

    private enum Keys {
        static let channel = "updates.channel"
        static let automaticallyChecks = "updates.automaticallyChecks"
        static let automaticallyDownloads = "updates.automaticallyDownloads"
    }

    private let defaults: UserDefaults
    private let releaseClient: any AppReleaseFetching
    private let installer: AppUpdateInstaller
    private var pendingUpdate: PendingAppUpdate?
    private var operation: Task<Void, Never>?
    private var automaticCheckTask: Task<Void, Never>?
    private var lastPresentedAvailableVersion: String?
    private let logger = Logger(subsystem: "ToolBox", category: "AppUpdate")

    init(
        defaults: UserDefaults = .standard,
        releaseClient: any AppReleaseFetching = GitHubReleaseClient(),
        installer: AppUpdateInstaller = AppUpdateInstaller(),
        bundle: Bundle = .main
    ) {
        self.defaults = defaults
        self.releaseClient = releaseClient
        self.installer = installer
        self.currentVersion = bundle.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "DEV0.0.0"
        self.channel = AppUpdateChannel(
            rawValue: defaults.string(forKey: Keys.channel) ?? ""
        ) ?? .stable
        self.automaticallyChecks = defaults.object(forKey: Keys.automaticallyChecks) as? Bool ?? true
        self.automaticallyDownloads = defaults.object(forKey: Keys.automaticallyDownloads) as? Bool ?? true
    }

    func start() {
        automaticCheckTask?.cancel()
        automaticCheckTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(6 * 60 * 60))
                } catch {
                    return
                }
                guard let self else { return }
                guard self.automaticallyChecks else { continue }
                self.checkForUpdates(userInitiated: false)
            }
        }
        operation?.cancel()
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                if let pending = try await installer.restorePendingUpdate(),
                   pending.version != currentVersion {
                    pendingUpdate = pending
                    state = .ready(version: pending.version)
                    presentReadyAlert(version: pending.version)
                    return
                }
            } catch {
                logger.error(
                    "Ignoring invalid staged update: \(String(describing: error), privacy: .public)"
                )
            }
            if automaticallyChecks {
                await performCheck(userInitiated: false)
            }
        }
    }

    func checkForUpdates(userInitiated: Bool = true) {
        operation?.cancel()
        operation = Task { [weak self] in
            await self?.performCheck(userInitiated: userInitiated)
        }
    }

    func downloadAvailableUpdate() {
        guard let release = latestRelease else { return }
        operation?.cancel()
        operation = Task { [weak self] in
            await self?.performDownload(release)
        }
    }

    func restartAndInstall() {
        guard let pendingUpdate else { return }
        operation?.cancel()
        operation = Task { [weak self] in
            guard let self else { return }
            do {
                try await installer.launchInstaller(for: pendingUpdate)
                NSApp.terminate(nil)
            } catch {
                state = .failed(message: displayMessage(for: error))
            }
        }
    }

    private func performCheck(userInitiated: Bool) async {
        if !userInitiated {
            switch state {
            case .downloading, .ready:
                return
            default:
                break
            }
        }
        state = .checking
        do {
            let releases = try await releaseClient.fetchReleases()
            try Task.checkCancellation()
            guard let release = AppUpdatePolicy.latestUpdate(
                in: releases,
                channel: channel,
                currentVersion: currentVersion
            ), let version = release.version else {
                state = .upToDate
                return
            }
            latestRelease = release
            state = .available(version: version)
            presentAvailableAlert(release: release)
            if automaticallyDownloads && !isDevelopmentBuild {
                await performDownload(release)
            }
        } catch is CancellationError {
            return
        } catch {
            state = .failed(message: displayMessage(for: error))
            if userInitiated {
                AppAlert.show(title: "无法检查更新", message: displayMessage(for: error))
            }
        }
    }

    private func performDownload(_ release: AppRelease) async {
        guard !isDevelopmentBuild, let version = release.version else { return }
        state = .downloading(version: version)
        do {
            let pending = try await installer.downloadAndStage(release)
            try Task.checkCancellation()
            pendingUpdate = pending
            state = .ready(version: pending.version)
            presentReadyAlert(version: pending.version)
        } catch is CancellationError {
            state = .available(version: version)
        } catch {
            state = .failed(message: displayMessage(for: error))
        }
    }

    private func presentAvailableAlert(release: AppRelease) {
        guard let version = release.version else { return }
        guard lastPresentedAvailableVersion != version else { return }
        lastPresentedAvailableVersion = version
        let betaWarning = release.isPrerelease ? "\n\n这是 Beta 版本，可能不稳定。" : ""
        if isDevelopmentBuild {
            AppAlert.show(
                title: "发现新版本 \(version)",
                message: "当前是 \(currentVersion) 开发版，只会提醒，不会自动下载更新。\(betaWarning)"
            )
        } else if automaticallyDownloads {
            AppAlert.show(
                title: "发现新版本 \(version)",
                message: "ToolBox 正在后台下载更新。下载完成后会提醒你重启。\(betaWarning)"
            )
        } else {
            AppAlert.show(
                title: "发现新版本 \(version)",
                message: "可以立即下载，或稍后在“设置 → 关于”中更新。\(betaWarning)",
                primaryButton: ("下载更新", { [weak self] in self?.downloadAvailableUpdate() }),
                secondaryButtonTitle: "稍后"
            )
        }
    }

    private func presentReadyAlert(version: String) {
        AppAlert.show(
            title: "更新已准备好",
            message: "ToolBox \(version) 已下载并验证。重启应用即可完成更新。",
            primaryButton: ("重启并更新", { [weak self] in self?.restartAndInstall() }),
            secondaryButtonTitle: "稍后"
        )
    }

    private func displayMessage(for error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return error.localizedDescription
    }
}
