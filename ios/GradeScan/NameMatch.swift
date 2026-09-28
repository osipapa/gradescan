import Foundation

/// Works out who wrote a sheet from the handwriting recognition's readings, which are rarely letter-perfect
/// ("roah sim" for "Noah Kim"). Each student gets a probability: how close the best reading is once the letters
/// handwriting recognition typically mixes up, nicknames ("Tori" for Victoria) and run-together or split words
/// ("arlapatel", "Ma riana") are allowed for, weighed by whether their period matches the sheet, whether they've
/// already been scanned for this test, and how much the handwriting looks like their earlier sheets (HandwritingMemory).
enum NameMatch {
    struct Guess {
        let student: Student
        let probability: Double   // 0–1, over the whole class plus "someone not on the list"
        let distance: Double      // 0 = identical; about 0.1 per lookalike letter in a short name
    }

    /// One way the recognizer read the name, and how sure it was (0–1). Readings from one look at the image share a
    /// `pass`, and each pass counts once, so a pass that lists many alternatives doesn't outvote one with a single reading.
    struct Reading: Sendable, Hashable {
        let text: String
        var confidence: Double = 1
        var pass: Int = 0
    }

    /// Every student, most likely first.
    static func guesses(_ read: String?, among students: [Student], period: Int?, taken: Set<String> = []) -> [Guess] {
        guesses(read.map { [Reading(text: $0)] } ?? [], among: students, period: period, taken: taken)
    }

    /// Assign when the reading is clearly one student; suggest (one tap to confirm) when it's probably them.
    static func decide(_ read: String?, among students: [Student], period: Int?, taken: Set<String> = []) -> (assign: Student?, suggest: Student?) {
        decide(read.map { [Reading(text: $0)] } ?? [], among: students, period: period, taken: taken)
    }

    /// Every student, most likely first, from all the readings of one handwritten name. `handwriting` says how much more
    /// likely the writing is each student's, judged by their earlier sheets (1 = no idea; students missing count as 1).
    static func guesses(_ readings: [Reading], among students: [Student], period: Int?, taken: Set<String> = [],
                        handwriting: [String: Double] = [:]) -> [Guess] {
        // Per pass, each distinct reading once (alternatives often differ only in case), at its highest confidence.
        var distinct: [Int: [[String]: Double]] = [:]
        for r in readings {
            let words = tokens(r.text)
            if !words.isEmpty { distinct[r.pass, default: [:]][words] = max(distinct[r.pass]?[words] ?? 0, r.confidence) }
        }
        let passes = distinct.values.map { Array($0) }
        guard !passes.isEmpty || !handwriting.isEmpty else {
            // Nothing to go on but the period.
            return students.map { Guess(student: $0, probability: 0, distance: 1.5) }
                .sorted { ($0.student.period == period ? 0 : 1, $0.student.name) < ($1.student.period == period ? 0 : 1, $1.student.name) }
        }
        let scored = students.map { student -> (Student, Double, Double) in
            let name = tokens(student.name)
            // Nothing read: every student starts even, and only the handwriting and the period tell them apart.
            var best = 1.5, evidence = passes.isEmpty ? exp(-notListed / temperature) : 0
            for pass in passes {
                var strongest = 0.0
                for (words, confidence) in pass {
                    let d = nameDistance(words, name)
                    best = min(best, d)
                    strongest = max(strongest, exp(-d / temperature) * max(confidence, 0.05))
                }
                evidence += strongest / Double(passes.count)
            }
            var weight = evidence * (handwriting[student.id] ?? 1)
            if let period, student.period == period { weight *= 3 }
            if taken.contains(student.id) { weight *= 0.2 }   // one scan per student per test
            return (student, best, weight)
        }
        let total = scored.reduce(exp(-notListed / temperature)) { $0 + $1.2 }
        return scored.map { Guess(student: $0.0, probability: $0.2 / total, distance: $0.1) }
            .sorted { $0.probability > $1.probability || ($0.probability == $1.probability && $0.student.name < $1.student.name) }
    }

    /// Assign when the readings clearly point at one student; suggest (one tap to confirm) when it's probably them.
    static func decide(_ readings: [Reading], among students: [Student], period: Int?, taken: Set<String> = [],
                       handwriting: [String: Double] = [:]) -> (assign: Student?, suggest: Student?) {
        guard let top = guesses(readings, among: students, period: period, taken: taken, handwriting: handwriting).first else { return (nil, nil) }
        // Writing that closely matches the student's earlier sheets makes up for a rougher reading.
        let looksLikeThem = (handwriting[top.student.id] ?? 1) >= 7
        if top.probability >= 0.85 && top.distance <= (looksLikeThem ? 0.45 : 0.3) { return (top.student, nil) }
        if top.probability >= 0.35 && (top.distance <= 0.7 || looksLikeThem) { return (nil, top.student) }
        return (nil, nil)
    }

    private static let temperature = 0.08
    private static let notListed = 0.55   // a reading this far from everyone is probably someone not on the list

    static func tokens(_ s: String) -> [String] {
        s.folding(options: [.diacriticInsensitive], locale: nil).lowercased()
            .split { !$0.isLetter }.map(String.init).filter { !$0.isEmpty }
    }

    /// How far a reading is from a student's name: `distance`, except that a nickname can stand in for the first name
    /// and the words may be run together or split apart.
    static func nameDistance(_ read: [String], _ name: [String]) -> Double {
        guard !read.isEmpty, !name.isEmpty else { return 1.5 }
        let read = read.count > 5 ? Array(read.sorted { $0.count > $1.count }.prefix(5)) : read   // no name has more words
        let nicks = nicknames[name[0]] ?? []
        var best = distance(read, name)
        for nick in nicks { best = min(best, distance(read, [nick] + name.dropFirst()) + 0.04) }
        // Letters only, against the orders a name gets written in.
        let joined = Array(read.joined())
        guard joined.count >= 4 else { return best }
        let first = name[0], last = name[name.count - 1]
        var forms: Set<String> = [name.joined(), first + last]
        if name.count > 1 { forms.formUnion([last + first, name.dropFirst().joined() + first] + nicks.map { $0 + last }) }
        for form in forms { best = min(best, wordCost(joined, Array(form)) + (read.count > 1 ? 0.03 : 0)) }
        return best
    }

    /// How far a reading is from a name, word by word and in any order (a name may be written last-first).
    /// A left-out word costs a little (students often write just their first name); an extra word costs more.
    static func distance(_ read: [String], _ name: [String]) -> Double {
        guard !read.isEmpty, !name.isEmpty else { return 1.5 }
        let r = read.map(Array.init), n = name.map(Array.init)
        let cost = r.map { a in n.map { wordCost(a, $0) } }   // every read word against every name word, once
        var best = Double.infinity
        func pair(_ i: Int, _ used: Set<Int>, _ total: Double) {
            if total >= best { return }
            guard i < r.count else {
                let missing = Double(max(0, n.count - used.count)), extra = Double(max(0, r.count - used.count))
                best = min(best, total + 0.35 * missing + 0.5 * extra)
                return
            }
            var paired = false
            for j in n.indices where !used.contains(j) {
                paired = true
                pair(i + 1, used.union([j]), total + cost[i][j])
            }
            if !paired || r.count > n.count { pair(i + 1, used, total) }   // an extra word
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

    /// Names students go by instead of the one on the class list, keyed by the class list's first name.
    static let nicknames: [String: [String]] = {
        let table = [
            "alexander": "alex xander zander al", "alexandra": "alex lexi alexa sandra", "alejandro": "alex ale jandro",
            "alejandra": "ale alex", "alexis": "alex lexi", "samuel": "sam sammy", "samantha": "sam sammy", "matthew": "matt matty",
            "mateo": "teo", "william": "will liam billy bill", "benjamin": "ben benji benny", "michael": "mike mikey",
            "christopher": "chris topher", "christian": "chris", "christina": "chris tina", "nicholas": "nick nico",
            "nicolas": "nick nico", "anthony": "tony ant", "antonio": "tony tono", "joshua": "josh", "andrew": "andy drew",
            "andres": "andy", "abigail": "abby abi gail", "madison": "maddie maddy", "madeline": "maddie maddy",
            "elizabeth": "liz lizzy beth eliza ellie", "katherine": "kate katie kat", "catherine": "cate cathy cat",
            "isabella": "bella izzy isa", "isabel": "isa izzy bella", "gabriela": "gabby gaby gabi", "gabriella": "gabby gaby",
            "gabriel": "gabe gabi", "daniel": "dan danny dani", "daniela": "dani dany", "guadalupe": "lupe lupita",
            "francisco": "paco pancho frank", "jesus": "chuy chucho", "eduardo": "lalo eddie ed", "victoria": "vicky tori vic",
            "zachary": "zach zack", "nathan": "nate", "nathaniel": "nate nathan", "jacob": "jake", "santiago": "santi",
            "valentina": "vale val", "jose": "pepe", "olivia": "liv livvy", "sophia": "sophie", "sofia": "sofi",
            "jonathan": "jon johnny", "thomas": "tom tommy", "joseph": "joe joey", "robert": "rob bobby bob robbie",
            "roberto": "beto", "alberto": "beto", "richard": "rick ricky rich", "ricardo": "ricky richie",
            "james": "jim jimmy jamie", "jennifer": "jen jenny", "jessica": "jess jessie", "rebecca": "becca becky",
            "margaret": "maggie meg", "patricia": "patty tricia", "steven": "steve", "stephen": "steve",
            "timothy": "tim timmy", "kenneth": "ken kenny", "maximilian": "max", "maxwell": "max", "maximiliano": "max maxi",
            "theodore": "theo teddy", "frederick": "fred freddy", "leonardo": "leo", "leonard": "leo len", "guillermo": "memo",
            "ignacio": "nacho", "enrique": "kike quique", "rafael": "rafa", "fernando": "fer nando", "fernanda": "fer",
            "mariana": "mari", "maria": "mari", "natalia": "nati nat", "natalie": "nat", "emily": "em emmy", "emma": "em",
            "evelyn": "evie", "penelope": "penny", "charlotte": "charlie lottie", "charles": "charlie chuck",
            "jackson": "jack", "jaxon": "jax", "dominic": "dom", "sebastian": "seb bastian", "gregory": "greg",
            "jeffrey": "jeff", "gerardo": "gera", "alfredo": "fredo", "armando": "mando", "jacqueline": "jackie",
            "veronica": "vero", "ximena": "xime", "kimberly": "kim", "elijah": "eli", "elias": "eli", "isaiah": "zay",
            "cameron": "cam", "camila": "cami mila", "anastasia": "ana stacy", "ashley": "ash", "harrison": "harry",
            "henry": "hank", "harold": "harry", "lillian": "lily lil", "mackenzie": "kenzie mac", "tobias": "toby",
            "vincent": "vince vinny",
        ]
        return table.mapValues { $0.split(separator: " ").map(String.init) }
    }()
}
