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

// MARK: - 图像命令契约（审计修复回归）

extension ToolBoxCLITests {
    /// --no-recursive 必须是 @Flag：裸用（不带值）应合法解析。
    func testImageCompressParsesBareNoRecursiveFlag() throws {
        var command = try ToolBoxImageCommand.Compress.parse([
            "/tmp/some-image.jpg", "--no-recursive",
        ])
        XCTAssertTrue(command.noRecursive)
        command.noRecursive = false // silence unused-mutating warning
        XCTAssertFalse(command.noRecursive)
    }

    func testImageRehashParsesBareNoRecursiveFlag() throws {
        let command = try ToolBoxImageCommand.Rehash.parse([
            "/tmp/some-image.jpg", "--no-recursive",
        ])
        XCTAssertTrue(command.noRecursive)
    }

    func testImageCompressRejectsInvalidLevel() {
        XCTAssertThrowsError(try ToolBoxImageCommand.Compress.parse([
            "/tmp/a.jpg", "--level", "9",
        ]))
    }

    /// 全部项失败时退出码必须非零（便于脚本感知）。
    func testImageBatchAllFailedYieldsFailureExitStatus() throws {
        let renderer = ToolBoxCLIResponseRenderer()
        let allFailed = ToolBoxControlResponseEnvelope.success(
            requestID: "t",
            result: .imageProcess(ToolBoxImageProcessResultDTO(
                items: [
                    ToolBoxImageOutcomeDTO(source: "/tmp/a.jpg", kind: .failed, detail: "x"),
                    ToolBoxImageOutcomeDTO(source: "/tmp/b.jpg", kind: .unsupported, detail: "y"),
                ],
                totalBytesSaved: 0
            ))
        )
        XCTAssertEqual(renderer.render(allFailed, asJSON: false).exitStatus, ToolBoxCLIExitStatus.failure)

        let partialSuccess = ToolBoxControlResponseEnvelope.success(
            requestID: "t",
            result: .imageProcess(ToolBoxImageProcessResultDTO(
                items: [
                    ToolBoxImageOutcomeDTO(
                        source: "/tmp/a.jpg", kind: .replaced,
                        originalBytes: 100, resultBytes: 50, outputFormat: "jpeg"
                    ),
                    ToolBoxImageOutcomeDTO(source: "/tmp/b.jpg", kind: .failed, detail: "y"),
                ],
                totalBytesSaved: 50
            ))
        )
        XCTAssertEqual(renderer.render(partialSuccess, asJSON: false).exitStatus, ToolBoxCLIExitStatus.success)
    }

    /// 截断信息应体现在渲染输出中。
    func testImageBatchRendersTruncationNotice() throws {
        let renderer = ToolBoxCLIResponseRenderer()
        let response = ToolBoxControlResponseEnvelope.success(
            requestID: "t",
            result: .imageProcess(ToolBoxImageProcessResultDTO(
                items: [],
                totalBytesSaved: 0,
                truncatedItemCount: 900
            ))
        )
        let rendered = renderer.render(response, asJSON: false)
        XCTAssertTrue(rendered.standardOutput.contains("已截断"))
    }
}

extension ToolBoxCLITests {
    private func makeControlDTO(
        kind: ToolBoxDisplayControlKind,
        minimum: Int?,
        maximum: Int?,
        current: String?,
        readable: Bool = true
    ) -> ToolBoxDisplayControlDTO {
        ToolBoxDisplayControlDTO(
            kind: kind,
            minimum: minimum,
            maximum: maximum,
            currentValue: current,
            isReadable: readable,
            isWritable: true
        )
    }

    /// Mirrors the server quantization (step = 1/(max-min)): a 20...30 range
    /// maps a 53% request to 50%, so a readback of 50 confirms while 53 is
    /// still pending.
    func testReadbackVerdictUsesRawMinimumInQuantization() throws {
        let dto = ToolBoxDisplayDTO(
            displayID: 42,
            name: "Test",
            isBuiltIn: false,
            controls: [
                makeControlDTO(kind: .brightness, minimum: 20, maximum: 30, current: "50"),
                makeControlDTO(kind: .contrast, minimum: 20, maximum: 30, current: "53"),
            ]
        )

        guard case .confirmed = ToolBoxDisplayCommand.Set.readbackVerdict(for: dto, change: .brightness(53)) else {
            XCTFail("Expected 50 to confirm a 53% target on a 20...30 range")
            return
        }

        // 53 displayed on a 20...30 range means the write has not landed on
        // the quantized expectation yet: keep polling (nil), not confirmed.
        if case .confirmed = ToolBoxDisplayCommand.Set.readbackVerdict(for: dto, change: .contrast(53)) {
            XCTFail("53 must not confirm while the quantized expectation is 50")
        }
    }

    func testReadbackVerdictRejectsUnreadableControl() throws {
        let dto = ToolBoxDisplayDTO(
            displayID: 42,
            name: "Test",
            isBuiltIn: false,
            controls: [
                makeControlDTO(kind: .brightness, minimum: 0, maximum: 100, current: "50", readable: false),
            ]
        )
        guard case .unconfirmed = ToolBoxDisplayCommand.Set.readbackVerdict(for: dto, change: .brightness(50)) else {
            XCTFail("Expected write-only control to be unconfirmed")
            return
        }
    }
}
