import Foundation

/// Works out who wrote a sheet from the handwriting recognition's reading, which is rarely letter-perfect
/// ("roah sim" for "Noah Kim"). Each student gets a probability: how close the reading is once the letters
/// handwriting recognition typically mixes up are allowed for, weighed by whether their period matches the
/// sheet and whether they've already been scanned for this test.
enum NameMatch {
    struct Guess {
        let student: Student
        let probability: Double   // 0–1, over the whole class plus "someone not on the list"
        let distance: Double      // 0 = identical; about 0.1 per lookalike letter in a short name
    }

    /// Every student, most likely first.
    static func guesses(_ read: String?, among students: [Student], period: Int?, taken: Set<String> = []) -> [Guess] {
        let words = tokens(read ?? "")
        guard !words.isEmpty else {
            // Nothing to go on but the period.
            return students.map { Guess(student: $0, probability: 0, distance: 1.5) }
                .sorted { ($0.student.period == period ? 0 : 1, $0.student.name) < ($1.student.period == period ? 0 : 1, $1.student.name) }
        }
        let scored = students.map { student -> (Student, Double, Double) in
            let d = distance(words, tokens(student.name))
            var weight = exp(-d / temperature)
            if let period, student.period == period { weight *= 2 }
            if taken.contains(student.id) { weight *= 0.2 }   // one scan per student per test
            return (student, d, weight)
        }
        let total = scored.reduce(exp(-notListed / temperature)) { $0 + $1.2 }
        return scored.map { Guess(student: $0.0, probability: $0.2 / total, distance: $0.1) }
            .sorted { $0.probability > $1.probability || ($0.probability == $1.probability && $0.student.name < $1.student.name) }
    }

    /// Assign when the reading is clearly one student; suggest (one tap to confirm) when it's probably them.
    static func decide(_ read: String?, among students: [Student], period: Int?, taken: Set<String> = []) -> (assign: Student?, suggest: Student?) {
        guard let top = guesses(read, among: students, period: period, taken: taken).first else { return (nil, nil) }
        if top.probability >= 0.85 && top.distance <= 0.3 { return (top.student, nil) }
        if top.probability >= 0.5 && top.distance <= 0.6 { return (nil, top.student) }
        return (nil, nil)
    }

    private static let temperature = 0.08
    private static let notListed = 0.55   // a reading this far from everyone is probably someone not on the list

    static func tokens(_ s: String) -> [String] {
        s.folding(options: [.diacriticInsensitive], locale: nil).lowercased()
            .split { !$0.isLetter }.map(String.init).filter { !$0.isEmpty }
    }

    /// How far a reading is from a name, word by word and in any order (a name may be written last-first).
    /// A left-out word costs a little (students often write just their first name); an extra word costs more.
    static func distance(_ read: [String], _ name: [String]) -> Double {
        guard !read.isEmpty, !name.isEmpty else { return 1.5 }
        let r = read.map(Array.init), n = name.map(Array.init)
        var best = Double.infinity
        func pair(_ i: Int, _ used: Set<Int>, _ cost: Double) {
            if cost >= best { return }
            guard i < r.count else {
                let missing = Double(max(0, n.count - used.count)), extra = Double(max(0, r.count - used.count))
                best = min(best, cost + 0.35 * missing + 0.5 * extra)
                return
            }
            var paired = false
            for j in n.indices where !used.contains(j) {
                paired = true
                pair(i + 1, used.union([j]), cost + wordCost(r[i], n[j]))
            }
            if !paired || r.count > n.count { pair(i + 1, used, cost) }   // an extra word
        }
        pair(0, [], 0)
        return best / Double(r.count)
    }

    /// Edit distance between two words where swapping lookalike letters is cheap, per letter of the longer word.
    static func wordCost(_ a: [Character], _ b: [Character]) -> Double {
        if a == b { return 0 }
        if a.count == 1 { return b.first == a.first ? 0.3 : 1 }   // an initial
        let gap = 0.8
        var row = (0...b.count).map { Double($0) * gap }
        for i in 1...a.count {
            var diagonal = row[0]
            row[0] = Double(i) * gap
            for j in stride(from: 1, through: b.count, by: 1) {
                let above = row[j]
                let swap = a[i - 1] == b[j - 1] ? 0 : lookalike(a[i - 1], b[j - 1]) ? 0.4 : 1
                row[j] = min(above + gap, row[j - 1] + gap, diagonal + swap)
                diagonal = above
            }
        }
        return row[b.count] / Double(max(a.count, b.count))
    }

    /// Letters handwriting recognition mixes up.
    private static let groups: [Set<Character>] = [
        ["n", "r", "m", "h", "u", "v", "w"],
        ["a", "o", "e", "c", "d", "q", "g", "u"],
        ["i", "l", "j", "t", "f", "r", "y"],
        ["s", "z", "k", "x", "g"],
        ["b", "h", "k", "l", "d"],
        ["p", "q", "g", "y", "j"],
    ]

    static func lookalike(_ a: Character, _ b: Character) -> Bool { groups.contains { $0.contains(a) && $0.contains(b) } }
}
