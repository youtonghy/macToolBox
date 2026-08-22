import Foundation

public enum ToolBoxEndpointMetadataError: Error, Equatable {
    case unsupportedSchemaVersion(Int)
    case unsupportedProtocolVersion(Int)
    case invalidBundleIdentifier(String)
    case invalidProcessIdentifier(Int32)
    case invalidSocketPath
    case encodedMetadataTooLarge
}

public struct ToolBoxEndpointMetadata: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1
    public static let appBundleIdentifier = "com.youtonghy.toolbox"
    public static let maximumEncodedSize = 256 * 1024

    public let schemaVersion: Int
    public let protocolVersion: Int
    public let appBundleIdentifier: String
    public let appVersion: String
    public let appProcessIdentifier: Int32
    public let publishedAt: Date
    public let socketPath: String

    public init(
        appVersion: String,
        appProcessIdentifier: Int32,
        publishedAt: Date = Date(),
        socketPath: String,
        schemaVersion: Int = ToolBoxEndpointMetadata.currentSchemaVersion,
        protocolVersion: Int = ToolBoxControlProtocolVersion.current,
        appBundleIdentifier: String = ToolBoxEndpointMetadata.appBundleIdentifier
    ) {
        self.schemaVersion = schemaVersion
        self.protocolVersion = protocolVersion
        self.appBundleIdentifier = appBundleIdentifier
        self.appVersion = appVersion
        self.appProcessIdentifier = appProcessIdentifier
        self.publishedAt = publishedAt
        self.socketPath = socketPath
    }

    public func validate() throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw ToolBoxEndpointMetadataError.unsupportedSchemaVersion(schemaVersion)
        }
        guard protocolVersion == ToolBoxControlProtocolVersion.current else {
            throw ToolBoxEndpointMetadataError.unsupportedProtocolVersion(protocolVersion)
        }
        guard appBundleIdentifier == Self.appBundleIdentifier else {
            throw ToolBoxEndpointMetadataError.invalidBundleIdentifier(appBundleIdentifier)
        }
        guard appProcessIdentifier > 0 else {
            throw ToolBoxEndpointMetadataError.invalidProcessIdentifier(appProcessIdentifier)
        }
        guard socketPath.hasPrefix("/"),
              socketPath.utf8.count < 104,
              !socketPath.utf8.contains(0)
        else {
            throw ToolBoxEndpointMetadataError.invalidSocketPath
        }
    }
}

public enum ToolBoxEndpointMetadataCodec {
    public static func encode(_ metadata: ToolBoxEndpointMetadata) throws -> Data {
        try metadata.validate()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(metadata)
        guard data.count <= ToolBoxEndpointMetadata.maximumEncodedSize else {
            throw ToolBoxEndpointMetadataError.encodedMetadataTooLarge
        }
        return data
    }

    public static func decode(_ data: Data) throws -> ToolBoxEndpointMetadata {
        guard data.count <= ToolBoxEndpointMetadata.maximumEncodedSize else {
            throw ToolBoxEndpointMetadataError.encodedMetadataTooLarge
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let metadata = try decoder.decode(ToolBoxEndpointMetadata.self, from: data)
        try metadata.validate()
        return metadata
    }
}

public enum ToolBoxEndpointLocation {
    public static let metadataFilename = "control-v1.json"
    public static let socketFilename = "control-v1.sock"

    public static func defaultMetadataURL(fileManager: FileManager = .default) -> URL {
        let cacheRoot = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches", isDirectory: true)
        return cacheRoot
            .appendingPathComponent(ToolBoxEndpointMetadata.appBundleIdentifier, isDirectory: true)
            .appendingPathComponent(metadataFilename, isDirectory: false)
    }

    public static func defaultSocketURL(fileManager: FileManager = .default) -> URL {
        defaultMetadataURL(fileManager: fileManager)
            .deletingLastPathComponent()
            .appendingPathComponent(socketFilename, isDirectory: false)
    }
}
