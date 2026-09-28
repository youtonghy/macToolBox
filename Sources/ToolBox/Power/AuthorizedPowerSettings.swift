import AppKit
import ServiceManagement
import SwiftUI

protocol AuthorizedPowerServicing: AnyObject {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() async throws
}

extension SMAppService: AuthorizedPowerServicing {}

@MainActor
final class AuthorizedPowerSettings: ObservableObject {
    static let shared = AuthorizedPowerSettings()
    static let failedRestartsKey = "authorizedPowerSamplingFailedRestarts"
    static let unavailableKey = "authorizedPowerSamplingUnavailable"
    static let registeredHelperKey = "authorizedPowerSamplingRegisteredHelper"
    /// Restarts in a row that did not bring samples back before sampling is
    /// turned off. Persisted, so short power-panel sessions still add up.
    static let maximumFailedRestarts = 5

    @Published private(set) var requested = false
    @Published private(set) var status: SMAppService.Status = .notRegistered
    @Published private(set) var isChanging = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var unavailable = false
    private let service: any AuthorizedPowerServicing
    private let defaults: UserDefaults
    private let pinnedHelperIdentity: () -> String?

    init(
        defaults: UserDefaults = .standard,
        service: any AuthorizedPowerServicing = SMAppService.daemon(plistName: PowerSamplingService.plistName),
        pinnedHelperIdentity: @escaping () -> String? = {
            PowerSamplingIdentity.pinnedCDHash(
                for: Bundle.main.bundleURL.appendingPathComponent(PowerSamplingService.helperRelativePath)
            )
        }
    ) {
        self.defaults = defaults
        self.service = service
        self.pinnedHelperIdentity = pinnedHelperIdentity
        refresh()
    }

    func refresh() {
        requested = defaults.bool(forKey: PowerSamplingService.enabledKey)
        unavailable = defaults.bool(forKey: Self.unavailableKey)
        status = service.status
    }

    func setEnabled(_ enabled: Bool) {
        changeEnabled(enabled, unavailable: false)
    }

    /// Shares the manual off path, including unregistering the helper.
    @discardableResult
    private func changeEnabled(_ enabled: Bool, unavailable: Bool) -> Bool {
        guard !isChanging else { return false }
        errorMessage = nil
        isChanging = true
        // Any explicit change starts a new failure streak.
        defaults.removeObject(forKey: Self.failedRestartsKey)
        defaults.set(unavailable, forKey: Self.unavailableKey)
        self.unavailable = unavailable
        if !enabled {
            // Stop requesting samples and update every settings view immediately,
            // even if removing the service takes time or fails.
            defaults.set(false, forKey: PowerSamplingService.enabledKey)
            requested = false
        }
        Task {
            defer { isChanging = false; refresh() }
            do {
                if enabled {
                    if service.status != .enabled && service.status != .requiresApproval {
                        try await registerService()
                    }
                    defaults.set(true, forKey: PowerSamplingService.enabledKey)
                    if service.status == .requiresApproval {
                        SMAppService.openSystemSettingsLoginItems()
                    }
                } else {
                    if service.status != .notRegistered && service.status != .notFound {
                        try await service.unregister()
                    }
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
        return true
    }

    /// Recovery registers a missing item and re-registers one whose launch
    /// constraint still pins a previous helper build. Otherwise the registration
    /// is left alone: needless re-registration can leave the item needing
    /// approval again. Replacing a wedged helper process is the client's job
    /// (see `AuthorizedPowerSampling.restart()`). Background recovery never opens
    /// an approval window. After `maximumFailedRestarts` restarts without a
    /// fresh sample, sampling is turned off instead. Returns true only when the
    /// client should restart its helper session; otherwise the watchdog retries
    /// later or, once sampling is off, falls back to IOReport.
    func restartAfterSamplingFailure() async -> Bool {
        guard !isChanging, defaults.bool(forKey: PowerSamplingService.enabledKey) else { return false }
        let failedRestarts = defaults.integer(forKey: Self.failedRestartsKey)
        guard failedRestarts < Self.maximumFailedRestarts else {
            changeEnabled(false, unavailable: true)
            return false
        }
        defaults.set(failedRestarts + 1, forKey: Self.failedRestartsKey)
        isChanging = true
        errorMessage = nil
        defer { isChanging = false; refresh() }
        do {
            if service.status == .notRegistered || service.status == .notFound {
                try await registerService()
            } else if registrationIsStale {
                try await reregisterService()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        return true
    }

    /// Run at launch. After a rebuild or update, launchd refuses to spawn the
    /// helper registered for the previous build (EX_CONFIG, "needs LWCR update")
    /// until the daemon is registered again.
    func refreshStaleRegistration() async {
        guard !isChanging, defaults.bool(forKey: PowerSamplingService.enabledKey),
              service.status == .enabled || service.status == .requiresApproval,
              registrationIsStale
        else { return }
        isChanging = true
        errorMessage = nil
        defer { isChanging = false; refresh() }
        do {
            try await reregisterService()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// A fresh sample ends the failure streak.
    func recordSamplingRecovered() {
        defaults.removeObject(forKey: Self.failedRestartsKey)
    }

    /// Whether the registered launch constraint pins a different helper build.
    /// A registration from before this was recorded counts as stale.
    private var registrationIsStale: Bool {
        guard let identity = pinnedHelperIdentity() else { return false }
        return defaults.string(forKey: Self.registeredHelperKey) != identity
    }

    /// Registration waits on the background task management daemon; keep it
    /// off the main thread.
    private func registerService() async throws {
        let service = self.service
        try await Task.detached(priority: .userInitiated) { try service.register() }.value
        defaults.set(pinnedHelperIdentity(), forKey: Self.registeredHelperKey)
    }

    private func reregisterService() async throws {
        try await service.unregister()
        // Registering before BTM drops the old record fails with
        // "invalid record generation".
        for _ in 0..<20 {
            let status = service.status
            if status == .notRegistered || status == .notFound { break }
            try await Task.sleep(for: .milliseconds(250))
        }
        try await registerService()
    }
}

struct AuthorizedPowerSettingsSection: View {
    @ObservedObject private var settings = AuthorizedPowerSettings.shared

    var body: some View {
        SettingsSection(title: "功耗采集") {
            SettingsInnerCard {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("授权功耗采集", isOn: Binding(
                        get: { settings.requested }, set: { settings.setEnabled($0) }
                    ))
                    .toggleStyle(.switch)
                    .disabled(settings.isChanging)
                    if settings.unavailable {
                        Text("当前功能不可用")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    Text("CPU 功耗不可用时，可授权系统辅助服务采集。关闭后停止采集并移除服务。")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    if settings.requested {
                        if settings.status == .enabled {
                            Text("已授权，将在显示功耗时采集。")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                        } else if settings.status == .requiresApproval {
                            Text("等待系统授权。请在登录项设置中允许 ToolBox 后台服务。")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                            Button("打开登录项设置") { SMAppService.openSystemSettingsLoginItems() }
                        } else {
                            Text("采集服务未注册或不可用，请重新启用。")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                            Button("重新启用功耗采集") { settings.setEnabled(true) }
                                .disabled(settings.isChanging)
                        }
                    } else if settings.status == .enabled || settings.status == .requiresApproval {
                        Button("移除功耗采集服务") { settings.setEnabled(false) }
                            .disabled(settings.isChanging)
                    }
                    if let error = settings.errorMessage {
                        Text(error).font(.system(size: 12)).foregroundStyle(.red)
                    }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            settings.refresh()
        }
    }
}
