import Foundation

/// A scan as the stats need it.
struct ScoredSheet {
    let answers: String
    let period: Int?
    let override: Double?   // set in the portal to replace the computed score
}

/// How a test went: averages, grade spread, periods, and the questions most students missed.
struct TestStats {
    struct Grade: Identifiable { let letter: String; let count: Int; var id: String { letter } }
    struct Period: Identifiable { let period: Int?; let count: Int; let average: Double; var id: Int { period ?? 0 } }
    struct Question: Identifiable {
        let number: Int           // 1-based
        let key: Character
        let percentRight: Int
        let wrong: Character?     // the wrong answer most chose: a letter, "-" blank, "*" two marks, "?" unclear
        let wrongCount: Int
        var id: Int { number }
    }

    let count: Int
    let average: Double?          // percents, 0–100 (bonus questions can push a score past 100)
    let median: Double?
    let high: Double?
    let low: Double?
    let grades: [Grade]
    let periods: [Period]
    let questions: [Question]

    init(quiz: Quiz, sheets: [ScoredSheet]) {
        count = sheets.count
        let max = quiz.maxScore
        let percents = max > 0 ? sheets.map { quiz.score($0.answers, override: $0.override) / max * 100 } : []
        let sorted = percents.sorted()
        average = sorted.isEmpty ? nil : sorted.reduce(0, +) / Double(sorted.count)
        median = sorted.isEmpty ? nil : sorted.count % 2 == 1 ? sorted[sorted.count / 2] : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
        high = sorted.last
        low = sorted.first
        let bands: [(letter: String, from: Double, below: Double)] = [
            ("A", 90, .infinity), ("B", 80, 90), ("C", 70, 80), ("D", 60, 70), ("F", -.infinity, 60),
        ]
        grades = bands.map { band in Grade(letter: band.letter, count: percents.filter { $0 >= band.from && $0 < band.below }.count) }
        var byPeriod: [Int?: [Double]] = [:]
        if !percents.isEmpty { for (sheet, p) in zip(sheets, percents) { byPeriod[sheet.period, default: []].append(p) } }
        periods = byPeriod.map { Period(period: $0.key, count: $0.value.count, average: $0.value.reduce(0, +) / Double($0.value.count)) }
            .sorted { ($0.period ?? 99) < ($1.period ?? 99) }
        let key = Array(quiz.answerKey.uppercased())
        questions = sheets.isEmpty ? [] : (0..<quiz.numQuestions).map { i in
            let k: Character = i < key.count ? key[i] : "?"
            var right = 0
            var wrongs: [Character: Int] = [:]
            for sheet in sheets {
                let given = Array(sheet.answers)
                let a: Character = i < given.count ? given[i] : "-"
                if k == "*" || a == k { right += 1 } else { wrongs[a, default: 0] += 1 }
            }
            let top = wrongs.max { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }
            return Question(number: i + 1, key: k, percentRight: Int((Double(right) / Double(sheets.count) * 100).rounded()),
                            wrong: top?.key, wrongCount: top?.value ?? 0)
        }
    }

    /// Hardest first; ties by question number.
    var hardest: [Question] { questions.sorted { $0.percentRight < $1.percentRight || ($0.percentRight == $1.percentRight && $0.number < $1.number) } }

    static func wrongLabel(_ c: Character) -> String {
        switch c {
        case "-": return "most left blank"
        case "*": return "most marked two"
        case "?": return "most unclear"
        default: return "most chose \(c)"
        }
    }
}

extension Quiz {
    /// Points possible; bonus questions don't count toward it.
    var maxScore: Double { Grader.grade(self, "").max }

    func score(_ answers: String, override: Double? = nil) -> Double { override ?? Grader.grade(self, answers).score }

    /// "18/20"
    func scoreText(_ answers: String, override: Double? = nil) -> String { "\(fmt(score(answers, override: override)))/\(fmt(maxScore))" }

    /// Rounded percent, or nil when the test has no points.
    func percent(_ answers: String, override: Double? = nil) -> Int? {
        maxScore > 0 ? Int((score(answers, override: override) / maxScore * 100).rounded()) : nil
    }

    var summary: String {
        "\(numQuestions) questions · A–\(String(Grader.letters[max(0, min(numChoices, 5) - 1)])) · \(fmt(pointsPerQuestion)) \(pointsPerQuestion == 1 ? "pt" : "pts") each"
    }
}
