import Combine
import Foundation
import OSLog

/// Versioned persistence for SSID auto-switch settings, stored as JSON under
/// `networkLocation.autoSwitch.v1`.
struct NetworkLocationSettingsStore {
    static let defaultsKey = "networkLocation.autoSwitch.v1"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> NetworkLocationAutoSwitchConfiguration {
        guard let data = defaults.data(forKey: Self.defaultsKey) else { return .disabled }
        do {
            return try JSONDecoder().decode(NetworkLocationAutoSwitchConfiguration.self, from: data)
        } catch {
            CorruptDefaultsBackup.backup(defaults: defaults, key: Self.defaultsKey)
            return .disabled
        }
    }

    func save(_ configuration: NetworkLocationAutoSwitchConfiguration) throws {
        defaults.set(try JSONEncoder().encode(configuration), forKey: Self.defaultsKey)
    }
}

/// Single source of truth for network locations, shared by the menu-bar
/// section and the settings page. All `networksetup` work runs on one serial
/// queue so manual and automatic switches can never interleave.
@MainActor
final class NetworkLocationModel: ObservableObject {
    @Published private(set) var snapshot = NetworkLocationSnapshot.empty
    @Published private(set) var isBusy = false
    @Published private(set) var errorMessage: String?
    /// Last automatic switch, shown so users can tell why the location moved.
    @Published private(set) var lastAutoSwitchMessage: String?
    @Published private(set) var autoSwitch: NetworkLocationAutoSwitchConfiguration
    @Published private(set) var currentSSID: String?
    @Published private(set) var ssidAuthorization: NetworkLocationSSIDAuthorization

    private let controller: NetworkLocationControlling
    private let store: NetworkLocationSettingsStore
    private let ssidMonitor: NetworkLocationSSIDMonitoring
    private let preferencesObserver: NetworkLocationPreferencesObserver?
    private let queue = DispatchQueue(label: "com.youtonghy.toolbox.network-location", qos: .userInitiated)
    private let logger = Logger(subsystem: "ToolBox", category: "NetworkLocation")
    private var started = false
    private var pendingOperations = 0
    /// Snapshots are stamped on the serial queue; older ones never overwrite newer ones.
    private var issuedSequence: UInt64 = 0
    private var appliedSequence: UInt64 = 0
    /// The SSID the auto-switch rules were last evaluated for. Rules run once
    /// per network arrival, so a manual switch on the same network sticks.
    private var evaluatedSSID: String?

    init(
        controller: NetworkLocationControlling = NetworkSetupLocationController(),
        store: NetworkLocationSettingsStore = NetworkLocationSettingsStore(),
        ssidMonitor: NetworkLocationSSIDMonitoring? = nil,
        preferencesObserver: NetworkLocationPreferencesObserver? = NetworkLocationPreferencesObserver()
    ) {
        let ssidMonitor = ssidMonitor ?? CoreWLANSSIDMonitor()
        self.controller = controller
        self.store = store
        self.ssidMonitor = ssidMonitor
        self.preferencesObserver = preferencesObserver
        autoSwitch = store.load()
        ssidAuthorization = ssidMonitor.authorization
    }

    func start() {
        guard !started else { return }
        started = true
        preferencesObserver?.onChange = { [weak self] in self?.refresh() }
        preferencesObserver?.start()
        ssidMonitor.onSSIDChange = { [weak self] ssid in self?.handleSSID(ssid) }
        ssidMonitor.onAuthorizationChange = { [weak self] authorization in
            self?.ssidAuthorization = authorization
        }
        refresh()
        updateSSIDMonitoring()
    }

    func stop() {
        guard started else { return }
        started = false
        preferencesObserver?.stop()
        preferencesObserver?.onChange = nil
        ssidMonitor.stop()
        ssidMonitor.onSSIDChange = nil
        ssidMonitor.onAuthorizationChange = nil
    }

    // MARK: - Locations

    func refresh() {
        Task { await perform(reportsErrors: false) { _ in () } }
    }

    func switchTo(_ name: String) {
        guard name != snapshot.current else { return }
        Task {
            await perform { controller in try controller.switchToLocation(named: name) }
        }
    }

    /// Returns whether the location now exists, so callers can clear input.
    @discardableResult
    func createLocation(named rawName: String) async -> Bool {
        let name: String
        do {
            name = try NetworkLocationName.normalized(rawName)
        } catch {
            report(error)
            return false
        }
        await perform { controller in
            try controller.createLocation(named: name, allowsAuthorizationPrompt: true)
        }
        return snapshot.locations.contains(name)
    }

    // MARK: - SSID auto switching

    func setAutoSwitchEnabled(_ enabled: Bool) {
        updateAutoSwitch { $0.isEnabled = enabled }
        if enabled, ssidAuthorization == .notDetermined {
            ssidMonitor.requestAuthorization()
        }
    }

    func requestSSIDAuthorization() {
        ssidMonitor.requestAuthorization()
    }

    /// Adds a rule, or re-targets the existing rule for the same SSID.
    func upsertRule(ssid rawSSID: String, location: String) throws {
        let ssid = rawSSID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ssid.isEmpty, !location.isEmpty else { throw NetworkLocationError.invalidRule }
        updateAutoSwitch { configuration in
            if let index = configuration.rules.firstIndex(where: { $0.ssid == ssid }) {
                configuration.rules[index].location = location
            } else {
                configuration.rules.append(NetworkLocationSSIDRule(ssid: ssid, location: location))
            }
        }
    }

    func removeRule(id: NetworkLocationSSIDRule.ID) {
        updateAutoSwitch { $0.rules.removeAll { $0.id == id } }
    }

    func setFallbackLocation(_ location: String?) {
        updateAutoSwitch { $0.fallbackLocation = location }
    }

    private func updateAutoSwitch(_ change: (inout NetworkLocationAutoSwitchConfiguration) -> Void) {
        var next = autoSwitch
        change(&next)
        guard next != autoSwitch else { return }
        do {
            try store.save(next)
        } catch {
            report(error)
            return
        }
        autoSwitch = next
        // Re-evaluate the current network against the edited rules.
        evaluatedSSID = nil
        updateSSIDMonitoring()
        if let currentSSID { handleSSID(currentSSID) }
    }

    private func updateSSIDMonitoring() {
        guard started else { return }
        if autoSwitch.isEnabled {
            ssidMonitor.start()
        } else {
            ssidMonitor.stop()
            currentSSID = nil
            evaluatedSSID = nil
        }
    }

    private func handleSSID(_ ssid: String?) {
        currentSSID = ssid
        guard autoSwitch.isEnabled, let ssid, ssid != evaluatedSSID else { return }
        evaluatedSSID = ssid
        let configuration = autoSwitch
        Task {
            let target: String?? = await perform { controller in
                let target = NetworkLocationAutoSwitchPolicy.targetLocation(
                    ssid: ssid,
                    configuration: configuration,
                    snapshot: try controller.snapshot()
                )
                if let target { try controller.switchToLocation(named: target) }
                return target
            }
            if case let .some(.some(target)) = target {
                lastAutoSwitchMessage = String(
                    format: L10n.string("已根据 Wi-Fi“%@”切换到“%@”"),
                    ssid,
                    target
                )
            }
        }
    }

    // MARK: - Serial execution

    /// Runs `work` and a follow-up snapshot on the serial queue. Returns the
    /// work result, or `nil` when it failed (the error is surfaced unless
    /// `reportsErrors` is false).
    @discardableResult
    private func perform<T: Sendable>(
        reportsErrors: Bool = true,
        _ work: @escaping @Sendable (NetworkLocationControlling) throws -> T
    ) async -> T? {
        pendingOperations += 1
        isBusy = true
        defer {
            pendingOperations -= 1
            isBusy = pendingOperations > 0
        }
        if reportsErrors { errorMessage = nil }

        let controller = controller
        let (result, snapshot, sequence) = await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                let result = Result { try work(controller) }
                let snapshot = Result { try controller.snapshot() }
                DispatchQueue.main.async {
                    continuation.resume(returning: (result, snapshot, self?.nextSequence() ?? 0))
                }
            }
        }

        if case let .success(snapshot) = snapshot, sequence > appliedSequence {
            appliedSequence = sequence
            self.snapshot = snapshot
        }
        switch result {
        case let .success(value):
            return value
        case let .failure(error):
            if reportsErrors { report(error) }
            logger.error("Network location operation failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func nextSequence() -> UInt64 {
        issuedSequence &+= 1
        return issuedSequence
    }

    private func report(_ error: Error) {
        if case NetworkLocationError.cancelled = error {
            errorMessage = nil
            return
        }
        errorMessage = error.localizedDescription
    }
}
