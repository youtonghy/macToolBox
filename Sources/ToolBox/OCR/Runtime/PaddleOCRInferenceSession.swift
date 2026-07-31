import Foundation

enum PaddleOCRInferenceError: Error, Equatable {
    case invalidTensor
    case sessionCreationFailed(String)
    case inferenceFailed(String)
}

final class PaddleOCRInferenceSession: @unchecked Sendable {
    private var handle: OpaquePointer?

    init(modelURL: URL, provider: OCRExecutionProvider) throws {
        var rawError: UnsafeMutablePointer<CChar>?
        handle = modelURL.path.withCString {
            TBOXORTCreateSession($0, provider == .coreML, &rawError)
        }
        guard handle != nil else {
            throw PaddleOCRInferenceError.sessionCreationFailed(Self.consume(&rawError))
        }
        if rawError != nil { TBOXORTFreeError(rawError) }
    }

    deinit {
        if let handle { TBOXORTDestroySession(handle) }
    }

    func run(_ input: PaddleOCRTensor) throws -> PaddleOCRTensor {
        guard let handle,
              !input.data.isEmpty,
              !input.shape.isEmpty,
              Self.elementCount(for: input.shape) == input.data.count
        else { throw PaddleOCRInferenceError.invalidTensor }

        var output = TBOXORTTensor()
        var rawError: UnsafeMutablePointer<CChar>?
        let succeeded = input.data.withUnsafeBufferPointer { data in
            input.shape.withUnsafeBufferPointer { shape in
                TBOXORTRun(
                    handle,
                    data.baseAddress,
                    data.count,
                    shape.baseAddress,
                    shape.count,
                    &output,
                    &rawError
                )
            }
        }
        guard succeeded else {
            throw PaddleOCRInferenceError.inferenceFailed(Self.consume(&rawError))
        }
        defer { TBOXORTFreeTensor(&output) }
        guard let data = output.data,
              let shape = output.shape,
              output.dataCount > 0,
              output.shapeCount > 0
        else { throw PaddleOCRInferenceError.inferenceFailed("ONNX Runtime returned an empty tensor") }
        return PaddleOCRTensor(
            data: Array(UnsafeBufferPointer(start: data, count: output.dataCount)),
            shape: Array(UnsafeBufferPointer(start: shape, count: output.shapeCount))
        )
    }

    private static func elementCount(for shape: [Int64]) -> Int? {
        var count = 1
        for dimension in shape {
            guard dimension > 0, dimension <= Int64(Int.max) else { return nil }
            let product = count.multipliedReportingOverflow(by: Int(dimension))
            guard !product.overflow else { return nil }
            count = product.partialValue
        }
        return count
    }

    private static func consume(_ error: inout UnsafeMutablePointer<CChar>?) -> String {
        guard let pointer = error else { return "Unknown ONNX Runtime error" }
        error = nil
        defer { TBOXORTFreeError(pointer) }
        return String(cString: pointer)
    }
}
