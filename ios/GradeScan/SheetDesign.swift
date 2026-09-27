import Foundation

/// The answer-sheet layout, ported from `sheetLayout` in portal/index.html so tests can be created on the phone.
/// Keep the numbers in step with the portal; the portal prints whatever layout a test has saved.
enum SheetDesign {
    static let fid = 0.25, fidAt = 0.2, border = 0.43, pad = 0.1
    static let r = 0.09, dx = 0.26, dy = 0.28, label = 0.26, gap = 0.2, periods = 9, pdx = 0.25
    static let dateY = 1.24, periodY = 1.48, top = 2.02

    static func layout(questions n: Int, choices c: Int) -> SheetLayout {
        let rows = (n + 1) / 2, cols = n > 1 ? 2 : 1
        let colW = label + Double(c - 1) * dx + 2 * r
        let gridW = Double(cols) * colW + Double(cols - 1) * gap
        let x0 = border + pad, inner = max(gridW, 0.5 + Double(periods - 1) * pdx + 2 * r)
        let w = r3(inner + 2 * x0), last = top + Double(rows - 1) * dy, h = r3(last + 0.42 + border)
        let gx = x0 + (inner - gridW) / 2, a = fidAt, nameX = x0 + 0.5
        let questions: [[[Double]]] = (0..<n).map { i in
            let x = gx + Double(i / rows) * (colW + gap) + label + r, y = top + Double(i % rows) * dy
            return (0..<c).map { j in [r3(x + Double(j) * dx), r3(y)] }
        }
        return SheetLayout(
            w: w, h: h, fid: fid, r: r,
            corners: [[a, a], [r3(w - a), a], [r3(w - a), r3(h - a)], [a, r3(h - a)]],
            marker: [a, r3(a + 0.35 * (h - 2 * a))],
            questions: questions,
            period: (0..<periods).map { k in [r3(x0 + 0.5 + r + Double(k) * pdx), periodY] },
            name: [r3(nameX), 0.7, r3(w - x0 - nameX), 0.32],
            dateBox: [r3(nameX), r3(dateY - 0.26), 1.4, 0.32])
    }

    private static func r3(_ x: Double) -> Double { (x * 1000).rounded() / 1000 }
}
