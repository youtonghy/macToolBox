import Foundation

enum PaddleCTCDecoderError: Error, Equatable {
    case invalidShape([Int64])
    case invalidDataCount
}

struct PaddleRecognition: Equatable, Sendable {
    let text: String
    let confidence: Float
}

struct PaddleCTCDecoder: Sendable {
    private let characters: [String]

    init(characters: [String]) {
        self.characters = [""] + characters + [" "]
    }

    func decode(data: [Float], shape: [Int64]) throws -> PaddleRecognition {
        guard shape.count == 3, shape[0] == 1, shape[1] > 0, shape[2] > 0 else {
            throw PaddleCTCDecoderError.invalidShape(shape)
        }
        let timesteps = Int(shape[1])
        let classes = Int(shape[2])
        guard data.count == timesteps * classes else {
            throw PaddleCTCDecoderError.invalidDataCount
        }
        var previous = -1
        var text = ""
        var scores: [Float] = []
        for timestep in 0..<timesteps {
            let offset = timestep * classes
            var index = 0
            var score = data[offset]
            for candidate in 1..<classes where data[offset + candidate] > score {
                index = candidate
                score = data[offset + candidate]
            }
            defer { previous = index }
            guard index != 0, index != previous, index < characters.count else { continue }
            text += characters[index]
            scores.append(min(max(score, 0), 1))
        }
        let confidence = scores.isEmpty ? 0 : scores.reduce(0, +) / Float(scores.count)
        return PaddleRecognition(text: text, confidence: confidence)
    }
}
