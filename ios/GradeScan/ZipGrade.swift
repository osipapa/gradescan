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
                           periodBox: [2.72, 0.53, 0.63, 0.31])  // the Period field
    }()

    /// A test a ZipGrade stack can be for: at most 20 questions, A–E.
    static func fits(_ quiz: Quiz) -> Bool { quiz.numQuestions <= 20 && quiz.numChoices <= 5 }

    private static func r3(_ x: Double) -> Double { (x * 1000).rounded() / 1000 }
}
