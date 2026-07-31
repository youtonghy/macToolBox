import CryptoKit
import XCTest
@testable import ToolBox

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

    func testBundledCatalogContainsAllPPOCRv6ProfilesAndLicense() throws {
        let catalog = try OCRModelCatalogLoader.shipped.loadBundledCatalog()

        XCTAssertEqual(catalog.models.map(\.profile), [.tiny, .small, .medium])
        XCTAssertTrue(catalog.models.allSatisfy { $0.files.count == 4 })
        XCTAssertNotNil(Bundle.main.url(forResource: "PaddleOCR-NOTICE", withExtension: "txt"))
    }
}
