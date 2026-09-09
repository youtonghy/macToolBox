import Foundation
import Testing
import ToolBoxControlProtocol

struct ImageCLIRegressionTests {
    @Test func largerOutputAndRetainedSourceAreRenderedAccurately() throws {
        let response = ToolBoxControlResponseEnvelope.success(requestID: "image-test", result: .imageProcess(
            ToolBoxImageProcessResultDTO(items: [
                ToolBoxImageOutcomeDTO(source: "/tmp/a.jpg", kind: .savedAs, target: "/tmp/a.png",
                                       originalBytes: 100, resultBytes: 300, outputFormat: "png",
                                       detail: "产物已保存，源文件未删除"),
            ], totalBytesSaved: -200)
        ))
        let rendered = ToolBoxCLIResponseRenderer().render(response, asJSON: false)
        #expect(rendered.standardOutput.contains("增加"))
        #expect(!rendered.standardOutput.contains("节省 -"))
        #expect(rendered.standardOutput.contains("源文件未删除"))
        #expect(!rendered.standardOutput.contains("源文件已删除"))
        let encoded = try ToolBoxControlJSONCodec.encodeResponse(response)
        #expect(try ToolBoxControlJSONCodec.decodeResponse(encoded) == response)
    }

    @Test func convertRequiresAnActualOutputFormat() throws {
        #expect(throws: (any Error).self) {
            try ToolBoxImageCommand.Convert.parse(["/tmp/a.jpg", "--format", "original"])
        }
        let command = try ToolBoxImageCommand.Compress.parse(["/tmp/a.jpg", "--format", "png"])
        #expect(command.format == "png")
    }
}
