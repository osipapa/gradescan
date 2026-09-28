import CoreGraphics
import Foundation

/// One camera frame as the capture gate sees it. `sheet` is nil when no readable sheet of a known test is in view.
struct GateFrame {
    let time: TimeInterval
    let sheet: SheetRead?
}

/// What one frame read from a sheet.
struct SheetRead {
    let corners: [CGPoint]   // normalized image points
    let identity: String     // test and printed student number; one physical sheet can't change these
    let period: Int?
    let answers: String      // A–E, "-" blank, "*" two marks, "?" unclear
    var name: NameMark? = nil   // the handwritten name's rough picture, when there's writing
}

/// A coarse picture of the handwriting in the name box: enough to tell one student's sheet from another's when
/// their answers are the same (a stack of perfect scores laid one on top of the next), not to read it.
struct NameMark {
    let cells: [Double]   // darkness in a grid over the box, evened out (zero mean, unit spread)

    /// How alike two are: about 1 for the same sheet in two frames, near 0 for different handwriting.
    func likeness(_ other: NameMark) -> Double {
        guard cells.count == other.cells.count, !cells.isEmpty else { return 0 }
        return zip(cells, other.cells).reduce(0) { $0 + $1.0 * $1.1 } / Double(cells.count)
    }

    /// The handwriting in a layout's name box: a 32 × 4 grid of darkness over the box (its printed edges left out),
    /// and within each row the change from one cell to the next, so a shadow or the band the writing sits in
    /// counts for nothing and only the strokes do. Nil when the box is blank.
    static func read(_ layout: SheetLayout, _ img: LumaImage, _ map: Homography) -> NameMark? {
        let box = layout.name, cols = 32, rows = 4
        guard box.count == 4 else { return nil }
        var grid: [[Double]] = []
        for r in 0..<rows {
            var row: [Double] = []
            for c in 0..<cols {
                var sum = 0.0
                for sy in 0..<2 {
                    for sx in 0..<2 {
                        let x = box[0] + box[2] * (0.03 + 0.94 * (Double(c) + (Double(sx) + 0.5) / 2) / Double(cols))
                        let y = box[1] + box[3] * (0.15 + 0.7 * (Double(r) + (Double(sy) + 0.5) / 2) / Double(rows))
                        sum += img.at(map.apply(CGPoint(x: x, y: y)))
                    }
                }
                row.append(sum / 4)
            }
            grid.append(row)
        }
        guard let paper = grid.flatMap({ $0 }).max(), paper > 0 else { return nil }
        let edges = grid.flatMap { row in zip(row.dropFirst(), row).map { ($1 - $0) / paper } }
        return evened(edges, minSpread: 0.04)
    }

    static func average(_ marks: [NameMark]) -> NameMark? {
        guard let first = marks.first else { return nil }
        let sums = marks.dropFirst().reduce(first.cells) { sum, m in zip(sum, m.cells).map { $0 + $1 } }
        return evened(sums, minSpread: 0)
    }

    /// Zero mean and unit spread; nil when there's too little variation to go on (a blank box).
    static func evened(_ raw: [Double], minSpread: Double) -> NameMark? {
        guard !raw.isEmpty else { return nil }
        let mean = raw.reduce(0, +) / Double(raw.count)
        let spread = (raw.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(raw.count)).squareRoot()
        guard spread > minSpread else { return nil }
        return NameMark(cells: raw.map { ($0 - mean) / spread })
    }
}

enum GateOutput: Equatable {
    case idle                               // no sheet
    case locking(Double)                    // holding steady, 0–1
    case fire(period: Int?, answers: String)
    case blank                              // steady, but nothing is filled in
    case waiting                            // captured; waiting for the next sheet
}

/// Decides when to capture: once per sheet, and only when it's held steady. After a capture it waits until the
/// sheet leaves the view, or a clearly different sheet is in front of the camera. Hovering, a bubble that flickers
/// between readings, and glare can't capture the same sheet twice.
struct CaptureGate {
    static let steadyStep = 0.014         // most a corner may move between frames (normalized image units)
    static let steadyDrift = 0.045        // most a corner may drift over the whole steady run
    static let lockDuration: TimeInterval = 0.3
    static let minReads = 5
    static let window = 15
    static let agreement = 0.6
    static let clearDuration: TimeInterval = 0.5
    static let differentAnswers = 2

    enum State { case armed, cooldown, paused }
    private(set) var state: State = .armed
    /// Single mode: pause after each capture until `resume(rescan:)`.
    var pausesAfterCapture = false
    /// How long a sheet is held steady before it's captured. Longer for an answer key, so the sheet already in
    /// front of the camera isn't taken while the teacher looks for the key.
    var lockDuration = CaptureGate.lockDuration

    private var run: [SheetRead] = []
    private var runStart: TimeInterval = 0
    private var runOrigin: [CGPoint] = []
    private var captured: (identity: String, answers: String, name: NameMark?)?
    private var absentSince: TimeInterval?

    /// Ready to capture whatever is in view.
    mutating func reset() {
        state = .armed
        run = []
        captured = nil
        absentSince = nil
    }

    /// After a pause: `rescan` captures the sheet in view again; otherwise it waits for the next sheet.
    mutating func resume(rescan: Bool) {
        run = []
        absentSince = nil
        if rescan { captured = nil }
        state = captured == nil ? .armed : .cooldown
    }

    mutating func step(_ frame: GateFrame) -> GateOutput {
        if state == .paused { return .waiting }
        guard let sheet = frame.sheet else {
            run = []
            let since = absentSince ?? frame.time
            absentSince = since
            if state == .cooldown && frame.time - since >= Self.clearDuration {
                state = .armed
                captured = nil
            }
            return state == .cooldown ? .waiting : .idle
        }
        absentSince = nil
        if let last = run.last, last.identity == sheet.identity,
           Self.maxMove(last.corners, sheet.corners) < Self.steadyStep,
           Self.maxMove(runOrigin, sheet.corners) < Self.steadyDrift {
            run.append(sheet)
            if run.count > Self.window { run.removeFirst() }
        } else {
            run = [sheet]
            runStart = frame.time
            runOrigin = sheet.corners
        }
        if state == .cooldown, let c = captured, c.identity != sheet.identity {
            state = .armed   // a different test or a different named sheet
            captured = nil
        }
        let elapsed = frame.time - runStart
        guard elapsed >= lockDuration, run.count >= Self.minReads else {
            return state == .cooldown ? .waiting : .locking(min(0.99, max(0, elapsed / lockDuration)))
        }
        let (period, answers) = Self.consensus(run)
        let filled = answers.contains { Self.isLetter($0) }
        let name = NameMark.average(run.compactMap(\.name))
        switch state {
        case .armed:
            return filled ? fire(sheet.identity, period, answers, name) : .blank
        case .cooldown:
            // Same sheet unless several confident answers differ, or the handwritten name does: a new sheet laid on
            // top without a gap (in a stack, two students can have the same answers).
            guard filled, let c = captured else { return .waiting }
            let otherName = c.name.map { old in name.map { $0.likeness(old) < 0.35 } ?? false } ?? false
            guard Self.differences(c.answers, answers) >= Self.differentAnswers || otherName else { return .waiting }
            return fire(sheet.identity, period, answers, name)
        case .paused:
            return .waiting
        }
    }

    private mutating func fire(_ identity: String, _ period: Int?, _ answers: String, _ name: NameMark?) -> GateOutput {
        captured = (identity, answers, name)
        state = pausesAfterCapture ? .paused : .cooldown
        run = []
        return .fire(period: period, answers: answers)
    }

    /// Per question, the value at least `agreement` of the reads share, or "?"; the period the same way, or nil.
    static func consensus(_ reads: [SheetRead]) -> (period: Int?, answers: String) {
        let need = Int((Double(reads.count) * agreement).rounded(.up))
        let periods = Dictionary(grouping: reads.map(\.period), by: { $0 }).mapValues(\.count)
        let period = periods.max { $0.value < $1.value }.flatMap { $0.value >= need ? $0.key : nil }
        let rows = reads.map { Array($0.answers) }
        let n = rows.map(\.count).min() ?? 0
        let answers = String((0..<n).map { i -> Character in
            let counts = Dictionary(grouping: rows.map { $0[i] }, by: { $0 }).mapValues(\.count)
            guard let top = counts.max(by: { $0.value < $1.value }), top.value >= need else { return "?" }
            return top.key
        })
        return (period, answers)
    }

    /// Questions where both readings have a letter and the letters differ.
    static func differences(_ a: String, _ b: String) -> Int {
        zip(a, b).filter { x, y in x != y && isLetter(x) && isLetter(y) }.count
    }

    static func isLetter(_ c: Character) -> Bool { "ABCDE".contains(c) }

    private static func maxMove(_ a: [CGPoint], _ b: [CGPoint]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return .infinity }
        return zip(a, b).map { hypot(Double($0.x - $1.x), Double($0.y - $1.y)) }.max() ?? .infinity
    }
}
