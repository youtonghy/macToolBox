import XCTest
@testable import ToolBox

final class AudioRouteRecoveryPolicyTests: XCTestCase {
    func testRetriesUseBoundedBackoffThenFailClosed() {
        var policy = AudioRouteRecoveryPolicy()

        XCTAssertEqual(policy.action(for: "A", reason: .callbackStall, now: time(0)), .retry(after: .milliseconds(250)))
        XCTAssertEqual(policy.action(for: "A", reason: .callbackStall, now: time(1)), .retry(after: .seconds(1)))
        XCTAssertEqual(policy.action(for: "A", reason: .callbackStall, now: time(2)), .retry(after: .seconds(4)))
        XCTAssertEqual(policy.action(for: "A", reason: .callbackStall, now: time(3)), .failClosed)
    }

    func testExhaustedBudgetDoesNotResetWhenTimePasses() {
        var policy = exhaustedPolicy()

        XCTAssertEqual(
            policy.action(for: "A", reason: .callbackStall, now: time(120)),
            .failClosed
        )
    }

    func testExplicitRecoveryCausesResetExhaustedBudget() {
        for cause in [
            AudioRouteRecoveryResetCause.userIntent,
            .halFingerprint,
            .audioServerGeneration
        ] {
            var policy = exhaustedPolicy()
            policy.reset(routeID: "A", cause: cause)

            XCTAssertEqual(
                policy.action(for: "A", reason: .callbackStall, now: time(120)),
                .retry(after: .milliseconds(250))
            )
        }
    }

    func testRetryBudgetsAreIndependentPerRoute() {
        var policy = exhaustedPolicy()

        XCTAssertEqual(
            policy.action(for: "B", reason: .ringOverload, now: time(4)),
            .retry(after: .milliseconds(250))
        )
    }

    func testUnexhaustedBudgetStartsANewWindowAfterThirtySeconds() {
        var policy = AudioRouteRecoveryPolicy()
        XCTAssertEqual(
            policy.action(for: "A", reason: .callbackStall, now: time(0)),
            .retry(after: .milliseconds(250))
        )

        XCTAssertEqual(
            policy.action(for: "A", reason: .callbackStall, now: time(31)),
            .retry(after: .milliseconds(250))
        )
    }

    private func exhaustedPolicy() -> AudioRouteRecoveryPolicy {
        var policy = AudioRouteRecoveryPolicy()
        _ = policy.action(for: "A", reason: .callbackStall, now: time(0))
        _ = policy.action(for: "A", reason: .callbackStall, now: time(1))
        _ = policy.action(for: "A", reason: .callbackStall, now: time(2))
        _ = policy.action(for: "A", reason: .callbackStall, now: time(3))
        return policy
    }

    private func time(_ seconds: UInt64) -> AudioRouteMonotonicTime {
        AudioRouteMonotonicTime(uptimeNanoseconds: seconds * 1_000_000_000)
    }
}
