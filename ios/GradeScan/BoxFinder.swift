import Accelerate
import CoreGraphics

/// Finds an answer sheet by its five solid black squares (four corners, plus one on the left edge that tells up
/// from down). Works for every test: positions are measured between the corner squares' centers, so (0, 0) is the
/// top-left square, (1, 1) the bottom-right one, and the edge square sits at (0, 0.35).
/// Works on a one-third-size copy of the camera's luma plane. Use one finder per queue; it reuses its buffers.
final class BoxFinder {
    private struct Blob {
        let x: Double      // centroid in downscaled pixels
        let y: Double
        let side: Double   // square root of the area
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

    /// Centers of the corner squares in normalized image coordinates: top-left, top-right, bottom-right, bottom-left.
    func find(_ image: LumaImage) -> [CGPoint]? {
        guard downscale(image) else { return nil }
        let blobs = squares()
        guard blobs.count >= 5, let corners = bestFit(blobs) else { return nil }
        let f = Double(factor), w = Double(image.width), h = Double(image.height)
        return corners.map { CGPoint(x: (f * $0.x + f / 2) / w, y: (f * $0.y + f / 2) / h) }
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
                        let reach = reach2.squareRoot() + 0.7
                        let shape = Double(area) / (reach * reach)
                        guard shape > 1.5, shape < 2.6 else { continue }
                        blobs.append(Blob(x: cx, y: cy, side: Double(area).squareRoot()))
                    }
                }
            }
        }
        return blobs
    }

    /// The four corner squares, in top-left, top-right, bottom-right, bottom-left order, whose fitted sheet
    /// puts the fifth square where the layout says. Prefers the sheet nearest the middle of the frame.
    private func bestFit(_ blobs: [Blob]) -> [Blob]? {
        let cands = Array(blobs.sorted { $0.side > $1.side }.prefix(12)), n = cands.count
        let sheet = Self.unitCorners, marker = Self.unitMarker
        let middle = CGPoint(x: Double(width) / 2, y: Double(height) / 2), diagonal = hypot(Double(width), Double(height))
        var best: (score: Double, corners: [Blob])?
        for i in 0..<n { for j in i + 1 ..< n { for k in j + 1 ..< n { for l in k + 1 ..< n {
            let quad = [cands[i], cands[j], cands[k], cands[l]]
            let biggest = quad.map(\.side).max()!, smallest = quad.map(\.side).min()!
            guard biggest <= 1.8 * smallest else { continue }
            let mx = quad.reduce(0) { $0 + $1.x } / 4, my = quad.reduce(0) { $0 + $1.y } / 4
            let ring = quad.sorted { atan2($0.y - my, $0.x - mx) < atan2($1.y - my, $1.x - mx) }   // clockwise on screen
            guard area(ring) > 12 * biggest * biggest else { continue }
            for turn in 0..<4 {
                let corners = (0..<4).map { ring[($0 + turn) % 4] }
                guard let map = Homography(sheet, corners.map { CGPoint(x: $0.x, y: $0.y) }) else { continue }
                // Every sheet is 3.3–3.9 inches between the corner squares' centers and the squares are 0.25 inches,
                // so each square is about 7% of that width. Page text and bubbles don't line up like that.
                let sized = zip(sheet, corners).allSatisfy { point, blob in
                    let a = map.apply(CGPoint(x: point.x - 0.035, y: point.y)), b = map.apply(CGPoint(x: point.x + 0.035, y: point.y))
                    let expected = hypot(b.x - a.x, b.y - a.y)
                    return blob.side > 0.6 * expected && blob.side < 1.6 * expected
                }
                guard sized else { continue }
                let predicted = map.apply(marker), expected = corners.reduce(0) { $0 + $1.side } / 4
                var miss = Double.infinity, found: Blob?
                for blob in blobs {
                    let d = hypot(blob.x - predicted.x, blob.y - predicted.y)
                    if d < miss { miss = d; found = blob }
                }
                guard let found, miss < 0.4 * expected, found.side > 0.55 * expected, found.side < 1.8 * expected else { continue }
                let score = miss / expected + 0.3 * hypot(mx - middle.x, my - middle.y) / diagonal
                if score < best?.score ?? .infinity { best = (score, corners) }
            }
        }}}}
        return best?.corners
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
