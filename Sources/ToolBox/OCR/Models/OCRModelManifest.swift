import Foundation

struct OCRModelFileManifest: Codable, Equatable, Sendable {
    var relativePath: String
    var url: URL
    var byteCount: Int64
    var sha256: String
}

struct OCRModelManifest: Codable, Equatable, Sendable {
    var id: String
    var pipeline: OCRPipelineID
    var profile: PPOCRv6Profile?
    var version: String
    var architectures: Set<OCRRuntimeArchitecture>
    var licenseResource: String
    var files: [OCRModelFileManifest]
}

struct OCRModelCatalog: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let models: [OCRModelManifest]

    func validate() throws {
        guard schemaVersion == 1 else { throw OCRModelManifestError.unknownSchema(schemaVersion) }
        guard !models.isEmpty else { throw OCRModelManifestError.emptyCatalog }
        var modelIDs = Set<String>()
        for model in models {
            guard modelIDs.insert(model.id).inserted else {
                throw OCRModelManifestError.duplicateModelID
            }
            try model.validate()
        }
    }
}

enum OCRModelManifestError: Error, Equatable {
    case unknownSchema(Int)
    case emptyCatalog
    case duplicateModelID
    case invalidIdentifier
    case invalidArchitecture
    case missingLicense
    case emptyFiles
    case duplicatePath
    case unsafePath
    case unsupportedURL
    case mutableURL
    case invalidLength
    case invalidHash
}

extension OCRModelManifest {
    func validate() throws {
        guard Self.isSafeIdentifier(id), Self.isSafeIdentifier(version) else {
            throw OCRModelManifestError.invalidIdentifier
        }
        guard !architectures.isEmpty else { throw OCRModelManifestError.invalidArchitecture }
        guard !licenseResource.isEmpty else { throw OCRModelManifestError.missingLicense }
        guard !files.isEmpty else { throw OCRModelManifestError.emptyFiles }
        var normalizedPaths = Set<String>()
        for file in files {
            let normalized = file.relativePath.precomposedStringWithCanonicalMapping
            guard normalizedPaths.insert(normalized).inserted else {
                throw OCRModelManifestError.duplicatePath
            }
            guard Self.isSafeRelativePath(file.relativePath) else {
                throw OCRModelManifestError.unsafePath
            }
            guard file.url.scheme?.lowercased() == "https",
                  file.url.host?.lowercased() == "huggingface.co"
            else {
                throw OCRModelManifestError.unsupportedURL
            }
            let parts = file.url.pathComponents
            guard let resolve = parts.firstIndex(of: "resolve"), resolve + 1 < parts.count,
                  Self.isFullGitRevision(parts[resolve + 1])
            else {
                throw OCRModelManifestError.mutableURL
            }
            guard file.byteCount > 0 else { throw OCRModelManifestError.invalidLength }
            guard file.sha256.count == 64,
                  file.sha256.unicodeScalars.allSatisfy({
                      CharacterSet(charactersIn: "0123456789abcdef").contains($0)
                  })
            else {
                throw OCRModelManifestError.invalidHash
            }
        }
    }

    private static func isSafeIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".-_"))
                .contains($0)
        }
    }

    private static func isSafeRelativePath(_ value: String) -> Bool {
        guard !value.isEmpty,
              value == value.precomposedStringWithCanonicalMapping,
              !value.hasPrefix("/"),
              !value.contains("\\"),
              !value.unicodeScalars.contains(where: { $0.value == 0 })
        else { return false }
        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        return components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    private static func isFullGitRevision(_ value: String) -> Bool {
        value.count == 40 && value.unicodeScalars.allSatisfy {
            CharacterSet(charactersIn: "0123456789abcdef").contains($0)
        }
    }
}
