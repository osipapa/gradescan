import Accelerate
import CoreGraphics

/// A sheet found in an image: its corner squares' centers in normalized image coordinates (top-left, top-right,
/// bottom-right, bottom-left) and its kind.
struct FoundSheet {
    let corners: [CGPoint]
    let kind: SheetKind
    var center: CGPoint { CGPoint(x: corners.reduce(0) { $0 + $1.x } / 4, y: corners.reduce(0) { $0 + $1.y } / 4) }
}

/// Finds answer sheets by their solid black squares: four corners plus extra squares on the edges that tell up from
/// down and which kind of sheet it is (see `SheetKind.markers`). Positions are measured between the corner squares'
/// centers, so (0, 0) is the top-left square and (1, 1) the bottom-right one. Several sheets laid out side by side
/// are all found. Works on a small copy of the camera's luma plane. Use one finder per queue; it reuses its buffers.
final class BoxFinder {
    private struct Blob {
        let x: Double      // centroid in downscaled pixels
        let y: Double
        let side: Double   // square root of the area
        let shape: Double  // area over the squared distance to the farthest pixel: about 1.8 for a square, 2.4+ for a filled bubble
        let fill: Double   // share of its tightest box it fills, at any angle: about 0.95 for a square, at most 0.79 for a round bubble
    }

    /// Directions every 7.5°, for measuring a blob's tightest box whatever its angle.
    private static let directions: [(c: Double, s: Double)] = (0..<24).map { k in (cos(Double(k) * .pi / 24), sin(Double(k) * .pi / 24)) }

    private var factor = 2   // about 960 pixels across after downscaling, whatever the camera gives
    private let window = 91   // local-average window in downscaled pixels, a few times the largest square
    private var width = 0
    private var height = 0
    private var small: [UInt8] = []
    private var mean: [UInt8] = []
    private var labels: [Int32] = []
    private var stack: [Int32] = []
    private var lastBlobs: [Blob] = []   // the last image's, for `follow`

    /// What the last image was like, for telling the teacher what to change when no sheet is found.
    struct Look {
        var brightness = 128.0    // average, 0–255
        var glare = 0.0           // share of the picture washed out to white
        var tiny = false          // square-looking marks too small to be sure of: the sheet is far away
    }
    private(set) var look = Look()

    static let unitCorners = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)]

    /// The one sheet nearest the middle of the frame. `accept` confirms a candidate is a real sheet (for ours, that
    /// its test code reads); filled bubbles can line up like squares, so unconfirmed candidates are passed over.
    func find(_ image: LumaImage, accept: (FoundSheet) -> Bool = { _ in true }) -> (corners: [CGPoint], kind: SheetKind)? {
        findAll(image, limit: 1, preferMiddle: true, accept: accept).first.map { ($0.corners, $0.kind) }
    }

    /// Every sheet in the frame (up to `limit`), best-fitting first, each confirmed by `accept`.
    func findAll(_ image: LumaImage, limit: Int = 8, preferMiddle: Bool = false, accept: (FoundSheet) -> Bool = { _ in true }) -> [FoundSheet] {
        lastBlobs = []
        guard downscale(image) else { return [] }
        let blobs = squares()
        lastBlobs = blobs
        look = measure(blobs)
        guard blobs.count >= 5 else { return [] }
        let f = Double(factor), w = Double(image.width), h = Double(image.height)
        var used = Set<Int>(), out: [FoundSheet] = []
        for fit in fits(blobs, preferMiddle: preferMiddle) where out.count < limit {
            let parts = fit.corners + fit.markers
            guard !parts.contains(where: used.contains) else { continue }
            let size = fit.corners.reduce(0) { $0 + blobs[$1].side } / 4
            let sheet = FoundSheet(corners: fit.corners.map { refined(blobs[$0], size: size) }.map { CGPoint(x: (f * $0.x + f / 2) / w, y: (f * $0.y + f / 2) / h) },
                                   kind: fit.kind)
            guard accept(sheet) else { continue }
            used.formUnion(parts)
            out.append(sheet)
        }
        return out
    }

    /// A sheet seen a moment ago, found again when the full search missed it in this image (a corner blurred,
    /// caught the light or went under a thumb): each corner square looked for near where it was. With one corner
    /// out of sight, that corner is moved the way the other three moved and `carried` is true; the sheet can be
    /// outlined, but not read. The caller confirms a sheet found with all four corners (its test code still reads).
    /// Call right after `findAll` on the same image.
    func follow(_ previous: FoundSheet, in image: LumaImage) -> (sheet: FoundSheet, carried: Bool)? {
        guard !lastBlobs.isEmpty, image.width / factor == width, image.height / factor == height else { return nil }
        let f = Double(factor), w = Double(image.width), h = Double(image.height)
        let old = previous.corners.map { CGPoint(x: ($0.x * w - f / 2) / f, y: ($0.y * h - f / 2) / f) }
        let side = 2 * previous.kind.squareHalf * hypot(old[1].x - old[0].x, old[1].y - old[0].y)
        let reach = max(3 * side, 0.04 * hypot(Double(width), Double(height)))
        var taken = Set<Int>()
        var now: [CGPoint?] = old.map { p in
            let near = lastBlobs.indices.filter { i in
                !taken.contains(i) && hypot(lastBlobs[i].x - p.x, lastBlobs[i].y - p.y) < reach
                    && lastBlobs[i].side > 0.5 * side && lastBlobs[i].side < 2 * side
            }
            guard let best = near.min(by: { hypot(lastBlobs[$0].x - p.x, lastBlobs[$0].y - p.y) < hypot(lastBlobs[$1].x - p.x, lastBlobs[$1].y - p.y) })
            else { return nil }
            taken.insert(best)
            return refined(lastBlobs[best], size: side)
        }
        let seen = now.indices.filter { now[$0] != nil }
        guard seen.count >= 3 else { return nil }
        var carried = false
        if let hidden = now.indices.first(where: { now[$0] == nil }) {
            let from = seen.map { old[$0] }, to = seen.compactMap { now[$0] }
            guard let moved = Self.affine(from, to, old[hidden]) else { return nil }
            now[hidden] = moved
            carried = true
        }
        let sheet = FoundSheet(corners: now.compactMap { $0 }.map { CGPoint(x: (f * $0.x + f / 2) / w, y: (f * $0.y + f / 2) / h) }, kind: previous.kind)
        return (sheet, carried)
    }

    /// Where `point` goes under the affine map that takes three points `from` to three points `to`.
    private static func affine(_ from: [CGPoint], _ to: [CGPoint], _ point: CGPoint) -> CGPoint? {
        guard from.count == 3, to.count == 3 else { return nil }
        let (a, b, c) = (from[0], from[1], from[2])
        let det = (b.x - a.x) * (c.y - a.y) - (c.x - a.x) * (b.y - a.y)
        guard abs(det) > 1e-6 else { return nil }
        // The point in the triangle's own coordinates, then the same coordinates in the moved triangle.
        let u = ((point.x - a.x) * (c.y - a.y) - (c.x - a.x) * (point.y - a.y)) / det
        let v = ((b.x - a.x) * (point.y - a.y) - (point.x - a.x) * (b.y - a.y)) / det
        return CGPoint(x: to[0].x + u * (to[1].x - to[0].x) + v * (to[2].x - to[0].x),
                       y: to[0].y + u * (to[1].y - to[0].y) + v * (to[2].y - to[0].y))
    }

    private func measure(_ blobs: [Blob]) -> Look {
        var sum = 0, bright = 0, count = 0
        for y in stride(from: 0, to: height, by: 6) {
            for x in stride(from: 0, to: width, by: 6) {
                let v = Int(small[y * width + x])
                sum += v; count += 1
                if v >= 250 { bright += 1 }
            }
        }
        let squares = blobs.filter { $0.shape <= 2.45 && $0.fill >= 0.6 }
        let sides = squares.map(\.side).sorted()
        return Look(brightness: Double(sum) / Double(max(1, count)), glare: Double(bright) / Double(max(1, count)),
                    tiny: sides.count >= 4 && sides[sides.count / 2] < 6)
    }

    /// A corner square's middle, taken from the dark pixels within a square-sized box around it: print or a
    /// shadow that runs into the square (and so into its blob) barely moves it.
    private func refined(_ blob: Blob, size: Double) -> CGPoint {
        var x = blob.x, y = blob.y
        let half = 0.65 * size
        for _ in 0..<3 {
            var sx = 0.0, sy = 0.0, sum = 0.0
            for py in max(0, Int(y - half))...min(height - 1, Int(y + half)) {
                for px in max(0, Int(x - half))...min(width - 1, Int(x + half)) {
                    let i = py * width + px, v = Double(small[i]), m = Double(mean[i])
                    guard m > 0, v < 0.6 * m else { continue }
                    let weight = 1 - v / m
                    sx += weight * Double(px); sy += weight * Double(py); sum += weight
                }
            }
            guard sum > 0 else { break }
            x = sx / sum; y = sy / sum
        }
        return CGPoint(x: x, y: y)
    }

    private func downscale(_ image: LumaImage) -> Bool {
        factor = max(2, max(image.width, image.height) / 960)
        let w = image.width / factor, h = image.height / factor
        guard w > window, h > window else { return false }
        if w != width || h != height {
            (width, height) = (w, h)
            small = [UInt8](repeating: 0, count: w * h)
            mean = [UInt8](repeating: 0, count: w * h)
            labels = [Int32](repeating: 0, count: w * h)
        }
        var source = vImage_Buffer(data: UnsafeMutableRawPointer(image.base), height: vImagePixelCount(image.height),
                                   width: vImagePixelCount(image.width), rowBytes: image.bytesPerRow)
        let scaled = small.withUnsafeMutableBytes { out -> vImage_Error in
            var dest = vImage_Buffer(data: out.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w)
            return vImageScale_Planar8(&source, &dest, nil, vImage_Flags(kvImageNoFlags))
        }
        guard scaled == kvImageNoError else { return false }
        let averaged = small.withUnsafeMutableBytes { input in
            mean.withUnsafeMutableBytes { output -> vImage_Error in
                var src = vImage_Buffer(data: input.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w)
                var dest = vImage_Buffer(data: output.baseAddress, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: w)
                return vImageBoxConvolve_Planar8(&src, &dest, nil, 0, 0, UInt32(window), UInt32(window), 0, vImage_Flags(kvImageEdgeExtend))
            }
        }
        return averaged == kvImageNoError
    }

    /// Solid, square dark blobs: candidates for the sheet's black squares.
    private func squares() -> [Blob] {
        let w = width, h = height
        var blobs: [Blob] = []
        var next: Int32 = 0
        labels.withUnsafeMutableBufferPointer { label in
            small.withUnsafeBufferPointer { s in
                mean.withUnsafeBufferPointer { m in
                    label.update(repeating: 0)
                    // Dark means well below the local average, so shadows and uneven light don't matter.
                    func dark(_ i: Int) -> Bool {
                        let v = Int(s[i])
                        return v < 160 && v * 10 < Int(m[i]) * 6
                    }
                    for start in 0 ..< w * h where label[start] == 0 && dark(start) {
                        next += 1
                        var area = 0, sumX = 0, sumY = 0, minX = w, maxX = 0, minY = h, maxY = 0
                        stack.removeAll(keepingCapacity: true)
                        stack.append(Int32(start))
                        label[start] = next
                        while let top = stack.popLast() {
                            let i = Int(top), x = i % w, y = i / w
                            area += 1; sumX += x; sumY += y
                            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                            if x > 0, label[i - 1] == 0, dark(i - 1) { label[i - 1] = next; stack.append(Int32(i - 1)) }
                            if x < w - 1, label[i + 1] == 0, dark(i + 1) { label[i + 1] = next; stack.append(Int32(i + 1)) }
                            if y > 0, label[i - w] == 0, dark(i - w) { label[i - w] = next; stack.append(Int32(i - w)) }
                            if y < h - 1, label[i + w] == 0, dark(i + w) { label[i + w] = next; stack.append(Int32(i + w)) }
                        }
                        let bw = maxX - minX + 1, bh = maxY - minY + 1
                        guard area >= 20, area <= 5000, bw <= 2 * bh, bh <= 2 * bw, 5 * area >= 2 * bw * bh else { continue }
                        // Area over the squared distance to the farthest pixel: about 2 for a square, 3.1 for a filled bubble.
                        let cx = Double(sumX) / Double(area), cy = Double(sumY) / Double(area)
                        var reach2 = 0.0
                        var lo = [Double](repeating: .infinity, count: 24), hi = [Double](repeating: -.infinity, count: 24)
                        for y in minY...maxY {
                            for x in minX...maxX where label[y * w + x] == next {
                                let dx = Double(x) - cx, dy = Double(y) - cy
                                reach2 = max(reach2, dx * dx + dy * dy)
                                for k in 0..<24 {
                                    let p = dx * Self.directions[k].c + dy * Self.directions[k].s
                                    lo[k] = min(lo[k], p)
                                    hi[k] = max(hi[k], p)
                                }
                            }
                        }
                        let reach = reach2.squareRoot() + 0.5
                        let shape = Double(area) / (reach * reach)
                        guard shape > 1.4, shape < 2.9 else { continue }
                        // The tightest box: a direction and the one 90° from it (twelve steps of 7.5°).
                        let box = (0..<12).map { k in (hi[k] - lo[k] + 1) * (hi[k + 12] - lo[k + 12] + 1) }.min() ?? Double(bw * bh)
                        blobs.append(Blob(x: cx, y: cy, side: Double(area).squareRoot(), shape: shape, fill: Double(area) / box))
                    }
                }
            }
        }
        return blobs
    }

    private struct Fit {
        let score: Double
        let corners: [Int]   // blob indices: top-left, top-right, bottom-right, bottom-left
        let markers: [Int]
        let kind: SheetKind
    }

    /// Every way the squares make a sheet, best first. A sheet is found from its left edge: two corner squares with
    /// the edge square between them, its kind's share of the way down (ours 0.35, ZipGrade 0.553). In a soft or
    /// distant picture a filled bubble can look as square as the sheet's squares, but bubbles don't line up like that.
    /// The other two corners are then looked for across from them, and every square has to be the size the
    /// sheet's geometry gives it.
    private func fits(_ blobs: [Blob], preferMiddle: Bool) -> [Fit] {
        // Squares have corners that reach out: area over the squared reach is about 2 for a square, 2.6 for a filled
        // bubble. This keeps 99% of the sheets' squares (tilted, soft or small) and drops most filled bubbles,
        // which on ZipGrade's form are the squares' size.
        let cands = blobs.indices.filter { blobs[$0].shape <= 2.45 && blobs[$0].fill >= 0.6 }
        guard cands.count >= 5 else { return [] }
        // A coarse grid over the image, to find the squares near a spot quickly.
        let cell = max(8.0, Double(max(width, height)) / 48)
        var grid: [Int: [Int]] = [:]
        for i in cands { grid[Int(blobs[i].x / cell) + Int(blobs[i].y / cell) * 4096, default: []].append(i) }
        let near: (Double, Double, Double) -> [Int] = { x, y, r in
            var out: [Int] = []
            for cy in max(0, Int((y - r) / cell))...max(0, Int((y + r) / cell)) {
                for cx in max(0, Int((x - r) / cell))...max(0, Int((x + r) / cell)) {
                    for i in grid[cx + cy * 4096] ?? [] where hypot(blobs[i].x - x, blobs[i].y - y) <= r { out.append(i) }
                }
            }
            return out
        }
        let similar: (Int, Int) -> Bool = { blobs[$0].side <= 1.8 * blobs[$1].side && blobs[$1].side <= 1.8 * blobs[$0].side }
        let closest: ([Int], Double, Double) -> Int? = { list, x, y in
            list.min { hypot(blobs[$0].x - x, blobs[$0].y - y) < hypot(blobs[$1].x - x, blobs[$1].y - y) }
        }
        let middle = CGPoint(x: Double(width) / 2, y: Double(height) / 2), diagonal = hypot(Double(width), Double(height))
        var out: [Fit] = [], seen = Set<[Int]>()
        for kind in [SheetKind.gradescan, .zipgrade20] {
            let along = kind.markers[0].y   // the left edge square, as a share of the way from the top-left corner down
            for tl in cands {
                for bl in cands where bl != tl && similar(tl, bl) {
                    let ex = blobs[bl].x - blobs[tl].x, ey = blobs[bl].y - blobs[tl].y, edge = hypot(ex, ey)
                    let side = max(blobs[tl].side, blobs[bl].side)
                    guard edge > 8 * side else { continue }   // a sheet's edge is many squares long
                    // The edge square: near its share of the way down (perspective shifts it a little), on the edge.
                    let mx = blobs[tl].x + along * ex, my = blobs[tl].y + along * ey
                    guard let m = closest(near(mx, my, 0.05 * edge + side).filter { $0 != tl && $0 != bl && similar($0, tl) }, mx, my),
                          abs((blobs[m].x - blobs[tl].x) * ey - (blobs[m].y - blobs[tl].y) * ex) / edge < 0.6 * side + 0.02 * edge else { continue }
                    // Across the top, the top-right corner, turning clockwise on screen from the edge; the
                    // bottom-right corner where the two sides point.
                    for tr in cands where tr != tl && tr != bl && tr != m && similar(tr, tl) {
                        let wx = blobs[tr].x - blobs[tl].x, wy = blobs[tr].y - blobs[tl].y, across = hypot(wx, wy)
                        guard across > 0.3 * edge, across < 2.5 * edge, (wx * ey - wy * ex) / (across * edge) > 0.5 else { continue }
                        // Where the two sides point; in steep perspective the far corner lands well off that.
                        let px = blobs[tr].x + ex, py = blobs[tr].y + ey
                        guard let br = closest(near(px, py, 0.4 * min(edge, across)).filter { ![tl, bl, m, tr].contains($0) && similar($0, tl) }, px, py)
                        else { continue }
                        let ids = [tl, tr, br, bl]
                        guard seen.insert(ids + [kind == .gradescan ? 0 : 1]).inserted,
                              let map = Homography(Self.unitCorners, ids.map { CGPoint(x: blobs[$0].x, y: blobs[$0].y) }) else { continue }
                        // Each square the size the geometry gives it where it is (so perspective, which makes near
                        // squares bigger, is allowed for): ours are 0.25 in over 3.3–3.9 in between the corners,
                        // ZipGrade's 0.17 in over 3.4 in. Page text, code squares and bubbles aren't.
                        let half = kind.squareHalf
                        let expectedSide: (CGPoint) -> Double = { point in
                            let a = map.apply(CGPoint(x: point.x - half, y: point.y)), b = map.apply(CGPoint(x: point.x + half, y: point.y))
                            return hypot(b.x - a.x, b.y - a.y)
                        }
                        let fits: (Int, CGPoint) -> Bool = { id, point in
                            let expected = expectedSide(point)
                            return blobs[id].side > 0.6 * expected && blobs[id].side < 1.6 * expected
                        }
                        guard zip(ids, Self.unitCorners).allSatisfy(fits) else { continue }
                        // Every edge square of the kind where the corners put it (ZipGrade has one on each side).
                        let size = ids.reduce(0) { $0 + blobs[$1].side } / 4
                        var total = 0.0, markers: [Int] = []
                        for marker in kind.markers {
                            let p = map.apply(marker)
                            guard let found = closest(near(p.x, p.y, 0.6 * size + 0.015 * edge).filter { !ids.contains($0) && fits($0, marker) }, p.x, p.y)
                            else { break }
                            total += hypot(blobs[found].x - p.x, blobs[found].y - p.y)
                            markers.append(found)
                        }
                        guard markers.count == kind.markers.count else { continue }
                        var score = total / Double(markers.count) / size
                        if preferMiddle {
                            let cx = ids.reduce(0) { $0 + blobs[$1].x } / 4, cy = ids.reduce(0) { $0 + blobs[$1].y } / 4
                            score += 0.3 * hypot(cx - middle.x, cy - middle.y) / diagonal
                        }
                        out.append(Fit(score: score, corners: ids, markers: markers, kind: kind))
                    }
                }
            }
        }
        return out.sorted { $0.score < $1.score }
    }

}
