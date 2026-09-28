import CoreLocation
import CoreWLAN
import Foundation
import OSLog
import SystemConfiguration

enum NetworkLocationSSIDAuthorization: Equatable {
    case notDetermined
    case denied
    case authorized
}

protocol NetworkLocationSSIDMonitoring: AnyObject {
    var onSSIDChange: (@MainActor (String?) -> Void)? { get set }
    var onAuthorizationChange: (@MainActor (NetworkLocationSSIDAuthorization) -> Void)? { get set }
    var authorization: NetworkLocationSSIDAuthorization { get }
    func requestAuthorization()
    func start()
    func stop()
}

/// Reports the current Wi-Fi SSID. Since macOS 14 CoreWLAN only returns the
/// SSID to apps with Location Services authorization, so the monitor also owns
/// that permission. SSID changes arrive through CoreWLAN events; a slow poll
/// covers events CoreWLAN drops (for example around sleep/wake).
///
/// Must be created and used on the main thread.
final class CoreWLANSSIDMonitor: NSObject, NetworkLocationSSIDMonitoring {
    var onSSIDChange: (@MainActor (String?) -> Void)?
    var onAuthorizationChange: (@MainActor (NetworkLocationSSIDAuthorization) -> Void)?

    private let client = CWWiFiClient()
    private let locationManager = CLLocationManager()
    private let queue = DispatchQueue(label: "com.youtonghy.toolbox.network-location.ssid", qos: .utility)
    private let pollInterval: TimeInterval
    private let logger = Logger(subsystem: "ToolBox", category: "NetworkLocation")
    private var timer: DispatchSourceTimer?
    private var isRunning = false

    init(pollInterval: TimeInterval = 30) {
        self.pollInterval = pollInterval
        super.init()
        locationManager.delegate = self
    }

    var authorization: NetworkLocationSSIDAuthorization {
        switch locationManager.authorizationStatus {
        case .notDetermined:
            return .notDetermined
        case .authorizedAlways, .authorizedWhenInUse:
            return .authorized
        case .denied, .restricted:
            return .denied
        @unknown default:
            return .denied
        }
    }

    func requestAuthorization() {
        locationManager.requestWhenInUseAuthorization()
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        client.delegate = self
        for event in [CWEventType.ssidDidChange, .linkDidChange, .powerDidChange] {
            do {
                try client.startMonitoringEvent(with: event)
            } catch {
                logger.error("CoreWLAN event monitoring failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: max(5, pollInterval), leeway: .seconds(2))
        timer.setEventHandler { [weak self] in self?.readSSID() }
        self.timer = timer
        timer.resume()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        do {
            try client.stopMonitoringAllEvents()
        } catch {
            logger.error("CoreWLAN event monitoring stop failed: \(error.localizedDescription, privacy: .public)")
        }
        client.delegate = nil
        timer?.cancel()
        timer = nil
    }

    private func scheduleRead() {
        queue.async { [weak self] in self?.readSSID() }
    }

    private func readSSID() {
        let ssid = client.interface()?.ssid()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isRunning else { return }
            self.onSSIDChange?(ssid)
        }
    }

    deinit {
        timer?.cancel()
    }
}

extension CoreWLANSSIDMonitor: CWEventDelegate {
    func ssidDidChangeForWiFiInterface(withName interfaceName: String) {
        scheduleRead()
    }

    func linkDidChangeForWiFiInterface(withName interfaceName: String) {
        scheduleRead()
    }

    func powerStateDidChangeForWiFiInterface(withName interfaceName: String) {
        scheduleRead()
    }
}

extension CoreWLANSSIDMonitor: CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let authorization = self.authorization
        DispatchQueue.main.async { [weak self] in
            self?.onAuthorizationChange?(authorization)
        }
        // A fresh grant makes the SSID readable immediately.
        if isRunning { scheduleRead() }
    }
}

/// Fires whenever the system network configuration is committed or applied,
/// which covers location switches and edits made in System Settings or by
/// `networksetup` itself. Must be used on the main thread.
final class NetworkLocationPreferencesObserver {
    var onChange: (() -> Void)?

    private var preferences: SCPreferences?
    private let logger = Logger(subsystem: "ToolBox", category: "NetworkLocation")

    func start() {
        guard preferences == nil else { return }
        guard let preferences = SCPreferencesCreate(nil, "ToolBox.NetworkLocation" as CFString, nil) else {
            logger.error("SCPreferencesCreate failed: \(String(cString: SCErrorString(SCError())), privacy: .public)")
            return
        }
        var context = SCPreferencesContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: SCPreferencesCallBack = { _, _, info in
            guard let info else { return }
            let observer = Unmanaged<NetworkLocationPreferencesObserver>.fromOpaque(info).takeUnretainedValue()
            observer.onChange?()
        }
        guard SCPreferencesSetCallback(preferences, callback, &context),
              SCPreferencesScheduleWithRunLoop(
                  preferences,
                  CFRunLoopGetMain(),
                  CFRunLoopMode.commonModes.rawValue
              ) else {
            SCPreferencesSetCallback(preferences, nil, nil)
            logger.error("Network preferences observation failed: \(String(cString: SCErrorString(SCError())), privacy: .public)")
            return
        }
        self.preferences = preferences
    }

    func stop() {
        guard let preferences else { return }
        SCPreferencesUnscheduleFromRunLoop(preferences, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        SCPreferencesSetCallback(preferences, nil, nil)
        self.preferences = nil
    }

    deinit {
        stop()
    }
}
