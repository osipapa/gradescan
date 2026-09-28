import CoreGraphics
import Foundation
import Vision

/// Reads the handwritten name with on-device text recognition. Nothing leaves the phone except the result.
enum NameReader {
    /// Everything read from one handwritten name.
    struct Result: Sendable {
        var text: String?                        // the plainest reading, to show and to store
        var readings: [NameMatch.Reading] = []   // every reading, for matching to the class list
        var handwriting: [Float]?                // what the writing looks like, for HandwritingMemory
    }

    /// Two looks at the name, both on a white margin (writing that touches the edge of the picture is often missed):
    /// letter by letter as written, and with language correction, which also lists up to ten alternatives and favors
    /// the class list's names (`names`).
    static func read(_ strip: GrayStrip, names: [String] = []) async -> Result {
        await Task.detached(priority: .userInitiated) { recognize(strip, names: names) }.value
    }

    static func recognize(_ strip: GrayStrip, names: [String]) -> Result {
        var result = Result(handwriting: Handwriting.print(strip))
        guard let image = strip.padded().cgImage() else { return result }
        let plain = request(correcting: false, names: [])
        let corrected = request(correcting: true, names: names)
        guard (try? VNImageRequestHandler(cgImage: image).perform([plain, corrected])) != nil else { return result }
        let asWritten = readings(plain, pass: 0), alternatives = readings(corrected, pass: 1)
        result.text = asWritten.first?.text ?? alternatives.first?.text
        result.readings = asWritten + alternatives
        return result
    }

    private static func request(correcting: Bool, names: [String]) -> VNRecognizeTextRequest {
        let request = VNRecognizeTextRequest()
        request.revision = VNRecognizeTextRequestRevision3
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = correcting   // off: names aren't dictionary words; on: alternatives, class list first
        if correcting {
            let words = Set(names.flatMap { $0.split { !$0.isLetter && $0 != "'" && $0 != "-" }.map(String.init) })
            request.customWords = Array(words.union(words.map { $0.folding(options: [.diacriticInsensitive], locale: nil) })).sorted()
        }
        let wanted = ["en-US", "es-ES"]
        if let supported = try? request.supportedRecognitionLanguages() {
            request.recognitionLanguages = wanted.filter(supported.contains)
        }
        return request
    }

    /// Whole-name readings, left to right: each piece of writing's alternatives combined, most confident first.
    private static func readings(_ request: VNRecognizeTextRequest, pass: Int) -> [NameMatch.Reading] {
        var beam = [NameMatch.Reading(text: "", confidence: 1, pass: pass)]
        for observation in (request.results ?? []).sorted(by: { $0.boundingBox.minX < $1.boundingBox.minX }) {
            let candidates = observation.topCandidates(10)
            guard !candidates.isEmpty else { continue }
            var longer: [NameMatch.Reading] = []
            for sofar in beam {
                for candidate in candidates {
                    let text = sofar.text.isEmpty ? candidate.string : sofar.text + " " + candidate.string
                    longer.append(NameMatch.Reading(text: text, confidence: sofar.confidence * Double(candidate.confidence), pass: pass))
                }
            }
            beam = Array(longer.sorted { $0.confidence > $1.confidence }.prefix(12))
        }
        return beam.compactMap { r in clean(r.text).map { NameMatch.Reading(text: $0, confidence: r.confidence, pass: pass) } }
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

extension GrayStrip {
    /// The strip on a white margin a third of its height wide.
    func padded() -> GrayStrip {
        let m = max(8, height / 3), w = width + 2 * m, h = height + 2 * m
        var out = [UInt8](repeating: 255, count: w * h)
        for y in 0..<height {
            let from = y * width, to = (y + m) * w + m
            out.replaceSubrange(to..<(to + width), with: pixels[from..<(from + width)])
        }
        return GrayStrip(width: w, height: h, pixels: out)
    }
}
