import CryptoKit
import XCTest
@testable import ToolBoxCore

final class OCRModelCatalogLoaderTests: XCTestCase {
    func testVerifiesSignedCatalogAndRejectsTampering() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let data = Data("{\"models\":[],\"schemaVersion\":1}".utf8)
        let signature = try privateKey.signature(for: data)
        let loader = OCRModelCatalogLoader(publicKey: privateKey.publicKey.rawRepresentation)

        XCTAssertThrowsError(try loader.decodeCatalog(data: data, signature: signature)) {
            XCTAssertEqual(
                $0 as? OCRModelCatalogLoaderError,
                .invalidCatalog(.emptyCatalog)
            )
        }

        var tampered = data
        tampered.append(0x20)
        XCTAssertThrowsError(try loader.decodeCatalog(data: tampered, signature: signature)) {
            XCTAssertEqual($0 as? OCRModelCatalogLoaderError, .invalidSignature)
        }
    }

    func testBundledCatalogContainsEverySelectablePipelineAndLicense() throws {
        let catalog = try OCRModelCatalogLoader.shipped.loadBundledCatalog()

        XCTAssertEqual(catalog.models.count, 7)
        let downloadableSelections = Set(OCRPipelineID.allCases
            .filter { $0 != .systemVision }
            .flatMap { pipeline in
                pipeline.knownVariantIDs.map {
                    OCRModelSelection(pipeline: pipeline, variantID: $0)
                }
            })
        XCTAssertEqual(Set(catalog.models.map(\.selection)), downloadableSelections)
        XCTAssertTrue(catalog.models.allSatisfy { !$0.files.isEmpty })
        XCTAssertNotNil(Bundle.main.url(forResource: "PaddleOCR-NOTICE", withExtension: "txt"))
    }
}
