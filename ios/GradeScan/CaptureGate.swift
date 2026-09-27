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

    private var run: [SheetRead] = []
    private var runStart: TimeInterval = 0
    private var runOrigin: [CGPoint] = []
    private var captured: (identity: String, answers: String)?
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
        guard elapsed >= Self.lockDuration, run.count >= Self.minReads else {
            return state == .cooldown ? .waiting : .locking(min(0.99, max(0, elapsed / Self.lockDuration)))
        }
        let (period, answers) = Self.consensus(run)
        let filled = answers.contains { Self.isLetter($0) }
        switch state {
        case .armed:
            return filled ? fire(sheet.identity, period, answers) : .blank
        case .cooldown:
            // Same sheet unless several confident answers differ: a new sheet laid on top without a gap.
            guard filled, let c = captured, Self.differences(c.answers, answers) >= Self.differentAnswers else { return .waiting }
            return fire(sheet.identity, period, answers)
        case .paused:
            return .waiting
        }
    }

    private mutating func fire(_ identity: String, _ period: Int?, _ answers: String) -> GateOutput {
        captured = (identity, answers)
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
