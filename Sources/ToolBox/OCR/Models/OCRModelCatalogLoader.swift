import CryptoKit
import Foundation

enum OCRModelCatalogLoaderError: Error, Equatable {
    case missingResource(String)
    case invalidPublicKey
    case invalidSignatureEncoding
    case invalidSignature
    case malformedCatalog
    case invalidCatalog(OCRModelManifestError)
}

struct OCRModelCatalogLoader {
    private let publicKey: Data

    init(publicKey: Data) {
        self.publicKey = publicKey
    }

    func decodeCatalog(data: Data, signature: Data) throws -> OCRModelCatalog {
        let key: Curve25519.Signing.PublicKey
        do {
            key = try Curve25519.Signing.PublicKey(rawRepresentation: publicKey)
        } catch {
            throw OCRModelCatalogLoaderError.invalidPublicKey
        }
        guard key.isValidSignature(signature, for: data) else {
            throw OCRModelCatalogLoaderError.invalidSignature
        }
        let catalog: OCRModelCatalog
        do {
            catalog = try JSONDecoder().decode(OCRModelCatalog.self, from: data)
        } catch {
            throw OCRModelCatalogLoaderError.malformedCatalog
        }
        do {
            try catalog.validate()
        } catch let error as OCRModelManifestError {
            throw OCRModelCatalogLoaderError.invalidCatalog(error)
        }
        return catalog
    }

    func loadBundledCatalog(bundle: Bundle = .main) throws -> OCRModelCatalog {
        let catalogURL = try resourceURL(
            named: "catalog-v1",
            extension: "json",
            bundle: bundle
        )
        let signatureURL = try resourceURL(
            named: "catalog-v1",
            extension: "sig",
            bundle: bundle
        )
        let signatureText = try String(contentsOf: signatureURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let signature = Data(base64Encoded: signatureText) else {
            throw OCRModelCatalogLoaderError.invalidSignatureEncoding
        }
        let catalog = try decodeCatalog(
            data: Data(contentsOf: catalogURL),
            signature: signature
        )
        for license in Set(catalog.models.map(\.licenseResource)) {
            guard bundle.url(forResource: license, withExtension: nil) != nil else {
                throw OCRModelCatalogLoaderError.missingResource(license)
            }
        }
        return catalog
    }

    private func resourceURL(
        named name: String,
        extension fileExtension: String,
        bundle: Bundle
    ) throws -> URL {
        guard let url = bundle.url(forResource: name, withExtension: fileExtension) else {
            throw OCRModelCatalogLoaderError.missingResource("\(name).\(fileExtension)")
        }
        return url
    }

    static let shipped = OCRModelCatalogLoader(
        publicKey: Data(base64Encoded: "PhgH3VJk+drrbYziClQaPCnmsfn902MwwlzYsJnoVu4=")!
    )
}
