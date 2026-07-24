import CoreAudio
import Foundation

enum CoreAudioPropertyError: Error, LocalizedError {
    case status(OSStatus, AudioObjectPropertySelector)

    var errorDescription: String? {
        switch self {
        case let .status(status, selector):
            return "Core Audio property \(selector) failed with OSStatus \(status)."
        }
    }
}

enum CoreAudioPropertyReader {
    struct ObjectReadResult<Value> {
        let objects: [(id: AudioObjectID, value: Value)]
        let failureCount: Int
    }

    static func readAvailableObjects<Value>(
        _ objectIDs: [AudioObjectID],
        read: (AudioObjectID) throws -> Value
    ) -> ObjectReadResult<Value> {
        var objects: [(id: AudioObjectID, value: Value)] = []
        var failureCount = 0
        for objectID in objectIDs {
            do {
                objects.append((objectID, try read(objectID)))
            } catch {
                failureCount += 1
            }
        }
        return ObjectReadResult(objects: objects, failureCount: failureCount)
    }

    static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    static func value<T>(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        initial: T
    ) throws -> T {
        var result = initial
        var size = UInt32(MemoryLayout<T>.stride)
        var propertyAddress = address(selector, scope: scope)
        let status = withUnsafeMutableBytes(of: &result) { buffer in
            AudioObjectGetPropertyData(objectID, &propertyAddress, 0, nil, &size, buffer.baseAddress!)
        }
        guard status == noErr else { throw CoreAudioPropertyError.status(status, selector) }
        return result
    }

    static func objectIDs(
        objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) throws -> [AudioObjectID] {
        var propertyAddress = address(selector, scope: scope)
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(objectID, &propertyAddress, 0, nil, &size)
        guard status == noErr else { throw CoreAudioPropertyError.status(status, selector) }
        guard size > 0 else { return [] }
        var values = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.stride)
        status = AudioObjectGetPropertyData(objectID, &propertyAddress, 0, nil, &size, &values)
        guard status == noErr else { throw CoreAudioPropertyError.status(status, selector) }
        return values
    }

    static func string(objectID: AudioObjectID, selector: AudioObjectPropertySelector) throws -> String {
        var propertyAddress = address(selector)
        var size = UInt32(MemoryLayout<CFString?>.stride)
        var value: CFString = "" as CFString
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(objectID, &propertyAddress, 0, nil, &size, pointer)
        }
        guard status == noErr else { throw CoreAudioPropertyError.status(status, selector) }
        return value as String
    }

    static func hasStreams(objectID: AudioObjectID, scope: AudioObjectPropertyScope) throws -> Bool {
        var propertyAddress = address(kAudioDevicePropertyStreams, scope: scope)
        var size: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(objectID, &propertyAddress, 0, nil, &size)
        guard status == noErr else {
            throw CoreAudioPropertyError.status(status, kAudioDevicePropertyStreams)
        }
        return size >= MemoryLayout<AudioObjectID>.stride
    }

    static func streamFormats(
        objectID: AudioObjectID,
        scope: AudioObjectPropertyScope
    ) throws -> [HALAudioStreamFormatRecord] {
        let streamIDs = try objectIDs(
            objectID: objectID,
            selector: kAudioDevicePropertyStreams,
            scope: scope
        )
        return try streamIDs.map { streamID in
            let format: AudioStreamBasicDescription = try value(
                objectID: streamID,
                selector: kAudioStreamPropertyVirtualFormat,
                initial: AudioStreamBasicDescription()
            )
            return HALAudioStreamFormatRecord(format)
        }
    }
}
