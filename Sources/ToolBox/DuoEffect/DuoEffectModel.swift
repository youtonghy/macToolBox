import Combine
import Foundation

/// Owns Duo effect state shared by the coordinator and the settings UI.
@MainActor
final class DuoEffectModel: ObservableObject {
    @Published var statusText = "未启用"
    /// The user wants the effect on (it may still be suspended for sleep/lock).
    @Published private(set) var isActive = false
    @Published private(set) var calibrationMessage = ""
    /// Hinge angle at which the effect reaches zero, persisted across launches.
    @Published var openAngle: Double {
        didSet { defaults.set(openAngle, forKey: Self.openAngleKey) }
    }
    /// Frost strength used by the glass shader.
    @Published var frost: Double {
        didSet { defaults.set(frost, forKey: Self.frostKey) }
    }

    let sensor = LidAngleSensor()

    /// Wired by AppDelegate; runs the 8-second live preview in the coordinator.
    var onPreview: () -> Void = {}

    static let enabledKey = "feature.duoEffect.enabled"
    static let frostRange = 0.0...0.18
    private static let openAngleKey = "duoEffect.openAngle"
    private static let frostKey = "duoEffect.frost"
    private static let defaultOpenAngle = 120.0
    private static let defaultFrost = 0.09

    private let defaults: UserDefaults
    private var settingsVisible = false

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let savedAngle = defaults.object(forKey: Self.openAngleKey) as? Double ?? Self.defaultOpenAngle
        openAngle = (1...180).contains(savedAngle) ? savedAngle : Self.defaultOpenAngle
        let savedFrost = defaults.object(forKey: Self.frostKey) as? Double ?? Self.defaultFrost
        frost = Self.frostRange.contains(savedFrost) ? savedFrost : Self.defaultFrost
    }

    /// Saves the current hinge angle as the fully-open endpoint.
    @discardableResult
    func saveOpenAngle() -> Bool {
        guard sensor.isAvailable else {
            calibrationMessage = "等待铰链数据…"
            return false
        }
        let value = sensor.angle
        guard value.isFinite, (1...180).contains(value) else {
            calibrationMessage = "角度数据无效，请打开屏幕后重试"
            return false
        }
        openAngle = value
        calibrationMessage = "已保存展开终点 \(Int(value.rounded()))°"
        return true
    }

    /// The settings tab keeps the sensor alive so the live angle and
    /// calibration work before the effect itself is enabled.
    func setSettingsVisible(_ visible: Bool) {
        settingsVisible = visible
        updateSensorPolling()
    }

    func setActive(_ active: Bool) {
        isActive = active
        updateSensorPolling()
    }

    private func updateSensorPolling() {
        if isActive || settingsVisible {
            sensor.start()
        } else {
            sensor.stop()
        }
    }
}
