import CoreGraphics
import Foundation

/// Answer-sheet geometry in inches (US Letter, origin top-left).
/// Must match `L` in portal/index.html exactly.
enum SheetLayout {
    static let anchors: [String: CGPoint] = [
        "TL": CGPoint(x: 0.9, y: 0.9), "TR": CGPoint(x: 7.6, y: 0.9),
        "BL": CGPoint(x: 0.9, y: 10.1), "BR": CGPoint(x: 7.6, y: 10.1),
    ]
    static let idX: [CGFloat] = [1.1, 1.45, 1.8]
    static let columnX: [CGFloat] = [2.9, 5.3]
    static let top: CGFloat = 2.35
    static let pitch: CGFloat = 0.3
    static let choicePitch: CGFloat = 0.35
    static let perColumn = 25

    static func idBubble(_ column: Int, _ digit: Int) -> CGPoint {
        CGPoint(x: idX[column], y: top + CGFloat(digit) * pitch)
    }

    static func answerBubble(_ question: Int, _ choice: Int) -> CGPoint {
        CGPoint(x: columnX[question / perColumn] + CGFloat(choice) * choicePitch,
                y: top + CGFloat(question % perColumn) * pitch)
    }
}

/// Perspective transform fitted to four point pairs (sheet inches → camera point).
struct Homography {
    private let m: [Double]

    init?(_ from: [CGPoint], _ to: [CGPoint]) {
        var a: [[Double]] = []
        for (p, q) in zip(from, to) {
            let u = Double(p.x), v = Double(p.y), x = Double(q.x), y = Double(q.y)
            a.append([u, v, 1, 0, 0, 0, -u * x, -v * x, x])
            a.append([0, 0, 0, u, v, 1, -u * y, -v * y, y])
        }
        guard a.count == 8 else { return nil }
        for c in 0..<8 {
            guard let p = (c..<8).max(by: { abs(a[$0][c]) < abs(a[$1][c]) }), abs(a[p][c]) > 1e-12 else { return nil }
            a.swapAt(c, p)
            for r in 0..<8 where r != c {
                let f = a[r][c] / a[c][c]
                for k in c..<9 { a[r][k] -= f * a[c][k] }
            }
        }
        m = (0..<8).map { a[$0][8] / a[$0][$0] } + [1]
    }

    func apply(_ p: CGPoint) -> CGPoint {
        let u = Double(p.x), v = Double(p.y)
        let w = m[6] * u + m[7] * v + m[8]
        return CGPoint(x: (m[0] * u + m[1] * v + m[2]) / w, y: (m[3] * u + m[4] * v + m[5]) / w)
    }
}

/// Luminance plane of a camera frame. Points are normalized (0–1, top-left origin).
struct LumaImage {
    let base: UnsafeMutablePointer<UInt8>
    let width: Int
    let height: Int
    let bytesPerRow: Int

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
}

enum Reader {
    /// How dark a bubble must be (0 = paper, 1 = black) to count as filled. Raise it if erasures read as answers.
    static let fillThreshold = 0.3

    private static let inner: [CGPoint] = [
        CGPoint(x: 0, y: 0), CGPoint(x: 0.035, y: 0), CGPoint(x: -0.035, y: 0), CGPoint(x: 0, y: 0.035), CGPoint(x: 0, y: -0.035),
        CGPoint(x: 0.025, y: 0.025), CGPoint(x: -0.025, y: 0.025), CGPoint(x: 0.025, y: -0.025), CGPoint(x: -0.025, y: -0.025),
    ]
    private static let ring: [CGPoint] = (0..<8).map { k in
        let a = Double(k) * .pi / 4
        return CGPoint(x: 0.16 * cos(a), y: 0.16 * sin(a))
    }

    /// Darkness inside the bubble compared with the brightest paper just around it.
    static func darkness(_ c: CGPoint, _ img: LumaImage, _ h: Homography) -> Double {
        let sample: (CGPoint) -> Double = { img.at(h.apply(CGPoint(x: c.x + $0.x, y: c.y + $0.y))) }
        let ink = inner.map(sample).reduce(0, +) / Double(inner.count)
        let paper = ring.map(sample).max() ?? 0
        return paper > 0 ? max(0, 1 - ink / paper) : 0
    }

    /// Index of the single filled bubble, -1 if none, -2 if more than one.
    static func pick(_ d: [Double]) -> Int {
        guard let best = d.indices.max(by: { d[$0] < d[$1] }), d[best] >= fillThreshold else { return -1 }
        let rivals = d.indices.filter { $0 != best && d[$0] >= fillThreshold && d[$0] > d[best] * 0.7 }
        return rivals.isEmpty ? best : -2
    }

    /// Student # (nil if unreadable) and one character per question: A–E, "-" blank, "*" more than one.
    static func read(_ quiz: Quiz, _ img: LumaImage, _ h: Homography) -> (student: String?, answers: String) {
        var digits = ""
        for column in 0..<3 {
            let p = pick((0..<10).map { darkness(SheetLayout.idBubble(column, $0), img, h) })
            if p >= 0 { digits += String(p) }
        }
        var answers = ""
        for q in 0..<min(quiz.numQuestions, 50) {
            let p = pick((0..<min(quiz.numChoices, 5)).map { darkness(SheetLayout.answerBubble(q, $0), img, h) })
            if p >= 0 { answers.append(Grader.letters[p]) } else { answers += p == -1 ? "-" : "*" }
        }
        return (digits.count == 3 ? digits : nil, answers)
    }
}

struct Mark {
    let center: CGPoint   // bubble center in sheet inches
    let wrong: Bool       // true = red X on the student's answer, false = green ring on the right one
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

    static func marks(_ quiz: Quiz, _ answers: String) -> [Mark] {
        let key = Array(quiz.answerKey.uppercased()), given = Array(answers)
        var marks: [Mark] = []
        for i in 0..<min(quiz.numQuestions, given.count, key.count) where key[i] != "*" && given[i] != key[i] {
            if let j = letters.firstIndex(of: given[i]) { marks.append(Mark(center: SheetLayout.answerBubble(i, j), wrong: true)) }
            if let j = letters.firstIndex(of: key[i]) { marks.append(Mark(center: SheetLayout.answerBubble(i, j), wrong: false)) }
        }
        return marks
    }
}

func fmt(_ x: Double) -> String { String(format: "%g", x) }
