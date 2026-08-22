import XCTest
@testable import ToolBoxCore

final class WiFiSignalModelTests: XCTestCase {
    func testConnectedSnapshotCalculatesSNRAndQualityBoundaries() {
        XCTAssertEqual(connectedSnapshot(rssi: -80, noise: -90).snr, 10)
        XCTAssertEqual(connectedSnapshot(rssi: -80, noise: -90).quality, .veryPoor)
        XCTAssertEqual(connectedSnapshot(rssi: -75, noise: -86).quality, .poor)
        XCTAssertEqual(connectedSnapshot(rssi: -70, noise: -86).quality, .fair)
        XCTAssertEqual(connectedSnapshot(rssi: -60, noise: -86).quality, .good)
        XCTAssertEqual(connectedSnapshot(rssi: -49, noise: -90).quality, .excellent)
    }

    func testZeroMeasurementsAreUnavailable() {
        let snapshot = connectedSnapshot(rssi: 0, noise: 0, transmitRate: 0)

        XCTAssertEqual(snapshot.state, .connected)
        XCTAssertNil(snapshot.rssi)
        XCTAssertNil(snapshot.noise)
        XCTAssertNil(snapshot.snr)
        XCTAssertNil(snapshot.transmitRate)
        XCTAssertNil(snapshot.quality)
    }

    func testChannelWidthUsesMHzInsteadOfRawEnumValue() {
        XCTAssertEqual(WiFiChannelWidth.mhz20.displayText, "20 MHz")
        XCTAssertEqual(WiFiChannelWidth.mhz40.displayText, "40 MHz")
        XCTAssertEqual(WiFiChannelWidth.mhz80.displayText, "80 MHz")
        XCTAssertEqual(WiFiChannelWidth.mhz160.displayText, "160 MHz")
        XCTAssertEqual(WiFiChannelWidth.unknown.displayText, "系统未提供")
    }

    @MainActor
    func testModelKeepsOnlyFiveMinutesOfConnectedHistory() {
        let provider = ManualWiFiProvider()
        let model = WiFiSignalModel(provider: provider)
        let base = Date(timeIntervalSince1970: 10_000)

        model.start()
        provider.publish(connectedSnapshot(timestamp: base, rssi: -60, noise: -90))
        provider.publish(connectedSnapshot(timestamp: base.addingTimeInterval(299), rssi: -61, noise: -90))
        provider.publish(connectedSnapshot(timestamp: base.addingTimeInterval(301), rssi: -62, noise: -90))

        XCTAssertEqual(model.history.map(\.rssi), [-61, -62])
        model.stop()
    }

    @MainActor
    func testStoppedAndPreviousSessionCallbacksCannotUpdateModel() {
        let provider = ManualWiFiProvider()
        let model = WiFiSignalModel(provider: provider)
        let initial = model.snapshot

        model.start()
        let oldCallback = provider.onUpdate
        model.stop()
        oldCallback?(connectedSnapshot(rssi: -70, noise: -90))
        XCTAssertEqual(model.snapshot, initial)

        model.start()
        let currentCallback = provider.onUpdate
        oldCallback?(connectedSnapshot(rssi: -80, noise: -90))
        currentCallback?(connectedSnapshot(rssi: -55, noise: -90))

        XCTAssertEqual(model.snapshot.rssi, -55)
        XCTAssertEqual(model.history.map(\.rssi), [-55])
        model.stop()
    }

    private func connectedSnapshot(
        timestamp: Date = Date(timeIntervalSince1970: 1),
        rssi: Int,
        noise: Int,
        transmitRate: Double = 866
    ) -> WiFiSnapshot {
        WiFiSnapshot.connected(
            timestamp: timestamp,
            interfaceName: "en0",
            ssid: "Studio",
            bssid: "00:11:22:33:44:55",
            rssi: rssi,
            noise: noise,
            transmitRate: transmitRate,
            channelNumber: 149,
            band: .ghz5,
            channelWidth: .mhz80,
            phyMode: "802.11ax",
            security: "WPA3 Personal"
        )
    }
}

private final class ManualWiFiProvider: WiFiSnapshotProviding {
    var onUpdate: (@MainActor (WiFiSnapshot) -> Void)?

    func start(interval: TimeInterval) {}
    func stop() { onUpdate = nil }

    @MainActor
    func publish(_ snapshot: WiFiSnapshot) {
        onUpdate?(snapshot)
    }
}
