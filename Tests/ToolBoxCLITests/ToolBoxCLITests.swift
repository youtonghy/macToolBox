import XCTest
import ToolBoxControlProtocol

final class ToolBoxCLITests: XCTestCase {
    func testRequestAndResponseRoundTripPreservesCommandAndRequestID() throws {
        let request = ToolBoxControlRequestEnvelope(
            requestID: "test-request",
            request: .displaySet(ToolBoxDisplaySetRequestDTO(
                target: ToolBoxDisplayTargetDTO(displayID: 42),
                change: .brightness(65)
            ))
        )
        let encodedRequest = try ToolBoxControlJSONCodec.encodeRequest(request)
        XCTAssertEqual(try ToolBoxControlJSONCodec.decodeRequest(encodedRequest), request)

        let response = ToolBoxControlResponseEnvelope.success(
            requestID: request.requestID,
            result: .awake(ToolBoxToggleStateDTO(isEnabled: true))
        )
        let encodedResponse = try ToolBoxControlJSONCodec.encodeResponse(response)
        XCTAssertEqual(try ToolBoxControlJSONCodec.decodeResponse(encodedResponse), response)
    }

    func testEndpointMetadataRejectsWrongBundleIdentifier() {
        let metadata = ToolBoxEndpointMetadata(
            appVersion: "test",
            appProcessIdentifier: 1,
            socketPath: "/tmp/toolbox-test.sock",
            appBundleIdentifier: "foreign.bundle"
        )
        XCTAssertThrowsError(try metadata.validate())
    }
}
