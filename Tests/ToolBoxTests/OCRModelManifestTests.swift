import XCTest
@testable import ToolBox

final class OCRModelManifestTests: XCTestCase {
    func testValidCatalogRequiresImmutableHTTPSFilesAndUniqueModels() throws {
        let manifest = try makeOCRManifest()

        XCTAssertNoThrow(try OCRModelCatalog(schemaVersion: 1, models: [manifest]).validate())

        var mutable = manifest
        mutable.files[0].url = URL(string: "https://huggingface.co/PaddlePaddle/model/resolve/main/inference.onnx")!
        XCTAssertThrowsError(try OCRModelCatalog(schemaVersion: 1, models: [mutable]).validate()) {
            XCTAssertEqual($0 as? OCRModelManifestError, .mutableURL)
        }

        XCTAssertThrowsError(try OCRModelCatalog(schemaVersion: 1, models: [manifest, manifest]).validate()) {
            XCTAssertEqual($0 as? OCRModelManifestError, .duplicateModelID)
        }
    }

    func testRejectsUnsafePathsHashesLengthsAndUnknownSchema() throws {
        let base = try makeOCRManifest()
        for mutation in ManifestMutation.allCases {
            var manifest = base
            switch mutation {
            case .pathTraversal: manifest.files[0].relativePath = "../escape"
            case .absolutePath: manifest.files[0].relativePath = "/tmp/model"
            case .badHash: manifest.files[0].sha256 = "1234"
            case .zeroLength: manifest.files[0].byteCount = 0
            }
            XCTAssertThrowsError(try OCRModelCatalog(schemaVersion: 1, models: [manifest]).validate(), "\(mutation)")
        }

        XCTAssertThrowsError(try OCRModelCatalog(schemaVersion: 2, models: [base]).validate()) {
            XCTAssertEqual($0 as? OCRModelManifestError, .unknownSchema(2))
        }
    }

    func testLegacyProfileAndExplicitVariantResolveToPipelineSelections() throws {
        let legacy = try makeOCRManifest()
        XCTAssertEqual(
            legacy.selection,
            OCRModelSelection(pipeline: .ppOCRv6, variantID: "tiny")
        )

        var advanced = legacy
        advanced.pipeline = .paddleOCRVL
        advanced.profile = nil
        advanced.variantID = "v1.6"
        XCTAssertEqual(
            advanced.selection,
            OCRModelSelection(pipeline: .paddleOCRVL, variantID: "v1.6")
        )
    }

    func testRejectsVariantThatBelongsToAnotherPipeline() throws {
        var manifest = try makeOCRManifest()
        manifest.variantID = "v1.6"
        XCTAssertThrowsError(try manifest.validate()) {
            XCTAssertEqual($0 as? OCRModelManifestError, .invalidVariant)
        }
    }

    private enum ManifestMutation: CaseIterable {
        case pathTraversal, absolutePath, badHash, zeroLength
    }
}
