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
    }

    private var factor = 3   // about 640 pixels across after downscaling, whatever the camera gives
    private let window = 61   // local-average window in downscaled pixels, a few times the largest square
    private var width = 0
    private var height = 0
    private var small: [UInt8] = []
    private var mean: [UInt8] = []
    private var labels: [Int32] = []
    private var stack: [Int32] = []

    static let unitCorners = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)]
    static let unitMarker = CGPoint(x: 0, y: 0.35)

    /// The one sheet nearest the middle of the frame. `accept` confirms a candidate is a real sheet (for ours, that
    /// its test code reads); filled bubbles can line up like squares, so unconfirmed candidates are passed over.
    func find(_ image: LumaImage, accept: (FoundSheet) -> Bool = { _ in true }) -> (corners: [CGPoint], kind: SheetKind)? {
        findAll(image, limit: 1, preferMiddle: true, accept: accept).first.map { ($0.corners, $0.kind) }
    }

    /// Every sheet in the frame (up to `limit`), best-fitting first, each confirmed by `accept`.
    func findAll(_ image: LumaImage, limit: Int = 8, preferMiddle: Bool = false, accept: (FoundSheet) -> Bool = { _ in true }) -> [FoundSheet] {
        guard downscale(image) else { return [] }
        let blobs = squares()
        guard blobs.count >= 5 else { return [] }
        let f = Double(factor), w = Double(image.width), h = Double(image.height)
        var used = Set<Int>(), out: [FoundSheet] = []
        for fit in fits(blobs, preferMiddle: preferMiddle) where out.count < limit {
            let parts = fit.corners + fit.markers
            guard parts.allSatisfy({ !used.contains($0) }) else { continue }
            let sheet = FoundSheet(corners: fit.corners.map { CGPoint(x: (f * blobs[$0].x + f / 2) / w, y: (f * blobs[$0].y + f / 2) / h) },
                                   kind: fit.kind)
            guard accept(sheet) else { continue }
            used.formUnion(parts)
            out.append(sheet)
        }
        return out
    }

    private func downscale(_ image: LumaImage) -> Bool {
        factor = max(3, max(image.width, image.height) / 640)
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
                        for y in minY...maxY {
                            for x in minX...maxX where label[y * w + x] == next {
                                let dx = Double(x) - cx, dy = Double(y) - cy
                                reach2 = max(reach2, dx * dx + dy * dy)
                            }
                        }
                        let reach = reach2.squareRoot() + 0.5
                        let shape = Double(area) / (reach * reach)
                        guard shape > 1.5, shape < 2.6 else { continue }
                        blobs.append(Blob(x: cx, y: cy, side: Double(area).squareRoot(), shape: shape))
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

    /// Every way four squares make a sheet whose extra squares are where its kind puts them, best first.
    /// Each square is only tried with its nearest similar-sized neighbors, so many sheets in view stay fast.
    private func fits(_ blobs: [Blob], preferMiddle: Bool) -> [Fit] {
        // Corner and edge squares are square; filled bubbles, which can be the same size, are round.
        let square: (Int) -> Bool = { blobs[$0].shape < 2.45 }
        let cands = Array(blobs.indices.filter(square).sorted { blobs[$0].side > blobs[$1].side }.prefix(40))
        let sheet = Self.unitCorners
        let middle = CGPoint(x: Double(width) / 2, y: Double(height) / 2), diagonal = hypot(Double(width), Double(height))
        let dist: (Int, Int) -> Double = { hypot(blobs[$0].x - blobs[$1].x, blobs[$0].y - blobs[$1].y) }
        var seen = Set<[Int]>(), out: [Fit] = []
        let similar: (Int, Int) -> Bool = { blobs[$0].side < 1.8 * blobs[$1].side && blobs[$1].side < 1.8 * blobs[$0].side }
        for a in cands {
            // Two nearby squares as the corners next to `a`; the fourth corner is looked for where they point
            // (other sheets laid close by can be nearer than a sheet's own opposite corner).
            let n = Array(cands.filter { $0 != a && similar(a, $0) }.sorted { dist(a, $0) < dist(a, $1) }.prefix(14))
            for i in 0..<n.count { for j in i + 1 ..< n.count {
                let b = blobs[n[i]], c = blobs[n[j]], ax = blobs[a].x, ay = blobs[a].y
                let px = b.x + c.x - ax, py = b.y + c.y - ay
                let reach = 0.3 * min(dist(a, n[i]), dist(a, n[j]))
                guard let d = cands.filter({ $0 != a && $0 != n[i] && $0 != n[j] && similar(a, $0) })
                        .min(by: { hypot(blobs[$0].x - px, blobs[$0].y - py) < hypot(blobs[$1].x - px, blobs[$1].y - py) }),
                      hypot(blobs[d].x - px, blobs[d].y - py) < reach else { continue }
                let key = [a, n[i], n[j], d].sorted()
                guard seen.insert(key).inserted else { continue }
                let quad = key.map { blobs[$0] }
                let biggest = quad.map(\.side).max()!, smallest = quad.map(\.side).min()!
                guard biggest <= 1.8 * smallest else { continue }
                let mx = quad.reduce(0) { $0 + $1.x } / 4, my = quad.reduce(0) { $0 + $1.y } / 4
                let order = key.indices.sorted { atan2(quad[$0].y - my, quad[$0].x - mx) < atan2(quad[$1].y - my, quad[$1].x - mx) }   // clockwise on screen
                let ring = order.map { quad[$0] }, ids = order.map { key[$0] }
                guard area(ring) > 12 * biggest * biggest else { continue }
                // A sheet in perspective is still roughly a parallelogram: opposite sides of similar length.
                let sides = (0..<4).map { hypot(ring[$0].x - ring[($0 + 1) % 4].x, ring[$0].y - ring[($0 + 1) % 4].y) }
                guard sides[0] < 2 * sides[2], sides[2] < 2 * sides[0], sides[1] < 2 * sides[3], sides[3] < 2 * sides[1] else { continue }
                for turn in 0..<4 {
                    let corners = (0..<4).map { ring[($0 + turn) % 4] }, cornerIds = (0..<4).map { ids[($0 + turn) % 4] }
                    guard let map = Homography(sheet, corners.map { CGPoint(x: $0.x, y: $0.y) }) else { continue }
                    for kind in [SheetKind.gradescan, .zipgrade20] {
                        // Each kind's squares are a set share of the width between the corner squares' centers
                        // (ours 0.25 in over 3.3–3.9 in, ZipGrade's 0.17 in over 3.4 in). Page text and bubbles don't line up like that.
                        let half = kind.squareHalf
                        let sized = zip(sheet, corners).allSatisfy { point, blob in
                            let a = map.apply(CGPoint(x: point.x - half, y: point.y)), b = map.apply(CGPoint(x: point.x + half, y: point.y))
                            let expected = hypot(b.x - a.x, b.y - a.y)
                            return blob.side > 0.6 * expected && blob.side < 1.6 * expected
                        }
                        guard sized else { continue }
                        let expected = corners.reduce(0) { $0 + $1.side } / 4
                        var total = 0.0, markers: [Int] = []
                        for marker in kind.markers {
                            let predicted = map.apply(marker)
                            var miss = Double.infinity, found: Int?
                            for b in blobs.indices where square(b) {
                                let d = hypot(blobs[b].x - predicted.x, blobs[b].y - predicted.y)
                                if d < miss { miss = d; found = b }
                            }
                            guard let found, miss < 0.4 * expected, blobs[found].side > 0.55 * expected, blobs[found].side < 1.8 * expected else { break }
                            total += miss
                            markers.append(found)
                        }
                        guard markers.count == kind.markers.count else { continue }
                        var score = total / Double(markers.count) / expected
                        if preferMiddle { score += 0.3 * hypot(mx - middle.x, my - middle.y) / diagonal }
                        out.append(Fit(score: score, corners: cornerIds, markers: markers, kind: kind))
                    }
                }
            }}
        }
        return out.sorted { $0.score < $1.score }
    }

    private func area(_ ring: [Blob]) -> Double {
        var sum = 0.0
        for i in 0..<ring.count {
            let a = ring[i], b = ring[(i + 1) % ring.count]
            sum += a.x * b.y - b.x * a.y
        }
        return abs(sum) / 2
    }
}
