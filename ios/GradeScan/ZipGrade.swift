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

    /// Whether a candidate really is a ZipGrade form: its printed circles sit where the layout puts the bubbles
    /// (darker on the circle than on the paper just outside), which filled bubbles lined up like squares can't fake.
    static func looksReal(_ img: LumaImage, corners: [CGPoint]) -> Bool {
        let layout = form20
        guard let map = Homography(layout.cornerPoints, corners) else { return false }
        var hits = 0, tried = 0
        for q in [0, 4, 9, 10, 14, 19] {
            for c in [0, 2, 4] {
                let p = SheetLayout.point(layout.questions[q][c]), r = layout.r
                let at: (Double, Double) -> Double = { a, k in img.at(map.apply(CGPoint(x: p.x + k * r * cos(a), y: p.y + k * r * sin(a)))) }
                let angles = (0..<8).map { Double($0) * .pi / 4 }
                // The printed line is thin, so look just inside, on, and just outside it and keep the darkest.
                let circle = angles.reduce(0) { sum, a in sum + [0.84, 0.92, 1.0].map { at(a, $0) }.min()! } / 8
                let paper = [Double.pi / 2, 3 * .pi / 2].map { at($0, 1.5) }.max() ?? 0   // above and below: rows are far apart
                tried += 1
                if paper > 0 && circle < 0.9 * paper { hits += 1 }
            }
        }
        return hits * 3 >= tried * 2
    }

    /// A test a ZipGrade stack can be for: at most 20 questions, A–E.
    static func fits(_ quiz: Quiz) -> Bool { quiz.numQuestions <= 20 && quiz.numChoices <= 5 }

    private static func r3(_ x: Double) -> Double { (x * 1000).rounded() / 1000 }
}
