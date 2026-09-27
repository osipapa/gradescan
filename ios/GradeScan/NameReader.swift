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

    /// A period written by hand (ZipGrade's Period box): the first digit 1–9 it reads, if any.
    static func readPeriod(_ strip: GrayStrip) async -> Int? {
        guard let image = strip.cgImage() else { return nil }
        return await Task.detached(priority: .userInitiated) { () -> Int? in
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            guard (try? VNImageRequestHandler(cgImage: image).perform([request])) != nil else { return nil }
            let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined()
            // Handwritten 1s and 7s are often read as letters.
            let fixed = text.map { c -> Character in ["l": "1", "I": "1", "|": "1", "i": "1", "T": "7", "S": "5", "O": "0", "o": "0"][c] ?? c }
            return fixed.compactMap { $0.wholeNumberValue }.first { (1...9).contains($0) }
        }.value
    }

    /// A date written by hand (ZipGrade's Date box), as month/day or month/day/year: "9/25", "09/25/26".
    static func readDate(_ strip: GrayStrip) async -> String? {
        guard let image = strip.cgImage() else { return nil }
        return await Task.detached(priority: .userInitiated) { () -> String? in
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            guard (try? VNImageRequestHandler(cgImage: image).perform([request])) != nil else { return nil }
            let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
            let fixed = String(text.map { ["l": "1", "I": "1", "|": "1", "O": "0", "o": "0", "S": "5", "-": "/", ".": "/", "\\": "/"][$0] ?? $0 })
            let parts = fixed.split { !$0.isNumber }.compactMap { Int($0) }
            guard parts.count >= 2, (1...12).contains(parts[0]), (1...31).contains(parts[1]) else { return nil }
            return parts.count >= 3 ? "\(parts[0])/\(parts[1])/\(parts[2] % 100)" : "\(parts[0])/\(parts[1])"
        }.value
    }

    /// Letters, spaces, hyphens and apostrophes only; nil when nothing name-like is left.
    static func clean(_ text: String) -> String? {
        let kept = String(text.unicodeScalars.map { CharacterSet.letters.contains($0) || "-' ".unicodeScalars.contains($0) ? Character($0) : " " })
        let name = kept.split(separator: " ").joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: "-' "))
        return name.count >= 2 ? name : nil
    }
}
