import CoreGraphics
import Foundation
import Vision

/// Reads a Jupiter class page from a photo: the names (listed "Last, First") and which period is selected.
enum RosterReader {
    struct Page {
        let names: [String]
        let period: Int?   // the selected class's period (highlighted in Jupiter's list on the left), when it's clear
    }

    /// A photo or screenshot. `image` must be upright.
    static func read(_ image: CGImage) async -> Page {
        await Task.detached(priority: .userInitiated) { readNow(image, live: false) }.value
    }

    /// Reads an upright image on the calling thread (keep it off the main one). `live`: a camera frame, where a line
    /// touching the frame's edge may be cut off, so it's left out.
    static func readNow(_ image: CGImage, live: Bool) -> Page {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        let wanted = ["en-US", "es-ES"]
        if let supported = try? request.supportedRecognitionLanguages() { request.recognitionLanguages = wanted.filter(supported.contains) }
        guard (try? VNImageRequestHandler(cgImage: image, orientation: .up).perform([request])) != nil else { return Page(names: [], period: nil) }
        let lines = (request.results ?? []).compactMap { o in o.topCandidates(1).first.map { Line(text: $0.string, box: o.boundingBox) } }
        let whole = live ? lines.filter { $0.box.minX > 0.015 && $0.box.maxX < 0.985 && $0.box.minY > 0.015 && $0.box.maxY < 0.985 } : lines
        return Page(names: parse(whole.map(\.text)), period: selectedPeriod(lines, in: image))
    }

    /// A line of text and where it is (normalized, origin at the bottom left, as Vision gives it).
    struct Line {
        let text: String
        let box: CGRect
    }

    /// Words from Jupiter's menus and buttons, which can read like "Help, Logout".
    static let menuWords: Set<String> = ["help", "logout", "copy", "delete", "new", "update", "revert", "done", "post", "grades", "roll",
                                         "log", "reports", "more", "setup", "attach", "rubric", "period", "student", "score", "comment",
                                         "find", "fill", "due", "worth", "category", "directions", "mean", "range", "count", "points"]

    /// "Garcia, Lena" → "Lena Garcia". Keeps hyphens, accents and middle names; drops scores, headers and menus.
    static func parse(_ lines: [String]) -> [String] {
        var seen = Set<String>(), out: [String] = []
        for line in lines {
            let text = String(line.prefix { !$0.isNumber })   // a score read on the same line
                .trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: ",.")))
            let parts = text.split(separator: ",", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else { continue }
            let allowed = CharacterSet.letters.union(CharacterSet(charactersIn: " -'’."))
            guard parts.allSatisfy({ $0.unicodeScalars.allSatisfy(allowed.contains) }) else { continue }
            let words = parts.flatMap { $0.split(separator: " ") }
            guard (2...6).contains(words.count), words.allSatisfy({ $0.count >= 2 || $0.hasSuffix(".") }),
                  !words.contains(where: { menuWords.contains($0.lowercased()) }) else { continue }
            let name = "\(parts[1]) \(parts[0])"
            if seen.insert(name.lowercased()).inserted { out.append(name) }
        }
        return out
    }

    /// The period a line names: "Period 9", "Per. 9", "P9", "Period #9", "9th Period".
    static func period(in text: String) -> Int? {
        for pattern in [#"(?i)\b(?:period|per\.?|pd\.?|p)\s*#?\s*\d{1,2}\b"#, #"(?i)\b\d{1,2}(?:st|nd|rd|th)?\s+period\b"#] {
            if let match = text.range(of: pattern, options: .regularExpression), let n = Int(text[match].filter(\.isNumber)), (1...9).contains(n) {
                return n
            }
        }
        return nil
    }

    /// The selected class's period. Jupiter lists the classes down the left with the open one highlighted, so when
    /// several periods show, it's the one whose background stands out; nil when that isn't clear.
    static func selectedPeriod(_ lines: [Line], in image: CGImage) -> Int? {
        let mentions = lines.compactMap { line in period(in: line.text).map { (period: $0, box: line.box) } }
        let periods = Set(mentions.map(\.period))
        guard periods.count > 1 else { return periods.first }
        guard let pixels = Pixels(image) else { return nil }
        let colors = mentions.map { pixels.median(in: $0.box) }
        let distances: [Double]
        if mentions.count >= 3 {
            // How much each differs from the two classes listed nearest it (the highlight differs from both;
            // light falling unevenly across a photo changes neighbors together).
            let center = mentions.map { CGPoint(x: $0.box.midX, y: $0.box.midY) }
            distances = mentions.indices.map { i in
                let near = mentions.indices.filter { $0 != i }
                    .sorted { hypot(center[$0].x - center[i].x, center[$0].y - center[i].y) < hypot(center[$1].x - center[i].x, center[$1].y - center[i].y) }
                    .prefix(2)
                return near.map { colors[i].distance(to: colors[$0]) }.min() ?? 0
            }
        } else {
            let page = pixels.median(in: CGRect(x: 0, y: 0, width: 1, height: 1))
            distances = colors.map { $0.distance(to: page) }
        }
        let order = distances.indices.sorted { distances[$0] > distances[$1] }
        let best = order[0]
        let runnerUp = order.dropFirst().first { mentions[$0].period != mentions[best].period }.map { distances[$0] } ?? 0
        if distances[best] >= 12 && distances[best] >= 2.5 * runnerUp { return mentions[best].period }
        // No clear highlight: a period named more often than any other (the list and the page title) is the one open.
        let counts = Dictionary(grouping: mentions, by: \.period).mapValues(\.count).sorted { $0.value > $1.value }
        return counts.count > 1 && counts[0].value >= 2 && counts[0].value > counts[1].value ? counts[0].key : nil
    }

    private struct Color {
        let r: Double, g: Double, b: Double
        func distance(to o: Color) -> Double { ((r - o.r) * (r - o.r) + (g - o.g) * (g - o.g) + (b - o.b) * (b - o.b)).squareRoot() }
        static func median(_ list: [Color]) -> Color {
            func mid(_ v: [Double]) -> Double { let s = v.sorted(); return s[s.count / 2] }
            return Color(r: mid(list.map(\.r)), g: mid(list.map(\.g)), b: mid(list.map(\.b)))
        }
    }

    /// The image as RGB, at most 1200 pixels wide.
    private struct Pixels {
        let width: Int, height: Int
        let data: [UInt8]

        init?(_ image: CGImage) {
            let scale = min(1, 1200 / Double(image.width))
            let w = max(1, Int(Double(image.width) * scale)), h = max(1, Int(Double(image.height) * scale))
            var buffer = [UInt8](repeating: 0, count: w * h * 4)
            let drawn = buffer.withUnsafeMutableBytes { raw -> Bool in
                guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
                ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
                return true
            }
            guard drawn else { return nil }
            (width, height, data) = (w, h, buffer)
        }

        /// The median color in a box (normalized, origin at the bottom left): its background, since text covers less.
        func median(in box: CGRect) -> Color {
            let grow = box.height * 0.3
            let x0 = max(0, Int((box.minX) * Double(width))), x1 = min(width - 1, Int(box.maxX * Double(width)))
            let y0 = max(0, Int((1 - box.maxY - grow) * Double(height))), y1 = min(height - 1, Int((1 - box.minY + grow) * Double(height)))
            guard x1 >= x0, y1 >= y0 else { return Color(r: 255, g: 255, b: 255) }
            let step = max(1, Int((Double((x1 - x0 + 1) * (y1 - y0 + 1)) / 4000).squareRoot()))
            var r: [Double] = [], g: [Double] = [], b: [Double] = []
            for y in stride(from: y0, through: y1, by: step) {
                for x in stride(from: x0, through: x1, by: step) {
                    let i = (y * width + x) * 4
                    r.append(Double(data[i])); g.append(Double(data[i + 1])); b.append(Double(data[i + 2]))
                }
            }
            func mid(_ v: [Double]) -> Double { let s = v.sorted(); return s[s.count / 2] }
            return Color(r: mid(r), g: mid(g), b: mid(b))
        }
    }
}

/// Settles what the live camera reads off a Jupiter page over several frames. A name counts once it's been read in
/// two frames. Misread spellings join the name they're closest to and are voted on letter by letter, but two names
/// read in the same frame are always two students ("Aidan Lee" and "Aiden Lee"). The page is steady once three
/// frames in a row change nothing. Opening another class (a different period, seen in two frames running) starts
/// over, and so does the camera leaving the page.
struct RosterConsensus {
    private(set) var names: [String] = []   // confirmed, alphabetical
    private(set) var period: Int?
    private(set) var steady = false

    private struct Cluster {
        var spellings: [String: Int]
        var seen: Int
        /// The most common length of spelling, then the most common letter at each place: three different one-letter
        /// slips still vote the right spelling back in.
        var name: String { vote.name }
        /// Whether some place is a tie, so more frames are needed to tell the spelling.
        var tied: Bool { vote.tied }

        private var vote: (name: String, tied: Bool) {
            let lengths = Dictionary(grouping: spellings, by: { $0.key.count }).mapValues { $0.reduce(0) { $0 + $1.value } }
            guard let length = lengths.max(by: { $0.value < $1.value || ($0.value == $1.value && $0.key < $1.key) })?.key else { return ("", false) }
            var tied = lengths.filter { $0.value == lengths[length] }.count > 1
            let words = spellings.filter { $0.key.count == length }.map { (letters: Array($0.key), count: $0.value) }
            let name = String((0..<length).map { i -> Character in
                var votes: [Character: Int] = [:]
                for word in words { votes[word.letters[i], default: 0] += word.count }
                let ranked = votes.sorted { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) }
                if ranked.count > 1 && ranked[0].value == ranked[1].value { tied = true }
                return ranked.first?.key ?? " "
            })
            return (name, tied)
        }
    }
    private var clusters: [Cluster] = []
    private var unchanged = 0
    private var blank = 0
    private var otherPeriod: (value: Int, frames: Int)?

    static let confirmations = 2
    static let steadyFrames = 3

    /// Adds one reading. `still`: a photo or screenshot, read once, so everything on it counts right away.
    mutating func add(_ page: RosterReader.Page, still: Bool = false) {
        if still { self = RosterConsensus() }
        guard !page.names.isEmpty else {
            blank += 1
            if blank >= 3 { self = RosterConsensus() }
            return
        }
        blank = 0
        if let p = page.period, p != period {
            if period == nil {
                period = p
            } else {
                let frames = otherPeriod?.value == p ? (otherPeriod?.frames ?? 0) + 1 : 1
                otherPeriod = (p, frames)
                if frames >= 2 {
                    self = RosterConsensus()
                    period = p
                }
            }
        } else if page.period != nil {
            otherPeriod = nil
        }
        var matched = Set<Int>()   // clusters this frame has already added to
        for name in page.names {
            let words = NameMatch.tokens(name)
            let nearest = clusters.indices.filter { !matched.contains($0) }
                .map { ($0, NameMatch.distance(words, NameMatch.tokens(clusters[$0].name))) }.min { $0.1 < $1.1 }
            if let (i, d) = nearest, d <= 0.2 {
                clusters[i].spellings[name, default: 0] += 1
                clusters[i].seen += 1
                matched.insert(i)
            } else {
                clusters.append(Cluster(spellings: [name: 1], seen: 1))
                matched.insert(clusters.count - 1)
            }
        }
        let confirmed = clusters.filter { still || $0.seen >= Self.confirmations }.map(\.name)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        if confirmed == names { unchanged += 1 } else { unchanged = 0; names = confirmed }
        let settled = clusters.allSatisfy { $0.seen < Self.confirmations || !$0.tied }
        steady = !names.isEmpty && (still || (unchanged >= Self.steadyFrames && settled))
    }
}
