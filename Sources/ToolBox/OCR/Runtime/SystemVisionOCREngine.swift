import CoreGraphics
import Foundation
import Vision

/// System-provided OCR engine using Vision framework's VNRecognizeTextRequest.
/// Available on macOS 11+ with no model downloads required.
///
/// Faster than PaddleOCR for short text (< 50 chars), but less accurate on
/// dense layouts or non-Latin scripts. Always prefer PaddleOCR for Chinese/Japanese.
final class SystemVisionOCREngine: Sendable {
    enum EngineError: Error, Equatable {
        case visionRequestFailed(String)
        case noResults
    }

    func recognize(image: CGImage) async throws -> TextOCRDocument {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        if #available(macOS 13.0, *) {
            request.automaticallyDetectsLanguage = true
        }

        return try await withCheckedThrowingContinuation { continuation in
            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            do {
                try handler.perform([request])
                guard let observations = request.results else {
                    continuation.resume(throwing: EngineError.noResults)
                    return
                }
                let document = convertObservations(observations)
                continuation.resume(returning: document)
            } catch {
                continuation.resume(throwing: EngineError.visionRequestFailed(error.localizedDescription))
            }
        }
    }

    private func convertObservations(_ observations: [VNRecognizedTextObservation]) -> TextOCRDocument {
        let lines = observations.compactMap { obs -> OCRTextLine? in
            guard let text = obs.topCandidates(1).first?.string, !text.isEmpty else { return nil }
            let normalizedRect = obs.boundingBox
            // Vision uses bottom-left origin, OCRTextLine expects top-left origin
            let polygon = [
                CGPoint(x: normalizedRect.minX, y: 1 - normalizedRect.maxY),
                CGPoint(x: normalizedRect.maxX, y: 1 - normalizedRect.maxY),
                CGPoint(x: normalizedRect.maxX, y: 1 - normalizedRect.minY),
                CGPoint(x: normalizedRect.minX, y: 1 - normalizedRect.minY),
            ]
            return try? OCRTextLine(
                text: text,
                confidence: Double(obs.confidence),
                normalizedPolygon: polygon
            )
        }
        return TextOCRDocument(lines: lines)
    }
}
