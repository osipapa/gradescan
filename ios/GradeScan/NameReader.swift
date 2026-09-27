import CoreGraphics
import Foundation
import Vision

/// Reads the handwritten name with on-device text recognition. Nothing leaves the phone except the result.
enum NameReader {
    static func read(_ strip: GrayStrip) async -> String? {
        guard let image = strip.cgImage() else { return nil }
        return await Task.detached(priority: .userInitiated) { recognize(image) }.value
    }

    static func recognize(_ image: CGImage) -> String? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false   // names aren't dictionary words
        let wanted = ["en-US", "es-ES"]
        if let supported = try? request.supportedRecognitionLanguages() {
            request.recognitionLanguages = wanted.filter(supported.contains)
        }
        guard (try? VNImageRequestHandler(cgImage: image).perform([request])) != nil else { return nil }
        let words = (request.results ?? [])
            .sorted { $0.boundingBox.minX < $1.boundingBox.minX }
            .compactMap { $0.topCandidates(1).first?.string }
        return clean(words.joined(separator: " "))
    }

    /// Letters, spaces, hyphens and apostrophes only; nil when nothing name-like is left.
    static func clean(_ text: String) -> String? {
        let kept = String(text.unicodeScalars.map { CharacterSet.letters.contains($0) || "-' ".unicodeScalars.contains($0) ? Character($0) : " " })
        let name = kept.split(separator: " ").joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: "-' "))
        return name.count >= 2 ? name : nil
    }
}
