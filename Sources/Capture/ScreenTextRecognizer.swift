import Foundation
import Vision
import CoreGraphics

enum ScreenTextRecognitionError: Error { case noImage }

struct RecognizedScreenLine: Sendable {
    let text: String
    let region: SourceRegion
}

struct ScreenTextRecognition: Sendable {
    let lines: [RecognizedScreenLine]
    var text: String { lines.map(\.text).joined(separator: "\n") }

    func region(for evidence: String) -> SourceRegion? {
        let tokens = evidence.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        guard !tokens.isEmpty else { return nil }
        let matches = lines.filter { line in
            let text = line.text.lowercased()
            return tokens.filter { text.contains($0) }.count >= min(tokens.count, max(2, tokens.count / 2))
        }
        guard !matches.isEmpty else { return nil }
        let left = matches.map { $0.region.x }.min()!
        let top = matches.map { $0.region.y }.min()!
        let right = matches.map { $0.region.x + $0.region.width }.max()!
        let bottom = matches.map { $0.region.y + $0.region.height }.max()!
        return SourceRegion(x: left, y: top, width: right - left, height: bottom - top)
    }
}

/// Retains Vision geometry in normalized top-left image coordinates.
enum ScreenTextRecognizer {
    static func recognize(in image: CGImage) async throws -> String { try await recognizeLayout(in: image).text }

    static func recognizeLayout(in image: CGImage) async throws -> ScreenTextRecognition {
        try await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            let handler = VNImageRequestHandler(cgImage: image)
            try handler.perform([request])
            let observations = (request.results ?? []).sorted {
                if abs($0.boundingBox.midY - $1.boundingBox.midY) > 0.012 { return $0.boundingBox.midY > $1.boundingBox.midY }
                return $0.boundingBox.minX < $1.boundingBox.minX
            }
            let lines = observations.compactMap { observation -> RecognizedScreenLine? in
                guard let text = observation.topCandidates(1).first?.string else { return nil }
                let box = observation.boundingBox
                return RecognizedScreenLine(text: text, region: SourceRegion(x: box.minX, y: 1 - box.maxY,
                                                                              width: box.width, height: box.height))
            }
            return ScreenTextRecognition(lines: lines)
        }.value
    }
}
