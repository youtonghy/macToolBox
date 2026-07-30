import CoreGraphics
import Foundation

struct DisplayHardwareIdentity: Hashable, Sendable {
    var vendorNumber: UInt32?
    var modelNumber: UInt32?
    var serialNumber: UInt32?
}

struct DisplayCapabilityCacheKey: Hashable, Sendable {
    var displayID: CGDirectDisplayID
    var hardwareIdentity: DisplayHardwareIdentity
    var backendName: String
    var connectionToken: UInt64
}

struct DisplayCapabilityStore {
    private var reports: [DisplayCapabilityCacheKey: DDCCapabilityReport] = [:]

    var count: Int {
        reports.count
    }

    mutating func report(for key: DisplayCapabilityCacheKey) -> DDCCapabilityReport? {
        invalidateOtherConnections(for: key)
        return reports[key]
    }

    mutating func record(
        _ report: DDCCapabilityReport,
        for key: DisplayCapabilityCacheKey
    ) {
        invalidateOtherConnections(for: key)
        reports[key] = report
    }

    mutating func retainConnections(_ keys: Set<DisplayCapabilityCacheKey>) {
        reports = reports.filter { keys.contains($0.key) }
    }

    mutating func invalidate(displayID: CGDirectDisplayID) {
        reports = reports.filter { $0.key.displayID != displayID }
    }

    private mutating func invalidateOtherConnections(for key: DisplayCapabilityCacheKey) {
        reports = reports.filter {
            $0.key.displayID != key.displayID || $0.key == key
        }
    }
}
