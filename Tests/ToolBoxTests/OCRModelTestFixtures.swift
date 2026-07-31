import Foundation
@testable import ToolBox

func makeOCRManifest(files: [OCRModelFileManifest]? = nil) throws -> OCRModelManifest {
    OCRModelManifest(
        id: "ppocrv6-tiny",
        pipeline: .ppOCRv6,
        profile: .tiny,
        version: "3.7.0-2ba1506",
        architectures: [.arm64],
        licenseResource: "PaddleOCR-Apache-2.0.txt",
        files: files ?? [
            OCRModelFileManifest(
                relativePath: "det/inference.onnx",
                url: immutableURL("det/inference.onnx"),
                byteCount: 10,
                sha256: String(repeating: "a", count: 64)
            ),
        ]
    )
}

func immutableURL(_ path: String) -> URL {
    URL(string: "https://huggingface.co/PaddlePaddle/model/resolve/2ba1506c0380b8f0b03dd142459aac66d4421f6c/\(path)")!
}
