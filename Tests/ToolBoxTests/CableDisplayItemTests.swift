import XCTest
@testable import ToolBox

final class CableDisplayItemTests: XCTestCase {
    func testVisibleCableItemsCapAndOverflowSubtitle() {
        let model = HardwareMenuModel()
        let items = (1...5).map { index in
            CableDisplayItem(
                id: UInt64(index),
                title: "USB-C Port \(index)",
                lines: ["line \(index)"],
                kind: .usbC,
                cableType: .passive
            )
        }

        model.setCableItemsForTesting(items)

        XCTAssertEqual(model.visibleCableItems.count, HardwareMenuLayout.maxCableItemCount)
        XCTAssertEqual(model.hiddenCableCount, 2)
        XCTAssertEqual(model.cableSectionSubtitle, "显示 3/5 条连接中的链路")
        XCTAssertEqual(
            model.cableListHeight,
            HardwareMenuLayout.cableListHeight(itemCount: HardwareMenuLayout.maxCableItemCount)
        )
    }

    func testCableDisplayKindClassifiesExistingPortSignals() {
        XCTAssertEqual(
            CableDisplayKind.classify(port: port(name: "MagSafe 3", type: "Power Port", hasPower: true)),
            .magSafe
        )
        XCTAssertEqual(
            CableDisplayKind.classify(port: port(name: "USB-C Port", displayActive: true)),
            .display
        )
        XCTAssertEqual(
            CableDisplayKind.classify(port: port(name: "USB-C Port", transportsActive: ["USB4"])),
            .thunderbolt
        )
        XCTAssertEqual(
            CableDisplayKind.classify(port: port(name: "Power Port", hasPower: true)),
            .power
        )
        XCTAssertEqual(
            CableDisplayKind.classify(port: port(name: "USB-C Port", dataActive: true)),
            .usbC
        )
        XCTAssertEqual(
            CableDisplayKind.classify(port: port(name: "Accessory")),
            .unknown
        )
    }

    private func port(
        id: UInt64 = 1,
        name: String,
        type: String? = nil,
        transportsActive: [String] = [],
        displayActive: Bool = false,
        dataActive: Bool = false,
        hasPower: Bool = false
    ) -> CablePortSnapshot {
        CablePortSnapshot(
            id: id,
            name: name,
            className: "IOPort",
            type: type,
            portNumber: nil,
            connectionActive: true,
            pdCapable: hasPower,
            transportsSupported: [],
            transportsActive: transportsActive,
            transportsProvisioned: [],
            plugOrientation: nil,
            cableIdentities: [],
            cableCapability: nil,
            powerNegotiation: hasPower
                ? PowerNegotiationSnapshot(
                    sourceName: nil,
                    options: [],
                    winningOption: PowerOptionSnapshot(
                        voltageMV: 20_000,
                        maxCurrentMA: 3_000,
                        maxPowerMW: 60_000
                    ),
                    negotiatedWatts: 60,
                    chargerWatts: 60,
                    cableMaxWatts: nil,
                    likelyBottleneck: PowerBottleneck.none
                )
                : nil,
            dataTransport: dataActive
                ? DataTransportSnapshot(
                    active: true,
                    usb3Signaling: nil,
                    usb3Description: nil,
                    controllerCableSpeedGbps: nil,
                    cableAdvertisedSpeedGbps: nil,
                    effectiveSpeedGbps: nil,
                    dataRole: nil,
                    transportRestricted: nil
                )
                : nil,
            displayTransport: displayActive
                ? DisplayTransportSnapshot(
                    active: true,
                    tunneled: nil,
                    laneCount: nil,
                    maxLaneCount: nil,
                    linkRate: nil,
                    linkRateDescription: nil,
                    estimatedPayloadGbps: nil,
                    hpdState: nil,
                    role: nil,
                    sinkCount: nil,
                    monitors: []
                )
                : nil,
            rawProperties: [:]
        )
    }
}
