import CoreGraphics
import Foundation

enum OCRWorkerProtocolError: Error, Equatable {
    case unsupportedSchema(Int)
    case unsupportedPipeline(String)
    case unsupportedResultKind(String)
    case unsupportedMessageType(String)
    case invalidTaskID
    case invalidPath
    case duplicateTask
    case invalidResult
    case invalidPolygon
    case invalidMarkdownRange
    case resultTooLarge
    case outputTooLarge
    case workerFailed(String)
    case workerTimedOut
}

private enum OCRWorkerProtocolConstants {
    static let maximumTaskIDBytes = 128
    static let maximumVariantIDBytes = 128
    static let maximumPathBytes = 4 * 1024
    static let maximumTextBytes = 16 * 1024 * 1024
    static let maximumBlocks = 100_000
}

private func validateWorkerText(_ value: String, maximumBytes: Int) throws {
    guard !value.isEmpty,
          value.utf8.count <= maximumBytes,
          value.unicodeScalars.allSatisfy({ $0.value != 0 })
    else { throw OCRWorkerProtocolError.invalidResult }
}

private func validateWorkerIdentifier(_ value: String, maximumBytes: Int) throws {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
    guard !value.isEmpty,
          value.utf8.count <= maximumBytes,
          value.unicodeScalars.allSatisfy({
              $0.value < 128 && allowed.contains($0)
          })
    else { throw OCRWorkerProtocolError.invalidTaskID }
}

private func validateWorkerPath(_ value: String) throws {
    guard !value.isEmpty,
          value.utf8.count <= OCRWorkerProtocolConstants.maximumPathBytes,
          value == value.precomposedStringWithCanonicalMapping,
          !value.hasPrefix("/"),
          !value.contains("\\"),
          !value.unicodeScalars.contains(where: { $0.value == 0 })
    else { throw OCRWorkerProtocolError.invalidPath }
    let components = value.split(separator: "/", omittingEmptySubsequences: false)
    guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
        throw OCRWorkerProtocolError.invalidPath
    }
}

private func validateWorkerFilesystemPath(_ value: String) throws {
    guard !value.isEmpty,
          value.utf8.count <= OCRWorkerProtocolConstants.maximumPathBytes,
          value == value.precomposedStringWithCanonicalMapping,
          !value.unicodeScalars.contains(where: { $0.value == 0 })
    else { throw OCRWorkerProtocolError.invalidPath }
    let components = value.split(separator: "/", omittingEmptySubsequences: true)
    guard components.allSatisfy({ $0 != "." && $0 != ".." }) else {
        throw OCRWorkerProtocolError.invalidPath
    }
}

struct OCRWorkerRequestEnvelope: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let type: String
    let taskID: String
    let pipeline: OCRPipelineID
    let variantID: String
    let imagePath: String
    let modelDirectory: String

    init(
        taskID: String,
        pipeline: OCRPipelineID,
        variantID: String,
        imagePath: String,
        modelDirectory: String,
        schemaVersion: Int = currentSchemaVersion
    ) throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw OCRWorkerProtocolError.unsupportedSchema(schemaVersion)
        }
        try validateWorkerIdentifier(taskID, maximumBytes: OCRWorkerProtocolConstants.maximumTaskIDBytes)
        try validateWorkerIdentifier(variantID, maximumBytes: OCRWorkerProtocolConstants.maximumVariantIDBytes)
        try validateWorkerPath(imagePath)
        try validateWorkerFilesystemPath(modelDirectory)
        self.schemaVersion = schemaVersion
        type = "request"
        self.taskID = taskID
        self.pipeline = pipeline
        self.variantID = variantID
        self.imagePath = imagePath
        self.modelDirectory = modelDirectory
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, type, taskID, pipeline, variantID, imagePath, modelDirectory
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == Self.currentSchemaVersion else {
            throw OCRWorkerProtocolError.unsupportedSchema(schemaVersion)
        }
        let type = try container.decodeIfPresent(String.self, forKey: .type) ?? "request"
        guard type == "request" else { throw OCRWorkerProtocolError.unsupportedMessageType(type) }
        let taskID = try container.decode(String.self, forKey: .taskID)
        let rawPipeline = try container.decode(String.self, forKey: .pipeline)
        guard let pipeline = OCRPipelineID(rawValue: rawPipeline) else {
            throw OCRWorkerProtocolError.unsupportedPipeline(rawPipeline)
        }
        let variantID = try container.decode(String.self, forKey: .variantID)
        let imagePath = try container.decode(String.self, forKey: .imagePath)
        let modelDirectory = try container.decode(String.self, forKey: .modelDirectory)
        try self.init(
            taskID: taskID,
            pipeline: pipeline,
            variantID: variantID,
            imagePath: imagePath,
            modelDirectory: modelDirectory,
            schemaVersion: schemaVersion
        )
    }
}

struct OCRWorkerCancelEnvelope: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1
    let schemaVersion: Int
    let type: String
    let taskID: String

    init(taskID: String, schemaVersion: Int = currentSchemaVersion) throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw OCRWorkerProtocolError.unsupportedSchema(schemaVersion)
        }
        try validateWorkerIdentifier(taskID, maximumBytes: OCRWorkerProtocolConstants.maximumTaskIDBytes)
        self.schemaVersion = schemaVersion
        type = "cancel"
        self.taskID = taskID
    }
}

struct OCRWorkerErrorEnvelope: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1
    let schemaVersion: Int
    let type: String
    let taskID: String
    let code: String
    let message: String

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, type, taskID, code, message
    }

    init(
        taskID: String,
        code: String,
        message: String,
        schemaVersion: Int = currentSchemaVersion
    ) throws {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw OCRWorkerProtocolError.unsupportedSchema(schemaVersion)
        }
        try validateWorkerIdentifier(taskID, maximumBytes: OCRWorkerProtocolConstants.maximumTaskIDBytes)
        try validateWorkerIdentifier(code, maximumBytes: 128)
        try validateWorkerText(message, maximumBytes: OCRWorkerProtocolConstants.maximumTextBytes)
        self.schemaVersion = schemaVersion
        type = "error"
        self.taskID = taskID
        self.code = code
        self.message = message
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        let type = try container.decodeIfPresent(String.self, forKey: .type) ?? "error"
        guard type == "error" else { throw OCRWorkerProtocolError.unsupportedMessageType(type) }
        let taskID = try container.decode(String.self, forKey: .taskID)
        let code = try container.decode(String.self, forKey: .code)
        let message = try container.decode(String.self, forKey: .message)
        try self.init(
            taskID: taskID,
            code: code,
            message: message,
            schemaVersion: schemaVersion
        )
    }
}

struct OCRWorkerPoint: Codable, Equatable, Sendable {
    let x: Double
    let y: Double

    init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    init(from decoder: Decoder) throws {
        if var unkeyed = try? decoder.unkeyedContainer() {
            guard !unkeyed.isAtEnd else {
                throw DecodingError.dataCorruptedError(
                    in: unkeyed,
                    debugDescription: "OCR worker point must contain x and y"
                )
            }
            let x = try unkeyed.decode(Double.self)
            let y = try unkeyed.decode(Double.self)
            guard unkeyed.isAtEnd else {
                throw DecodingError.dataCorruptedError(
                    in: unkeyed,
                    debugDescription: "OCR worker point must contain exactly two values"
                )
            }
            self.init(x: x, y: y)
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            x: try container.decode(Double.self, forKey: .x),
            y: try container.decode(Double.self, forKey: .y)
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(x)
        try container.encode(y)
    }

    private enum CodingKeys: String, CodingKey {
        case x
        case y
    }
}

struct OCRWorkerResultBlock: Codable, Equatable, Sendable {
    let id: String?
    let kind: String
    let polygon: [OCRWorkerPoint]
    let text: String?
    let html: String?
    let confidence: Double?
    let markdownStart: Int?
    let markdownEnd: Int?

    init(
        id: String?,
        kind: String,
        polygon: [OCRWorkerPoint],
        text: String?,
        html: String? = nil,
        confidence: Double? = nil,
        markdownStart: Int? = nil,
        markdownEnd: Int? = nil
    ) {
        self.id = id
        self.kind = kind
        self.polygon = polygon
        self.text = text
        self.html = html
        self.confidence = confidence
        self.markdownStart = markdownStart
        self.markdownEnd = markdownEnd
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, polygon, text, html, confidence, markdownStart, markdownEnd
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        try validateWorkerText(kind, maximumBytes: 128)
        let text = try container.decodeIfPresent(String.self, forKey: .text)
        let html = try container.decodeIfPresent(String.self, forKey: .html)
        if let text { try validateWorkerText(text, maximumBytes: OCRWorkerProtocolConstants.maximumTextBytes) }
        if let html { try validateWorkerText(html, maximumBytes: OCRWorkerProtocolConstants.maximumTextBytes) }
        let confidence = try container.decodeIfPresent(Double.self, forKey: .confidence)
        guard confidence == nil || (confidence!.isFinite && (0...1).contains(confidence!)) else {
            throw OCRWorkerProtocolError.invalidResult
        }
        let polygon = try container.decode([OCRWorkerPoint].self, forKey: .polygon)
        guard polygon.count <= 16 else { throw OCRWorkerProtocolError.invalidPolygon }
        self.init(
            id: try container.decodeIfPresent(String.self, forKey: .id),
            kind: kind,
            polygon: polygon,
            text: text,
            html: html,
            confidence: confidence,
            markdownStart: try container.decodeIfPresent(Int.self, forKey: .markdownStart),
            markdownEnd: try container.decodeIfPresent(Int.self, forKey: .markdownEnd)
        )
    }
}

enum OCRWorkerResultPayload: Equatable, Sendable {
    case structured([OCRWorkerResultBlock])
    case document(markdown: String, blocks: [OCRWorkerResultBlock])
}

extension OCRWorkerResultPayload: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case markdown
        case blocks
    }

    private enum Kind: String, Codable {
        case structured
        case document
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        switch kind {
        case Kind.structured.rawValue:
            let blocks = try container.decode([OCRWorkerResultBlock].self, forKey: .blocks)
            guard blocks.count <= OCRWorkerProtocolConstants.maximumBlocks else {
                throw OCRWorkerProtocolError.resultTooLarge
            }
            self = .structured(blocks)
        case Kind.document.rawValue:
            let markdown = try container.decode(String.self, forKey: .markdown)
            guard markdown.utf8.count <= OCRWorkerProtocolConstants.maximumTextBytes else {
                throw OCRWorkerProtocolError.resultTooLarge
            }
            let blocks = try container.decode([OCRWorkerResultBlock].self, forKey: .blocks)
            guard blocks.count <= OCRWorkerProtocolConstants.maximumBlocks else {
                throw OCRWorkerProtocolError.resultTooLarge
            }
            self = .document(
                markdown: markdown,
                blocks: blocks
            )
        default:
            throw OCRWorkerProtocolError.unsupportedResultKind(kind)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case let .structured(blocks):
            guard blocks.count <= OCRWorkerProtocolConstants.maximumBlocks else {
                throw OCRWorkerProtocolError.resultTooLarge
            }
            try container.encode(Kind.structured.rawValue, forKey: .kind)
            try container.encode(blocks, forKey: .blocks)
        case let .document(markdown, blocks):
            guard markdown.utf8.count <= OCRWorkerProtocolConstants.maximumTextBytes,
                  blocks.count <= OCRWorkerProtocolConstants.maximumBlocks
            else { throw OCRWorkerProtocolError.resultTooLarge }
            try container.encode(Kind.document.rawValue, forKey: .kind)
            try container.encode(markdown, forKey: .markdown)
            try container.encode(blocks, forKey: .blocks)
        }
    }
}

struct OCRWorkerResultEnvelope: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let taskID: String
    let pipeline: OCRPipelineID
    let variantID: String
    let result: OCRWorkerResultPayload

    init(
        taskID: String,
        pipeline: OCRPipelineID,
        variantID: String,
        result: OCRWorkerResultPayload,
        schemaVersion: Int = currentSchemaVersion
    ) {
        self.schemaVersion = schemaVersion
        self.taskID = taskID
        self.pipeline = pipeline
        self.variantID = variantID
        self.result = result
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case schemaVersion
        case taskID
        case pipeline
        case variantID
        case result
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let type = try container.decodeIfPresent(String.self, forKey: .type), type != "result" {
            throw OCRWorkerProtocolError.unsupportedMessageType(type)
        }
        let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == Self.currentSchemaVersion else {
            throw OCRWorkerProtocolError.unsupportedSchema(schemaVersion)
        }
        let taskID = try container.decode(String.self, forKey: .taskID)
        let rawPipeline = try container.decode(String.self, forKey: .pipeline)
        guard let pipeline = OCRPipelineID(rawValue: rawPipeline) else {
            throw OCRWorkerProtocolError.unsupportedPipeline(rawPipeline)
        }
        try validateWorkerIdentifier(taskID, maximumBytes: OCRWorkerProtocolConstants.maximumTaskIDBytes)
        let variantID = try container.decode(String.self, forKey: .variantID)
        try validateWorkerIdentifier(variantID, maximumBytes: OCRWorkerProtocolConstants.maximumVariantIDBytes)
        self.init(
            taskID: taskID,
            pipeline: pipeline,
            variantID: variantID,
            result: try container.decode(OCRWorkerResultPayload.self, forKey: .result),
            schemaVersion: schemaVersion
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("result", forKey: .type)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(taskID, forKey: .taskID)
        try container.encode(pipeline.rawValue, forKey: .pipeline)
        try container.encode(variantID, forKey: .variantID)
        try container.encode(result, forKey: .result)
    }
}
