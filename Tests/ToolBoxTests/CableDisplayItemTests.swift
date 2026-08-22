import XCTest
@testable import ToolBoxCore

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

    func testCableRegistryJoinRejectsDifferentControllersOnTheSamePort() {
        let lhs = CableRegistryJoin(
            hpmUUID: "00000000-0000-0000-0000-000000000001",
            portType: 2,
            portNumber: 1
        )
        let rhs = CableRegistryJoin(
            hpmUUID: "00000000-0000-0000-0000-000000000002",
            portType: 2,
            portNumber: 1
        )

        XCTAssertFalse(lhs.matches(rhs))
    }

    func testCableRegistryJoinRejectsDifferentPortsOnTheSameController() {
        let lhs = CableRegistryJoin(
            hpmUUID: "00000000-0000-0000-0000-000000000001",
            portType: 2,
            portNumber: 1
        )
        let rhs = CableRegistryJoin(
            hpmUUID: "00000000-0000-0000-0000-000000000001",
            portType: 2,
            portNumber: 2
        )

        XCTAssertFalse(lhs.matches(rhs))
    }

    func testCableRegistryJoinRejectsMissingPortNumbers() {
        let lhs = CableRegistryJoin(hpmUUID: nil, portType: 2, portNumber: nil)
        let rhs = CableRegistryJoin(hpmUUID: nil, portType: 2, portNumber: nil)

        XCTAssertFalse(lhs.matches(rhs))
    }

    func testCableRegistryJoinAllowsOneMissingControllerUUIDForTheSamePort() {
        let lhs = CableRegistryJoin(
            hpmUUID: "00000000-0000-0000-0000-000000000001",
            portType: 2,
            portNumber: 1
        )
        let rhs = CableRegistryJoin(hpmUUID: nil, portType: 2, portNumber: 1)

        XCTAssertTrue(lhs.matches(rhs))
    }

    func testCableRegistryJoinAllowsUnknownPortTypeOnTheSameControllerAndPort() {
        let lhs = CableRegistryJoin(
            hpmUUID: "00000000-0000-0000-0000-000000000001",
            portType: 2,
            portNumber: 1
        )
        let rhs = CableRegistryJoin(
            hpmUUID: "00000000000000000000000000000001",
            portType: 0,
            portNumber: 1
        )

        XCTAssertTrue(lhs.matches(rhs))
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
