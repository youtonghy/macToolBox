import CoreGraphics
import XCTest
@testable import ToolBoxCore

final class DDCBackendMatchingTests: XCTestCase {
    // MARK: - Arm64 assignment ambiguity

    private func candidate(
        displayID: CGDirectDisplayID,
        serviceLocation: Int,
        score: Int
    ) -> Arm64DDCServiceMatch {
        Arm64DDCServiceMatch(
            displayID: displayID,
            service: nil,
            connectionToken: nil,
            serviceLocation: serviceLocation,
            discouraged: false,
            dummy: false,
            matchScore: score
        )
    }

    func testIdenticalSerialLessDisplaysFailClosed() {
        // Two identical monitors: every display scores the same against every
        // service (no serial/location disambiguation). Neither may be bound,
        // because an arbitrary binding risks writing to the wrong screen.
        let candidates = [
            candidate(displayID: 1, serviceLocation: 10, score: 12),
            candidate(displayID: 1, serviceLocation: 11, score: 12),
            candidate(displayID: 2, serviceLocation: 10, score: 12),
            candidate(displayID: 2, serviceLocation: 11, score: 12),
        ]

        let resolution = Arm64DDCBackend.resolveAssignments(candidates: candidates)

        XCTAssertTrue(resolution.ambiguousDisplayIDs == [1, 2])
        XCTAssertTrue(resolution.matches.isEmpty)
    }

    func testDistinctDisplaysWithUniqueArgMaxAreAssigned() {
        // Distinct serials make each display strictly prefer its own service.
        let candidates = [
            candidate(displayID: 1, serviceLocation: 10, score: 13),
            candidate(displayID: 1, serviceLocation: 11, score: 12),
            candidate(displayID: 2, serviceLocation: 10, score: 12),
            candidate(displayID: 2, serviceLocation: 11, score: 13),
        ]

        let resolution = Arm64DDCBackend.resolveAssignments(candidates: candidates)

        XCTAssertTrue(resolution.ambiguousDisplayIDs.isEmpty)
        let bindings = resolution.matches
            .map { "\($0.displayID):\($0.serviceLocation)" }
            .sorted()
        XCTAssertEqual(bindings, ["1:10", "2:11"])
    }

    func testIndifferentDisplayFailsClosedWhileDistinctivePeerIsAssigned() {
        // Display 1 ties between both services; it must fail closed even
        // though a maximum-total assignment would have been derivable.
        let candidates = [
            candidate(displayID: 1, serviceLocation: 10, score: 12),
            candidate(displayID: 1, serviceLocation: 11, score: 12),
            candidate(displayID: 2, serviceLocation: 10, score: 5),
            candidate(displayID: 2, serviceLocation: 11, score: 12),
        ]

        let resolution = Arm64DDCBackend.resolveAssignments(candidates: candidates)

        XCTAssertTrue(resolution.ambiguousDisplayIDs == [1])
        let bindings = resolution.matches
            .map { "\($0.displayID):\($0.serviceLocation)" }
        XCTAssertEqual(bindings, ["2:11"])
    }

    func testSingleDisplayWithUniqueHighScoreIsAssigned() {
        let candidates = [
            candidate(displayID: 7, serviceLocation: 3, score: 15),
            candidate(displayID: 7, serviceLocation: 4, score: 1),
        ]

        let resolution = Arm64DDCBackend.resolveAssignments(candidates: candidates)

        XCTAssertTrue(resolution.ambiguousDisplayIDs.isEmpty)
        XCTAssertEqual(resolution.matches.map(\.serviceLocation), [3])
    }

    func testSingleDisplayTiedAcrossServicesFailsClosed() {
        // One visible display, two identical monitor services (e.g. a dummy
        // plug + real screen): writing to an arbitrary one is unsafe.
        let candidates = [
            candidate(displayID: 7, serviceLocation: 3, score: 15),
            candidate(displayID: 7, serviceLocation: 4, score: 15),
        ]

        let resolution = Arm64DDCBackend.resolveAssignments(candidates: candidates)

        XCTAssertTrue(resolution.ambiguousDisplayIDs == [7])
        XCTAssertTrue(resolution.matches.isEmpty)
    }

    func testUnmatchedDisplaysAreNotAmbiguous() {
        let candidates = [
            candidate(displayID: 1, serviceLocation: 10, score: 0),
            candidate(displayID: 1, serviceLocation: 11, score: 0),
        ]

        let resolution = Arm64DDCBackend.resolveAssignments(candidates: candidates)

        XCTAssertTrue(resolution.ambiguousDisplayIDs.isEmpty)
        XCTAssertTrue(resolution.matches.isEmpty)
    }

    // MARK: - Intel framebuffer fallback ambiguity

    func testIntelSelectUnambiguousFramebufferAcceptsUniqueCandidate() {
        let candidate = IntelDDCBackend.IntelFramebufferCandidate(
            port: 42, vendor: 0x10AE, product: 0xCF07, serial: 0
        )
        XCTAssertEqual(
            IntelDDCBackend.selectUnambiguousFramebuffer([candidate], displayID: 5),
            42
        )
    }

    func testIntelSelectUnambiguousFramebufferAcceptsNoCandidate() {
        XCTAssertNil(
            IntelDDCBackend.selectUnambiguousFramebuffer([], displayID: 5)
        )
    }

    func testIntelSelectUnambiguousFramebufferFailsClosedOnIdenticalCandidates() {
        // Two identical serial-less monitors match on vendor/product/serial=0.
        let candidates = [
            IntelDDCBackend.IntelFramebufferCandidate(port: 42, vendor: 0x10AE, product: 0xCF07, serial: 0),
            IntelDDCBackend.IntelFramebufferCandidate(port: 43, vendor: 0x10AE, product: 0xCF07, serial: 0),
        ]
        XCTAssertNil(
            IntelDDCBackend.selectUnambiguousFramebuffer(candidates, displayID: 5)
        )
    }
}
