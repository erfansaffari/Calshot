import Foundation
import Vision
import CoreGraphics

enum ScreenTextRecognitionError: Error {
    case noImage
}

/// Local OCR only; recognized text is returned in visual reading order.
enum ScreenTextRecognizer {
    static func recognize(in image: CGImage) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            let handler = VNImageRequestHandler(cgImage: image)
            try handler.perform([request])
            return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: "\n")
        }.value
    }
}
