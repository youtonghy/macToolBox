import Foundation

public enum ToolBoxControlJSONCodecError: Error, Equatable {
    case payloadTooLarge(Int)
}

public enum ToolBoxControlJSONCodec {
    public static let maximumPayloadSize = 1024 * 1024

    public static func encodeRequest(_ request: ToolBoxControlRequestEnvelope) throws -> Data {
        try encode(request)
    }

    public static func decodeRequest(_ data: Data) throws -> ToolBoxControlRequestEnvelope {
        try decode(ToolBoxControlRequestEnvelope.self, from: data)
    }

    public static func encodeResponse(_ response: ToolBoxControlResponseEnvelope) throws -> Data {
        try encode(response)
    }

    public static func decodeResponse(_ data: Data) throws -> ToolBoxControlResponseEnvelope {
        try decode(ToolBoxControlResponseEnvelope.self, from: data)
    }

    private static func encode<Value: Encodable>(_ value: Value) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        guard data.count <= maximumPayloadSize else {
            throw ToolBoxControlJSONCodecError.payloadTooLarge(data.count)
        }
        return data
    }

    private static func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
        guard data.count <= maximumPayloadSize else {
            throw ToolBoxControlJSONCodecError.payloadTooLarge(data.count)
        }
        return try JSONDecoder().decode(type, from: data)
    }
}
