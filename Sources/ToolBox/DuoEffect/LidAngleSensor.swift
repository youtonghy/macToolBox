import Foundation
import IOKit.hid
import QuartzCore

/// Reads the undocumented lid-angle HID device used by newer MacBooks.
/// Kept separate from the visual layer so a public API can replace it later.
/// Ported from https://github.com/jlxc2001/MacBook-Duo.
@MainActor
final class LidAngleSensor: ObservableObject {
    @Published private(set) var angle = 105.0
    private(set) var lastSuccessfulUpdate = Date.distantPast
    @Published private(set) var velocity = 0.0
    /// A readable HID device was found; polling may still be off.
    @Published private(set) var isSupported = false
    /// The device is open and the poll timer is running.
    @Published private(set) var isAvailable = false
    @Published private(set) var statusText = "正在查找铰链传感器…"

    private var manager: IOHIDManager?
    private var device: IOHIDDevice?
    private var deviceOpen = false
    private var timer: Timer?
    private var report = [UInt8](repeating: 0, count: 8)
    private var lastAngle = 105.0
    private var lastTime = CACurrentMediaTime()
    private var filteredVelocity = 0.0
    private let noOptions = IOOptionBits(kIOHIDOptionsTypeNone)

    init() {
        discoverDevice()
    }

    deinit {
        timer?.invalidate()
        if let device {
            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        if let manager {
            IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        }
    }

    func start() {
        guard timer == nil else { return }
        if device == nil {
            discoverDevice()
        }
        guard let device else {
            isAvailable = false
            statusText = "此设备不支持铰链传感器"
            return
        }

        if !deviceOpen {
            guard IOHIDDeviceOpen(device, noOptions) == kIOReturnSuccess else {
                isAvailable = false
                statusText = "传感器无法打开"
                return
            }
            deviceOpen = true
        }

        isAvailable = true
        statusText = "此设备支持铰链传感器"
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        poll()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        if let device, deviceOpen {
            IOHIDDeviceClose(device, noOptions)
            deviceOpen = false
        }
        isAvailable = false
    }

    private func discoverDevice() {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, noOptions)
        self.manager = manager

        guard IOHIDManagerOpen(manager, noOptions) == kIOReturnSuccess else {
            statusText = "HID 服务不可用"
            return
        }

        let matchStrategies: [[String: Any]] = [
            [
                kIOHIDVendorIDKey as String: 0x05AC,
                kIOHIDProductIDKey as String: 0x8104,
                kIOHIDDeviceUsagePageKey as String: 0x0020,
                kIOHIDDeviceUsageKey as String: 0x008A
            ],
            [
                kIOHIDVendorIDKey as String: 0x05AC,
                kIOHIDDeviceUsagePageKey as String: 0x0020,
                kIOHIDDeviceUsageKey as String: 0x008A
            ],
            [
                kIOHIDDeviceUsagePageKey as String: 0x0020,
                kIOHIDDeviceUsageKey as String: 0x008A
            ]
        ]

        for matching in matchStrategies {
            IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)
            guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else {
                continue
            }
            for candidate in devices where canRead(candidate) {
                device = candidate
                isSupported = true
                statusText = "此设备支持铰链传感器"
                return
            }
        }

        isSupported = false
        statusText = "此设备不支持铰链传感器"
    }

    private func canRead(_ candidate: IOHIDDevice) -> Bool {
        guard IOHIDDeviceOpen(candidate, noOptions) == kIOReturnSuccess else { return false }
        defer { IOHIDDeviceClose(candidate, noOptions) }

        var probe = [UInt8](repeating: 0, count: 8)
        var length = CFIndex(probe.count)
        let result = IOHIDDeviceGetReport(
            candidate,
            kIOHIDReportTypeFeature,
            1,
            &probe,
            &length
        )
        return result == kIOReturnSuccess && length >= 3
    }

    private func poll() {
        guard let device, deviceOpen else { return }
        var length = CFIndex(report.count)
        let result = IOHIDDeviceGetReport(
            device,
            kIOHIDReportTypeFeature,
            1,
            &report,
            &length
        )

        guard result == kIOReturnSuccess,
              let measured = Self.decodeAngle(report: report, reportLength: Int(length))
        else { return }

        let now = CACurrentMediaTime()
        let deltaTime = max(now - lastTime, 1.0 / 120.0)
        let instantVelocity = (measured - lastAngle) / deltaTime
        filteredVelocity = filteredVelocity * 0.72 + instantVelocity * 0.28

        angle = measured
        lastSuccessfulUpdate = Date()
        velocity = filteredVelocity
        lastAngle = measured
        lastTime = now
    }

    /// Feature report layout: report[0] is the report ID, the angle is
    /// little-endian in report[1...2]. A small number of implementations
    /// expose hundredths of a degree.
    nonisolated static func decodeAngle(report: [UInt8], reportLength: Int) -> Double? {
        guard reportLength >= 3, report.count >= 3 else { return nil }
        let rawValue = UInt16(report[2]) << 8 | UInt16(report[1])
        var measured = Double(rawValue)
        if measured > 360 { measured /= 100.0 }
        guard measured.isFinite, measured >= 0, measured <= 180 else { return nil }
        return measured
    }
}
