import CoreGraphics
import Foundation

/// The kinds of answer sheet the phone reads, told apart by their black squares.
enum SheetKind: String, Codable, Sendable {
    /// Ours: four corner squares and one on the left edge, a third of the way down. The test code is printed on it.
    case gradescan
    /// ZipGrade's standard 20-question form: four corner squares and one on each side, level with question 5.
    /// It carries no test code, so the teacher says which test a ZipGrade stack is for.
    case zipgrade20

    /// The extra squares, in corner-to-corner units ((0, 0) is the top-left square, (1, 1) the bottom-right).
    var markers: [CGPoint] {
        switch self {
        case .gradescan: return [CGPoint(x: 0, y: 0.35)]
        case .zipgrade20: return [CGPoint(x: 0, y: 0.553), CGPoint(x: 1, y: 0.553)]
        }
    }

    /// Half a black square's side, as a share of the distance between the corner squares' centers.
    var squareHalf: Double { self == .gradescan ? 0.035 : 0.0245 }

    /// Where its bubbles are. Ours comes from the test (the portal saves it); ZipGrade's is fixed.
    func layout(for quiz: Quiz) -> SheetLayout? { self == .gradescan ? quiz.layout : ZipGrade.form20 }
}

enum ZipGrade {
    /// ZipGrade's standard 20-question answer sheet (V2), measured from the official PDF
    /// (https://content.zipgrade.com/static/pdfs/ZipGrade20QuestionV2.pdf). Inches, with the top-left square's
    /// center at (0.2, 0.2) like our layouts; only the proportions matter, so any print size works.
    static let form20: SheetLayout = {
        let dx = 0.2 - 2.5483, dy = 0.2 - 3.2583   // the PDF's top-left square center moved to (0.2, 0.2)
        let rows = [4.4867, 4.7867, 5.0867, 5.3867, 5.6933, 5.9933, 6.3000, 6.6033, 6.9033, 7.2033]
        let left = [3.0967, 3.3233, 3.5500, 3.7800, 4.0067], right = [4.7300, 4.9567, 5.1833, 5.4133, 5.6400]
        let questions = [left, right].flatMap { column in rows.map { y in column.map { [r3($0 + dx), r3(y + dy)] } } }
        return SheetLayout(w: 3.8, h: 4.807, fid: 0.1667, r: 0.0983,
                           corners: [[0.2, 0.2], [3.6, 0.2], [3.6, 4.607], [0.2, 4.607]],
                           marker: [0.2, r3(5.6950 + dy)],
                           questions: questions,
                           period: [],                          // written by hand in the Period box
                           name: [1.07, 0.16, 2.28, 0.33],       // the Name field
                           periodBox: [2.72, 0.53, 0.63, 0.31],  // the Period field
                           dateBox: [1.07, 0.53, 0.99, 0.31])    // the Date field
    }()

    /// Whether a candidate really is a ZipGrade form: the box for the name, date and period across its top, and its
    /// printed bubbles where the form puts them. Our own sheet's bubble grid, under a wrong fit, has no such box.
    static func looksReal(_ img: LumaImage, corners: [CGPoint]) -> Bool {
        guard let map = Homography(form20.cornerPoints, corners) else { return false }
        return nameBox(img, map) && form20.printed(in: img, map: map)
    }

    /// The thick border of the Name / Date / Period box (measured from the PDF, layout inches: x 0.41–3.40,
    /// y 0.13–0.88), each side sampled in several places, darker than the paper just outside the box.
    private static func nameBox(_ img: LumaImage, _ map: Homography) -> Bool {
        let at: (Double, Double) -> Double = { x, y in img.at(map.apply(CGPoint(x: x, y: y))) }
        // Paper: above the box and to its left, clear of the corner square.
        let paper = ([0.9, 1.6, 2.3, 3.0].map { at($0, 0.06) } + [0.5, 0.7].map { at(0.3, $0) }).sorted()[3]
        guard paper > 0 else { return false }
        // The darkest point across each sampled bit of line, allowing for the sheet being a little off.
        let across = (-4...4).map { Double($0) * 0.012 }
        let horizontal: (Double, Double) -> Bool = { x, y in across.map { at(x, y + $0) }.min()! < 0.75 * paper }
        let vertical: (Double, Double) -> Bool = { x, y in across.map { at(x + $0, y) }.min()! < 0.75 * paper }
        let top = [0.8, 1.5, 2.2, 2.9].filter { horizontal($0, 0.1475) }.count
        let bottom = [0.8, 1.5, 2.2, 2.9].filter { horizontal($0, 0.8645) }.count
        let sides = [0.3, 0.7].filter { vertical(0.4315, $0) }.count + [0.3, 0.7].filter { vertical(3.386, $0) }.count
        return top + bottom + sides >= 10 && top >= 2 && bottom >= 2
    }

    /// A test a ZipGrade stack can be for: at most 20 questions, A–E.
    static func fits(_ quiz: Quiz) -> Bool { quiz.numQuestions <= 20 && quiz.numChoices <= 5 }

    private static func r3(_ x: Double) -> Double { (x * 1000).rounded() / 1000 }
}

extension SheetLayout {
    /// Whether this layout's bubbles are printed where `map` puts them: at least half are empty printed circles
    /// (the line darker than the paper inside and outside it) and seven in ten are circles or filled in. Students
    /// fill one bubble a row, so a real sheet has plenty of empty circles. Another sheet's bubble grid under a wrong
    /// fit matches only some of them, and a patch of filled bubbles has no empty circles.
    func printed(in img: LumaImage, map: Homography) -> Bool {
        let angles = (0..<8).map { Double($0) * .pi / 4 }
        // A curled sheet puts its bubbles a little off from where the corners say, so each is also looked for a
        // third of a bubble to each side.
        let shifts = [CGPoint.zero, CGPoint(x: 0.35 * r, y: 0), CGPoint(x: -0.35 * r, y: 0), CGPoint(x: 0, y: 0.35 * r), CGPoint(x: 0, y: -0.35 * r)]
        var empty = 0, filled = 0, tried = 0
        for row in questions {
            for bubble in row {
                tried += 1
                var isFilled = false
                for shift in shifts {
                    let p = SheetLayout.point(bubble)
                    let c = CGPoint(x: p.x + shift.x, y: p.y + shift.y)
                    let at: (Double, Double) -> Double = { a, k in img.at(map.apply(CGPoint(x: c.x + k * r * cos(a), y: c.y + k * r * sin(a)))) }
                    // The printed line is thin, so look just inside, on, and just outside it and keep the darkest.
                    let circle = angles.reduce(0) { sum, a in sum + [0.84, 0.92, 1.0].map { at(a, $0) }.min()! } / 8
                    let inside = angles.reduce(0) { $0 + at($1, 0.45) } / 8
                    let outside = [Double.pi / 2, 3 * .pi / 2].map { at($0, 1.5) }.max() ?? 0   // above and below: rows are far apart
                    guard outside > 0 else { continue }
                    if circle < 0.95 * min(inside, outside) { empty += 1; isFilled = false; break }
                    if inside < 0.75 * outside && circle < 0.9 * outside { isFilled = true }
                }
                if isFilled { filled += 1 }
            }
        }
        return tried > 0 && empty * 2 >= tried && (empty + filled) * 10 >= tried * 7
    }
}
