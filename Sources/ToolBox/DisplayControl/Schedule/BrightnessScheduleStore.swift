import Foundation
import OSLog

enum BrightnessScheduleConfigurationIssue: Equatable, Sendable {
    case corruptData
    case unknownSchema(Int)
    case invalidSchedule

    var message: String {
        switch self {
        case .corruptData:
            return "已保存的日程数据无法读取，已保持关闭。"
        case let .unknownSchema(version):
            return "不支持的日程版本 \(version)，已保持关闭。"
        case .invalidSchedule:
            return "已保存的日程无效，已保持关闭。"
        }
    }
}

struct BrightnessScheduleLoadResult: Equatable, Sendable {
    var configuration: BrightnessScheduleConfiguration
    var issue: BrightnessScheduleConfigurationIssue?
}

/// Versioned UserDefaults persistence for brightness schedules.
struct BrightnessScheduleStore {
    static let defaultKey = "display.brightnessSchedule.v1"

    private let defaults: UserDefaults
    private let key: String
    private let logger = Logger(subsystem: "ToolBox", category: "BrightnessScheduleStore")
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(defaults: UserDefaults = .standard, key: String = BrightnessScheduleStore.defaultKey) {
        self.defaults = defaults
        self.key = key
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        decoder = JSONDecoder()
    }

    func load() -> BrightnessScheduleLoadResult {
        guard let data = defaults.data(forKey: key) else {
            return BrightnessScheduleLoadResult(
                configuration: .disabledDefault,
                issue: nil
            )
        }

        do {
            let document = try decoder.decode(BrightnessScheduleDocumentV1.self, from: data)
            guard document.schemaVersion == 1 else {
                logger.error("Unknown brightness schedule schema \(document.schemaVersion, privacy: .public)")
                return BrightnessScheduleLoadResult(
                    configuration: .disabledDefault,
                    issue: .unknownSchema(document.schemaVersion)
                )
            }
            let schedule = try BrightnessSchedule(validating: document.segments)
            return BrightnessScheduleLoadResult(
                configuration: BrightnessScheduleConfiguration(
                    isEnabled: document.isEnabled,
                    schedule: schedule
                ),
                issue: nil
            )
        } catch is DecodingError {
            logger.error("Corrupt brightness schedule payload")
            return BrightnessScheduleLoadResult(
                configuration: .disabledDefault,
                issue: .corruptData
            )
        } catch {
            logger.error("Invalid brightness schedule: \(error.localizedDescription, privacy: .public)")
            return BrightnessScheduleLoadResult(
                configuration: .disabledDefault,
                issue: .invalidSchedule
            )
        }
    }

    func save(_ configuration: BrightnessScheduleConfiguration) throws {
        let document = BrightnessScheduleDocumentV1(
            schemaVersion: 1,
            isEnabled: configuration.isEnabled,
            segments: configuration.schedule.segments
        )
        let data = try encoder.encode(document)
        defaults.set(data, forKey: key)
    }

    /// Test helper: remove the stored blob without writing a replacement.
    func remove() {
        defaults.removeObject(forKey: key)
    }
}

private struct BrightnessScheduleDocumentV1: Codable, Equatable {
    var schemaVersion: Int
    var isEnabled: Bool
    var segments: [BrightnessScheduleSegment]
}
