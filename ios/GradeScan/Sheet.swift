import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Where everything sits on a test's answer sheet, in inches from the sheet's top-left corner.
/// The portal saves it with each test (quizzes.layout), so the phone reads exactly what was printed.
struct SheetLayout: Codable, Sendable {
    let w: Double
    let h: Double
    let fid: Double              // side of the solid black squares
    let r: Double                // bubble radius
    let corners: [[Double]]      // square centers: top-left, top-right, bottom-right, bottom-left
    let marker: [Double]         // extra square on the left edge, which tells up from down
    let questions: [[[Double]]]  // bubble centers per question, one per answer choice
    let period: [[Double]]       // bubble centers for periods 1–9
    let name: [Double]           // handwritten name area: x, y, width, height
    var periodBox: [Double]? = nil   // a handwritten period box instead of bubbles (ZipGrade): x, y, width, height

    var cornerPoints: [CGPoint] { corners.map(Self.point) }

    /// Rings just outside a bubble where strokes leaving it (an X over it) are looked for, in bubble radii: clear
    /// of its own printed circle and of the neighboring bubbles, which sit closer together on some sheets.
    var armsRadii: [Double] {
        guard let row = questions.first, row.count > 1, r > 0 else { return [1.35, 1.5] }
        let neighbor = hypot(row[1][0] - row[0][0], row[1][1] - row[0][1]) / r - 1   // where the next circle begins
        return neighbor >= 1.7 ? [1.35, 1.5] : [1.1, max(1.12, min(1.35, neighbor - 0.1))]
    }

    /// How dark a stroke past the circle must be to count. Where printed grey circles sit close by (ZipGrade),
    /// only pen and pencil dark enough to stand out from them count.
    var armsContrast: Double {
        armsRadii == [1.35, 1.5] ? Reader.inkContrast : 0.4
    }
    var markerPoint: CGPoint { Self.point(marker) }

    func bubble(_ question: Int, _ choice: Int) -> CGPoint? {
        guard question < questions.count, choice < questions[question].count else { return nil }
        return Self.point(questions[question][choice])
    }

    /// Whether this layout has everything the scanner needs for a test of this size.
    func fits(questions n: Int, choices c: Int) -> Bool {
        corners.count == 4 && corners.allSatisfy { $0.count == 2 } && marker.count == 2 && name.count == 4
            && period.allSatisfy { $0.count == 2 }
            && questions.count >= n && questions.prefix(n).allSatisfy { $0.count >= c && $0.allSatisfy { $0.count == 2 } }
    }

    static func point(_ p: [Double]) -> CGPoint { p.count == 2 ? CGPoint(x: p[0], y: p[1]) : .zero }
}

/// Perspective transform fitted to four point pairs (sheet inches → image point).
struct Homography: Sendable {
    private let a, b, c, d, e, f, g, h: Double

    init?(_ from: [CGPoint], _ to: [CGPoint]) {
        guard from.count == 4, to.count == 4 else { return nil }
        // Solved on the stack: the sheet search fits hundreds of these per camera frame.
        let solution: [Double]? = withUnsafeTemporaryAllocation(of: Double.self, capacity: 72) { m in
            for k in 0..<4 {
                let u = Double(from[k].x), v = Double(from[k].y), x = Double(to[k].x), y = Double(to[k].y)
                let r0 = 18 * k, r1 = r0 + 9
                m[r0] = u; m[r0 + 1] = v; m[r0 + 2] = 1; m[r0 + 3] = 0; m[r0 + 4] = 0; m[r0 + 5] = 0
                m[r0 + 6] = -u * x; m[r0 + 7] = -v * x; m[r0 + 8] = x
                m[r1] = 0; m[r1 + 1] = 0; m[r1 + 2] = 0; m[r1 + 3] = u; m[r1 + 4] = v; m[r1 + 5] = 1
                m[r1 + 6] = -u * y; m[r1 + 7] = -v * y; m[r1 + 8] = y
            }
            for col in 0..<8 {
                var pivot = col
                for row in col + 1 ..< 8 where abs(m[row * 9 + col]) > abs(m[pivot * 9 + col]) { pivot = row }
                guard abs(m[pivot * 9 + col]) > 1e-12 else { return nil }
                if pivot != col { for k in 0..<9 { m.swapAt(col * 9 + k, pivot * 9 + k) } }
                let p = m[col * 9 + col]
                for row in 0..<8 where row != col {
                    let factor = m[row * 9 + col] / p
                    if factor != 0 { for k in col..<9 { m[row * 9 + k] -= factor * m[col * 9 + k] } }
                }
            }
            return (0..<8).map { m[$0 * 9 + 8] / m[$0 * 9 + $0] }
        }
        guard let s = solution, s.allSatisfy(\.isFinite) else { return nil }
        (a, b, c, d, e, f, g, h) = (s[0], s[1], s[2], s[3], s[4], s[5], s[6], s[7])
    }

    func apply(_ p: CGPoint) -> CGPoint {
        let u = Double(p.x), v = Double(p.y), w = g * u + h * v + 1
        return CGPoint(x: (a * u + b * v + c) / w, y: (d * u + e * v + f) / w)
    }
}

/// Luminance plane of a camera frame. Points are normalized (0–1, top-left origin).
struct LumaImage {
    let base: UnsafeMutablePointer<UInt8>
    let width: Int
    let height: Int
    let bytesPerRow: Int

    /// Average of the 3×3 pixels around a point, or 0 outside the frame.
    func at(_ p: CGPoint) -> Double {
        guard p.x >= 0, p.x < 1, p.y >= 0, p.y < 1 else { return 0 }
        let x = Int(p.x * CGFloat(width)), y = Int(p.y * CGFloat(height))
        guard x > 0, y > 0, x < width - 1, y < height - 1 else { return 0 }
        var sum = 0
        for dy in -1...1 {
            let row = base + (y + dy) * bytesPerRow
            for dx in -1...1 { sum += Int(row[x + dx]) }
        }
        return Double(sum) / 9
    }

    /// Bilinear sample at a point, or nil outside the frame.
    func smooth(_ p: CGPoint) -> Double? {
        let x = Double(p.x) * Double(width) - 0.5, y = Double(p.y) * Double(height) - 0.5
        guard x >= 0, y >= 0, x < Double(width - 1), y < Double(height - 1) else { return nil }
        let x0 = Int(x), y0 = Int(y), fx = x - Double(x0), fy = y - Double(y0)
        let top = base + y0 * bytesPerRow + x0, bottom = top + bytesPerRow
        let upper = Double(top[0]) * (1 - fx) + Double(top[1]) * fx
        let lower = Double(bottom[0]) * (1 - fx) + Double(bottom[1]) * fx
        return upper * (1 - fy) + lower * fy
    }
}

/// A small grayscale picture, such as the straightened handwritten name.
struct GrayStrip: Sendable {
    let width: Int
    let height: Int
    let pixels: [UInt8]

    func cgImage() -> CGImage? {
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    /// A coarse 16×2 picture of the strip (0 = ink, 1 = paper), used to tell two sheets apart.
    func signature() -> [Double] {
        let cols = 16, rows = 2
        var sums = [Double](repeating: 0, count: cols * rows), counts = [Int](repeating: 0, count: cols * rows)
        for y in 0..<height {
            for x in 0..<width {
                let cell = (y * rows / height) * cols + x * cols / width
                sums[cell] += Double(pixels[y * width + x]) / 255
                counts[cell] += 1
            }
        }
        return zip(sums, counts).map { $1 > 0 ? $0 / Double($1) : 1 }
    }

    /// How different two signatures are: 0 for the same picture, larger for different handwriting.
    static func difference(_ a: [Double], _ b: [Double]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 1 }
        return zip(a, b).reduce(0) { $0 + abs($1.0 - $1.1) } / Double(a.count)
    }

    /// JPEG as a data URL, ready to store in the scans table and show in the portal.
    func jpegDataURL(quality: Double = 0.7) -> String? {
        guard let image = cgImage() else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return "data:image/jpeg;base64," + (data as Data).base64EncodedString()
    }
}

enum Reader {
    /// A point counts as ink when it's this much darker than the paper around its bubble.
    static let inkContrast = 0.3
    /// Share of a bubble's inside that must be ink, above the emptiest bubble in its row, to count as marked.
    /// Raise it if erasures or stray marks read as answers; lower it if light marks are missed.
    static let markLevel = 0.2
    /// Enough for an X mark to count; for anything else, between this and `markLevel` is too light to call: "?".
    static let faintLevel = 0.1

    /// The test code printed as 16 small squares between the bottom corner squares (see `codeBits` in the portal),
    /// or nil if it doesn't read cleanly. `unit` maps corner-to-corner coordinates to normalized image points.
    static func testCode(_ img: LumaImage, _ unit: Homography) -> Int? { code(img, unit, row: 1) }

    /// The student number on a named sheet, printed the same way between the top corner squares.
    static func studentNumber(_ img: LumaImage, _ unit: Homography) -> Int? { code(img, unit, row: 0) }

    private static func code(_ img: LumaImage, _ unit: Homography, row v: Double) -> Int? {
        let width = Double(img.width), height = Double(img.height)
        var word = 0
        for i in 0..<16 {
            let u = 0.2 + Double(i) * 0.04
            let c = unit.apply(CGPoint(x: u, y: v)), next = unit.apply(CGPoint(x: u + 0.04, y: v))
            let pitch = hypot((next.x - c.x) * width, (next.y - c.y) * height)   // pixels between neighboring squares
            let at: (Double, Double) -> Double = { dx, dy in img.at(CGPoint(x: c.x + dx / width, y: c.y + dy / height)) }
            let r = 0.12 * pitch, ring = 0.5 * pitch
            let ink = (at(0, 0) + at(r, 0) + at(-r, 0) + at(0, r) + at(0, -r)) / 5
            let paper = (0..<8).reduce(0.0) { best, k in
                let a = Double(k) * .pi / 4
                return max(best, at(ring * cos(a), ring * sin(a)))
            }
            guard paper > 0 else { return nil }
            if 1 - ink / paper >= 0.35 { word |= 1 << i }
        }
        let code = word & 4095, check = word >> 12
        guard code > 0, check == (code & 15) ^ ((code >> 4) & 15) ^ ((code >> 8) & 15) ^ 10 else { return nil }
        return code
    }

    // Sample points for a bubble of radius 1: its whole inside out to 0.7 (clear of the printed circle),
    // and a ring of paper just outside it.
    private static let disk: [CGPoint] = {
        var points = [CGPoint.zero]
        for (radius, count, turn) in [(0.2, 6, 0.0), (0.4, 12, 0.5), (0.55, 16, 0.0), (0.7, 20, 0.5)] {
            for k in 0..<count {
                let a = (Double(k) + turn) * 2 * .pi / Double(count)
                points.append(CGPoint(x: radius * cos(a), y: radius * sin(a)))
            }
        }
        return points
    }()
    private static let ring: [CGPoint] = (0..<12).map { k in
        let a = Double(k) * .pi / 6
        return CGPoint(x: 1.6 * cos(a), y: 1.6 * sin(a))
    }
    private static let spokes = 36   // directions sampled around a bubble to find straight strokes

    /// What's in one bubble.
    struct Bubble {
        var coverage: Double   // share of the inside that is ink, 0–1
        var tone: Double       // how dark that ink is, 0–1; an erased pencil mark is much lighter than a real one
        var crossedOut: Bool   // strokes leave it in three or more directions (an X over it) or on two opposite sides (a slash)
        var xMark: Bool        // the mark itself is an X: a few crossing strokes, not a fill
        var circled: Bool      // ink all around just outside the printed circle: the bubble was circled
        var arms: Int          // directions strokes leave it in, past the printed circle (an X over it has 3 or 4)
        static let empty = Bubble(coverage: 0, tone: 0, crossedOut: false, xMark: false, circled: false, arms: 0)
    }

    static func inspect(_ c: CGPoint, radius r: Double, _ img: LumaImage, _ h: Homography, arms armsRadii: [Double] = [1.35, 1.5],
                        armsContrast: Double = inkContrast) -> Bubble {
        let luma: (Double, Double) -> Double? = { x, y in img.smooth(h.apply(CGPoint(x: c.x + r * x, y: c.y + r * y))) }
        let paper = ring.reduce(0.0) { max($0, luma($1.x, $1.y) ?? 0) }
        guard paper > 0 else { return .empty }
        let ink: (Double, Double) -> Double = { x, y in max(0, 1 - (luma(x, y) ?? paper) / paper) }
        let inside = disk.map { ink($0.x, $0.y) }.filter { $0 > inkContrast }
        let around: ([Double], Double) -> [Bool] = { radii, contrast in
            (0..<spokes).map { k in
                let a = Double(k) * 2 * .pi / Double(spokes)
                return radii.contains { ink($0 * cos(a), $0 * sin(a)) > contrast }
            }
        }
        let coverage = Double(inside.count) / Double(disk.count)
        // Past the printed circle, far enough out that the circle itself doesn't show up when the sheet is a little
        // off. A fill that spills over leaves on one side; an X drawn over the bubble leaves in three or more
        // directions; a slash leaves on two opposite sides; a circle drawn around it is all around.
        let outer = around(armsRadii, armsContrast), leaving = runs(outer).filter { $0.length <= 6 }   // strokes, not a printed circle
        let opposite = leaving.count == 2 && leaving.allSatisfy { $0.length <= 2 }
            && abs(angularDistance(leaving[0].center, leaving[1].center) - Double(spokes / 2)) <= 3
        // Inside: an X crosses a ring around the middle in three to five short strokes; a fill, scribble or loop
        // covers much more of it.
        let xMark = coverage <= 0.35 && [0.5, 0.65].contains { radius in
            let circle = around([radius], inkContrast), strokes = runs(circle)
            return share(circle) <= 0.4 && (3...5).contains(strokes.count) && strokes.allSatisfy { $0.length <= 8 }
        }
        return Bubble(coverage: coverage, tone: inside.isEmpty ? 0 : inside.reduce(0, +) / Double(inside.count),
                      crossedOut: share(outer) <= 0.45 && (directions(leaving) >= 3 || opposite),
                      xMark: xMark, circled: share(outer) >= 0.6, arms: directions(leaving))
    }

    private static func share(_ around: [Bool]) -> Double { Double(around.filter { $0 }.count) / Double(max(1, around.count)) }

    /// Runs of ink around a ring: the spoke at the middle of each run and how many spokes it covers.
    static func runs(_ around: [Bool]) -> [(center: Double, length: Int)] {
        let n = around.count
        guard n > 0 else { return [] }
        guard let start = around.firstIndex(of: false) else { return [(center: 0, length: n)] }
        var out: [(center: Double, length: Int)] = []
        var length = 0
        for step in 1...n {
            if around[(start + step) % n] {
                length += 1
            } else if length > 0 {
                let first = Double(start + step - length)
                out.append((center: (first + Double(length - 1) / 2).truncatingRemainder(dividingBy: Double(n)), length: length))
                length = 0
            }
        }
        return out
    }

    /// How many clearly different directions (at least 60° apart) the runs point in.
    static func directions(_ runs: [(center: Double, length: Int)]) -> Int {
        var picked: [Double] = []
        for run in runs.sorted(by: { $0.length > $1.length }) where picked.allSatisfy({ angularDistance($0, run.center) >= Double(spokes) / 6 }) {
            picked.append(run.center)
        }
        return picked.count
    }

    private static func angularDistance(_ a: Double, _ b: Double) -> Double {
        let d = abs(a - b).truncatingRemainder(dividingBy: Double(spokes))
        return min(d, Double(spokes) - d)
    }

    /// Bubbles in a row with visible ink (marks, X's, faint marks, circles), for rows `choose` couldn't call.
    static func inked(_ b: [Bubble]) -> [Int] {
        let base = min(0.2, b.map(\.coverage).min() ?? 0)
        return b.indices.filter { b[$0].coverage - base >= faintLevel || b[$0].circled || (b[$0].coverage - base >= 0.05 && (b[$0].xMark || b[$0].crossedOut)) }
    }

    /// Which bubble in a row is the answer: its index, -1 blank, -2 rejected (more than one answer), -3 can't tell.
    /// It never guesses: anything ambiguous is -2 or -3, which score no credit and are flagged for review.
    ///
    /// - One real mark (fill, scribble, loop, check) is the answer, even with X's or crossed-out fills elsewhere,
    ///   as long as it's a solid mark and not a smudge.
    /// - A lone X is the answer. X's on two or more bubbles: rejected.
    /// - A filled bubble with an X or slash through it doesn't count. If that's all there is: can't tell.
    /// - Two real marks: if one is much lighter it's an erasure and the darker one is the answer; similar tone:
    ///   rejected; in between: can't tell.
    /// - A small stray mark next to a real one is ignored. A faint mark or a circled bubble on its own: can't tell.
    ///
    /// Coverage is measured above the row's emptiest bubble, which cancels out printed circles and uneven light.
    static func choose(_ b: [Bubble]) -> Int {
        guard !b.isEmpty else { return -1 }
        let base = min(0.2, b.map(\.coverage).min() ?? 0)
        let score = b.map { max(0, $0.coverage - base) }
        let xs = b.indices.filter { score[$0] >= faintLevel && b[$0].coverage <= 0.35 && (b[$0].xMark || b[$0].crossedOut) }
        let cancelled = b.indices.filter { score[$0] >= markLevel && b[$0].coverage > 0.35 && b[$0].crossedOut }
        var live = b.indices.filter { score[$0] >= markLevel && !xs.contains($0) && !cancelled.contains($0) }
        let unsure = b.indices.filter { !xs.contains($0) && score[$0] < markLevel
            && (score[$0] >= faintLevel || b[$0].circled || (score[$0] >= 0.05 && (b[$0].xMark || b[$0].crossedOut))) }
        if live.isEmpty {
            if xs.count >= 2 { return -2 }
            if xs.count == 1 && cancelled.isEmpty && unsure.isEmpty { return xs[0] }
            return xs.isEmpty && cancelled.isEmpty && unsure.isEmpty ? -1 : -3
        }
        if let biggest = live.max(by: { score[$0] < score[$1] }) {
            // A small mark next to a real one is a stray, unless it's much darker: then the big one may be the
            // erasure, and there's no telling which is the answer.
            let small = live.filter { $0 != biggest && score[$0] < 0.35 * score[biggest] }
            if small.contains(where: { b[biggest].tone <= 0.7 * b[$0].tone }) { return -3 }
            live = live.filter { !small.contains($0) }
        }
        // Of two fills, one with strokes leaving it in two or more directions, when the other has none and isn't
        // much lighter, was crossed out.
        if live.count > 1 {
            let clean = live.filter { b[$0].arms == 0 }
            if clean.count == 1, live.allSatisfy({ $0 == clean[0] || (b[$0].arms >= 2 && b[clean[0]].tone >= 0.7 * b[$0].tone) }) {
                live = clean
            }
        }
        if live.count > 1 {
            guard let darkest = live.max(by: { b[$0].tone < b[$1].tone }) else { return -3 }
            let lighter = live.filter { $0 != darkest }.map { b[$0].tone / max(b[darkest].tone, 0.001) }
            guard lighter.allSatisfy({ $0 <= 0.7 }) else { return lighter.contains { $0 > 0.85 } ? -2 : -3 }
            live = [darkest]
        }
        let answer = live[0]
        if (!xs.isEmpty || !cancelled.isEmpty) && score[answer] < 0.35 { return -3 }
        return answer
    }

    /// Period (nil if not marked clearly) and one character per question: A–E, "-" blank, "*" rejected (more than one
    /// answer), "?" can't tell. With `align` (for the photo), bubbles are first nudged onto their printed circles.
    static func read(_ quiz: Quiz, _ layout: SheetLayout, _ img: LumaImage, _ h: Homography, align: Bool = false) -> (period: Int?, answers: String, marks: [Int: String]) {
        let r = layout.r, arms = layout.armsRadii, armsContrast = layout.armsContrast
        let rows = [layout.period] + layout.questions.prefix(min(quiz.numQuestions, layout.questions.count)).map { Array($0.prefix(min(quiz.numChoices, 5))) }
        let fix = align ? correction(rows.flatMap { $0.map(SheetLayout.point) }, radius: r, img, h) : { _ in .zero }
        let bubbles: ([[Double]]) -> [Bubble] = { centers in
            centers.map(SheetLayout.point).map { c in
                let d = fix(c)
                return inspect(CGPoint(x: c.x + d.x, y: c.y + d.y), radius: r, img, h, arms: arms, armsContrast: armsContrast)
            }
        }
        let p = rows[0].isEmpty ? -1 : choose(bubbles(rows[0]))
        var answers = "", marks: [Int: String] = [:]
        for (q, row) in rows.dropFirst().enumerated() {
            let b = bubbles(row), k = choose(b)
            answers.append(k >= 0 ? Grader.letters[k] : k == -1 ? "-" : k == -2 ? "*" : "?")
            if k < -1 { marks[q] = String(inked(b).map { Grader.letters[$0] }) }
        }
        return (p >= 0 ? p + 1 : nil, answers, marks)
    }

    /// The corners place bubbles to within a pixel or two; this measures the leftover error on the empty bubbles
    /// (their printed circles are a clean signal) and fits one smooth correction for the whole sheet, so marks on
    /// a bubble never pull it off its circle.
    static func correction(_ centers: [CGPoint], radius r: Double, _ img: LumaImage, _ h: Homography) -> (CGPoint) -> CGPoint {
        // Bubbles under about 18 pixels across the radius are too soft to line up any better than the corners do.
        if let c = centers.first {
            let a = h.apply(c), b = h.apply(CGPoint(x: c.x + r, y: c.y))
            if hypot(Double(b.x - a.x) * Double(img.width), Double(b.y - a.y) * Double(img.height)) < 18 { return { _ in .zero } }
        }
        let empty = centers.filter { inspect($0, radius: r, img, h).coverage < 0.08 }
        guard empty.count >= 8 else { return { _ in .zero } }
        let measured = empty.map { (at: $0, shift: offset($0, radius: r, img, h)) }
        guard let fx = fitPlane(measured.map { ($0.at, Double($0.shift.x)) }),
              let fy = fitPlane(measured.map { ($0.at, Double($0.shift.y)) }) else { return { _ in .zero } }
        let limit = 0.2 * r
        return { p in
            CGPoint(x: max(-limit, min(limit, fx.0 + fx.1 * Double(p.x) + fx.2 * Double(p.y))),
                    y: max(-limit, min(limit, fy.0 + fy.1 * Double(p.x) + fy.2 * Double(p.y))))
        }
    }

    /// Least-squares fit of value = a + b·x + c·y.
    private static func fitPlane(_ samples: [(CGPoint, Double)]) -> (Double, Double, Double)? {
        var m = [[Double]](repeating: [0, 0, 0, 0], count: 3)
        for (p, v) in samples {
            let row = [1, Double(p.x), Double(p.y)]
            for i in 0..<3 {
                for j in 0..<3 { m[i][j] += row[i] * row[j] }
                m[i][3] += row[i] * v
            }
        }
        let det: ([[Double]]) -> Double = { a in
            a[0][0] * (a[1][1] * a[2][2] - a[1][2] * a[2][1]) - a[0][1] * (a[1][0] * a[2][2] - a[1][2] * a[2][0])
                + a[0][2] * (a[1][0] * a[2][1] - a[1][1] * a[2][0])
        }
        let base = m.map { Array($0.prefix(3)) }, d = det(base)
        guard abs(d) > 1e-9 else { return nil }
        let solve: (Int) -> Double = { col in det(base.enumerated().map { i, row in row.enumerated().map { j, v in j == col ? m[i][3] : v } }) / d }
        return (solve(0), solve(1), solve(2))
    }

    /// How far (in sheet inches) a bubble's printed circle sits from where the corners put it: the shift, within a
    /// quarter of the radius, that puts the most ink on the circle and the least just inside and outside it.
    static func offset(_ c: CGPoint, radius r: Double, _ img: LumaImage, _ h: Homography) -> CGPoint {
        var best = CGPoint.zero, bestScore = -Double.infinity
        let step = 0.08 * r
        for dy in -3...3 {
            for dx in -3...3 {
                let x0 = c.x + Double(dx) * step, y0 = c.y + Double(dy) * step
                var score = 0.0
                for k in 0..<24 {
                    let a = Double(k) * .pi / 12, ux = cos(a), uy = sin(a)
                    let luma: (Double) -> Double = { img.smooth(h.apply(CGPoint(x: x0 + $0 * r * ux, y: y0 + $0 * r * uy))) ?? 0 }
                    score += (luma(0.78) + luma(1.22)) / 2 - luma(1)
                }
                if score > bestScore { bestScore = score; best = CGPoint(x: Double(dx) * step, y: Double(dy) * step) }
            }
        }
        return best
    }

    /// The handwritten name, straightened and contrast-stretched so paper is white and ink is black.
    static func nameStrip(_ layout: SheetLayout, _ img: LumaImage, _ h: Homography, pixelsPerInch ppi: Double = 150) -> GrayStrip? {
        strip(layout.name, img, h, pixelsPerInch: ppi)
    }

    /// A handwritten box (the name, or ZipGrade's period), straightened and contrast-stretched.
    static func strip(_ box: [Double], _ img: LumaImage, _ h: Homography, pixelsPerInch ppi: Double = 150) -> GrayStrip? {
        guard box.count == 4 else { return nil }
        let x0 = box[0], y0 = box[1]
        let width = Int(box[2] * ppi), height = Int(box[3] * ppi)
        guard width > 0, height > 0 else { return nil }
        var values = [UInt8](repeating: 255, count: width * height)
        var histogram = [Int](repeating: 0, count: 256)
        for v in 0..<height {
            for u in 0..<width {
                let p = h.apply(CGPoint(x: x0 + (Double(u) + 0.5) / ppi, y: y0 + (Double(v) + 0.5) / ppi))
                guard let value = img.smooth(p) else { return nil }   // part of the name is out of view
                let byte = UInt8(clamping: Int(value.rounded()))
                values[v * width + u] = byte
                histogram[Int(byte)] += 1
            }
        }
        let lo = percentile(histogram, 0.01, of: values.count), hi = percentile(histogram, 0.9, of: values.count)
        guard hi - lo >= 50 else { return GrayStrip(width: width, height: height, pixels: [UInt8](repeating: 255, count: width * height)) }  // nothing written
        let span = Double(hi - lo)
        let pixels = values.map { UInt8(clamping: Int(((Double($0) - Double(lo)) / span * 255).rounded())) }
        return GrayStrip(width: width, height: height, pixels: pixels)
    }

    /// The sheet straightened and cropped, with the marks drawn on, as a JPEG data URL.
    static func sheetPicture(_ layout: SheetLayout, _ marks: [Mark], _ img: LumaImage, _ h: Homography, pixelsPerInch ppi: Double = 90) -> String? {
        sheetJPEG(layout, marks, img, h, pixelsPerInch: ppi).map { "data:image/jpeg;base64," + $0.base64EncodedString() }
    }

    /// The sheet straightened and cropped, with the marks drawn on, as JPEG data.
    static func sheetJPEG(_ layout: SheetLayout, _ marks: [Mark], _ img: LumaImage, _ h: Homography, pixelsPerInch ppi: Double = 90) -> Data? {
        let width = Int(layout.w * ppi), height = Int(layout.h * ppi)
        guard width > 0, height > 0 else { return nil }
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        for v in 0..<height {
            for u in 0..<width {
                let value = img.smooth(h.apply(CGPoint(x: (Double(u) + 0.5) / ppi, y: (Double(v) + 0.5) / ppi))) ?? 255
                let byte = UInt8(clamping: Int(value.rounded())), i = (v * width + u) * 4
                rgba[i] = byte; rgba[i + 1] = byte; rgba[i + 2] = byte
            }
        }
        guard let ctx = CGContext(data: &rgba, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.translateBy(x: 0, y: CGFloat(height)); ctx.scaleBy(x: ppi, y: -ppi)   // sheet inches, top-left origin
        ctx.setLineWidth(0.03); ctx.setLineCap(.round); ctx.setLineJoin(.round)
        for path in MarkPaths(marks, radius: layout.r).all {
            ctx.setStrokeColor(path.color)
            ctx.addPath(path.path)
            ctx.strokePath()
        }
        guard let image = ctx.makeImage() else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    private static func percentile(_ histogram: [Int], _ fraction: Double, of count: Int) -> Int {
        let target = Int(Double(count) * fraction)
        var seen = 0
        for (value, n) in histogram.enumerated() {
            seen += n
            if seen > target { return value }
        }
        return 255
    }
}

/// How one question is marked on screen and on the saved picture (all points in sheet inches).
struct Mark {
    var question = 0
    let right: Bool          // green ✓ next to the number, or red ✗
    var unsure = false       // waiting for the teacher's ✓ or ✗: amber dot
    let label: CGPoint       // where the ✓ or ✗ goes, just left of the question number
    let picked: CGPoint?     // the student's bubble: green if right, red X if wrong
    let correct: CGPoint?    // on a miss, the right answer's bubble, ringed in amber
}

enum Grader {
    static let letters: [Character] = Array("ABCDE")

    static func grade(_ quiz: Quiz, _ answers: String) -> (score: Double, max: Double, missed: [Int]) {
        let key = Array(quiz.answerKey.uppercased()), given = Array(answers)
        var correct = 0.0
        var missed: [Int] = []
        for i in 0..<quiz.numQuestions {
            let k: Character = i < key.count ? key[i] : "?"
            let a: Character = i < given.count ? given[i] : "-"
            if k == "*" || a == k { correct += 1 } else { missed.append(i + 1) }
        }
        return (correct * quiz.pointsPerQuestion, Double(quiz.numQuestions - quiz.bonusCount) * quiz.pointsPerQuestion, missed)
    }

    /// One mark per question: ✓ and green on a right answer; ✗, a red X on a wrong pick, and the right answer ringed on a miss.
    /// `waiting`: rows the teacher hasn't settled yet, drawn amber. Everything else is a clear ✓ or ✗.
    static func marks(_ quiz: Quiz, _ layout: SheetLayout, _ answers: String, waiting: Set<Int> = []) -> [Mark] {
        let key = Array(quiz.answerKey.uppercased()), given = Array(answers)
        var marks: [Mark] = []
        for i in 0..<min(quiz.numQuestions, given.count, key.count) {
            guard let first = layout.bubble(i, 0) else { continue }
            let label = CGPoint(x: first.x - layout.r - 0.28, y: first.y)
            let picked = letters.firstIndex(of: given[i]).flatMap { layout.bubble(i, $0) }
            if key[i] == "*" || given[i] == key[i] {
                marks.append(Mark(question: i, right: true, label: label, picked: picked, correct: nil))
            } else {
                marks.append(Mark(question: i, right: false, unsure: waiting.contains(i), label: label, picked: picked,
                                  correct: letters.firstIndex(of: key[i]).flatMap { layout.bubble(i, $0) }))
            }
        }
        return marks
    }
}

func fmt(_ x: Double) -> String { String(format: "%g", x) }

/// The strokes for a set of marks, in sheet inches: a ✓ or ✗ by each question number, like a teacher's pen, the right
/// answer ringed in grey on a miss, and an amber dot on a row waiting for the teacher.
struct MarkPaths {
    struct Colored { let path: CGPath; let color: CGColor }
    static let green = CGColor(red: 0.18, green: 0.72, blue: 0.3, alpha: 1)
    static let red = CGColor(red: 0.93, green: 0.2, blue: 0.16, alpha: 1)
    static let amber = CGColor(red: 1, green: 0.72, blue: 0.1, alpha: 1)
    static let grey = CGColor(red: 0.45, green: 0.45, blue: 0.45, alpha: 1)

    let green = CGMutablePath(), red = CGMutablePath(), amber = CGMutablePath(), grey = CGMutablePath()

    init(_ marks: [Mark], radius r: Double) {
        let s = 0.075   // half-size of the ✓ and ✗
        for m in marks {
            let c = m.label
            if m.right {
                green.move(to: CGPoint(x: c.x - s, y: c.y))
                green.addLine(to: CGPoint(x: c.x - s / 3, y: c.y + s * 0.8))
                green.addLine(to: CGPoint(x: c.x + s, y: c.y - s))
            } else if m.unsure {
                amber.addEllipse(in: CGRect(x: c.x - s * 0.6, y: c.y - s * 0.6, width: s * 1.2, height: s * 1.2))
                amber.addEllipse(in: CGRect(x: c.x - s * 0.15, y: c.y - s * 0.15, width: s * 0.3, height: s * 0.3))
            } else {
                red.move(to: CGPoint(x: c.x - s, y: c.y - s)); red.addLine(to: CGPoint(x: c.x + s, y: c.y + s))
                red.move(to: CGPoint(x: c.x - s, y: c.y + s)); red.addLine(to: CGPoint(x: c.x + s, y: c.y - s))
                if let k = m.correct { grey.addEllipse(in: CGRect(x: k.x - r - 0.03, y: k.y - r - 0.03, width: 2 * (r + 0.03), height: 2 * (r + 0.03))) }
            }
        }
    }

    var all: [Colored] {
        [Colored(path: grey, color: Self.grey), Colored(path: green, color: Self.green), Colored(path: red, color: Self.red), Colored(path: amber, color: Self.amber)]
    }
}

/// A row the phone couldn't call on its own, waiting for the teacher's ✓ or ✗.
struct RowReview: Codable, Equatable {
    let flag: String      // "?" can't tell, "*" more than one answer
    let marks: String     // letters of the bubbles with ink, "" when not known
    var result: String?   // what it was settled to (a letter or "-"); nil while waiting
}

enum Review {
    /// Every row the phone couldn't call waits for the teacher's ✓ or ✗ (unless everyone gets credit for it).
    static func rows(_ answers: String, marks: [Int: String], key: String) -> (answers: String, rows: [Int: RowReview]) {
        let chars = Array(answers), key = Array(key.uppercased())
        var rows: [Int: RowReview] = [:]
        for q in chars.indices where chars[q] == "?" || chars[q] == "*" {
            if q < key.count && key[q] == "*" { continue }
            rows[q] = RowReview(flag: String(chars[q]), marks: marks[q] ?? "", result: nil)
        }
        return (answers, rows)
    }

    /// Rows as saved with a scan (JSON object keys are strings); nil when there are none.
    static func stored(_ rows: [Int: RowReview]) -> [String: RowReview]? {
        rows.isEmpty ? nil : Dictionary(uniqueKeysWithValues: rows.map { (String($0.key), $0.value) })
    }

    static func loaded(_ rows: [String: RowReview]?) -> [Int: RowReview] {
        Dictionary(uniqueKeysWithValues: (rows ?? [:]).compactMap { k, v in Int(k).map { ($0, v) } })
    }

    /// "Wrong": the student's own wrong mark if there was exactly one, "*" for several, "-" for none.
    static func noCredit(_ row: RowReview, key: Character) -> String {
        let wrong = row.marks.filter { $0 != key }
        return wrong.count == 1 ? String(wrong) : row.marks.count >= 2 ? "*" : "-"
    }
}
