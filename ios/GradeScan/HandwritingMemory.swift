import Accelerate
import CoreGraphics
import Foundation
import ImageIO
import Vision

/// What a handwritten name looks like, for telling students apart by their writing rather than by the letters read.
enum Handwriting {
    /// Vision's image feature print (768 numbers, about unit length) of the writing alone: printed lines removed,
    /// cropped to the ink, scaled to a set height. Two prints of one student's name are usually closer than prints of
    /// two students' names, even when the letters don't read. Nil when nothing is written.
    static func print(_ strip: GrayStrip) -> [Float]? {
        guard let ink = inkOnly(strip), let image = ink.cgImage() else { return nil }
        let request = VNGenerateImageFeaturePrintRequest()
        request.revision = VNGenerateImageFeaturePrintRequestRevision2
        request.imageCropAndScaleOption = .scaleFit   // a name is long and flat; stretching it square blurs who wrote it
        guard (try? VNImageRequestHandler(cgImage: image).perform([request])) != nil,
              let print = request.results?.first, print.elementType == .float, print.elementCount == 768 else { return nil }
        return print.data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    static func distance(_ a: [Float], _ b: [Float]) -> Float {
        a.count == b.count ? vDSP.distanceSquared(a, b).squareRoot() : .infinity
    }

    /// The writing alone, 48 pixels tall on a white margin; nil when there's hardly any ink.
    static func inkOnly(_ strip: GrayStrip) -> GrayStrip? {
        let w = strip.width, h = strip.height, source = strip.pixels
        guard w > 8, h > 8 else { return nil }
        var px = source
        let dark: (Int, Int) -> Bool = { x, y in source[y * w + x] < 128 }
        // Printed lines: thin bands of rows dark across most of the strip, kept only where a stroke crosses them.
        let rows = (0..<h).filter { y in (0..<w).reduce(0) { $0 + (dark($1, y) ? 1 : 0) } * 10 > w * 6 }
        for band in bands(rows) where band.count <= 6 {
            let top = band.lowerBound, bottom = band.upperBound - 1
            for x in 0..<w where !(top >= 2 && dark(x, top - 2) && bottom + 2 < h && dark(x, bottom + 2)) {
                for y in band { px[y * w + x] = 255 }
            }
        }
        // Box edges: thin bands of columns dark down most of the strip.
        let columns = (0..<w).filter { x in (0..<h).reduce(0) { $0 + (dark(x, $1) ? 1 : 0) } * 10 > h * 7 }
        for band in bands(columns) where band.count <= 6 {
            for x in band { for y in 0..<h { px[y * w + x] = 255 } }
        }
        // Where the ink is, ignoring specks: the middle 99% of it across, 98% down.
        var across = [Int](repeating: 0, count: w), down = [Int](repeating: 0, count: h), total = 0
        for y in 0..<h { for x in 0..<w where px[y * w + x] < 110 { across[x] += 1; down[y] += 1; total += 1 } }
        guard total >= 40 else { return nil }
        let (x0, x1) = span(across, total, 0.005), (y0, y1) = span(down, total, 0.01)
        guard x1 > x0, y1 > y0 else { return nil }
        // Scaled to 48 pixels tall (bilinear), on an 8-pixel margin.
        let height = 48, margin = 8
        let scale = Double(height) / Double(y1 - y0 + 1)
        let width = min(1000, max(1, Int((Double(x1 - x0 + 1) * scale).rounded())))
        let W = width + 2 * margin, H = height + 2 * margin
        var out = [UInt8](repeating: 255, count: W * H)
        for v in 0..<height {
            let sy = min(Double(h - 1), max(0, Double(y0) + (Double(v) + 0.5) / scale - 0.5))
            let ya = Int(sy), yb = min(h - 1, ya + 1), fy = sy - Double(ya)
            for u in 0..<width {
                let sx = min(Double(w - 1), max(0, Double(x0) + (Double(u) + 0.5) / scale - 0.5))
                let xa = Int(sx), xb = min(w - 1, xa + 1), fx = sx - Double(xa)
                let top = Double(px[ya * w + xa]) * (1 - fx) + Double(px[ya * w + xb]) * fx
                let bottom = Double(px[yb * w + xa]) * (1 - fx) + Double(px[yb * w + xb]) * fx
                out[(v + margin) * W + u + margin] = UInt8(clamping: Int((top * (1 - fy) + bottom * fy).rounded()))
            }
        }
        return GrayStrip(width: W, height: H, pixels: out)
    }

    /// Runs of consecutive indices.
    private static func bands(_ indices: [Int]) -> [Range<Int>] {
        var out: [Range<Int>] = []
        for i in indices {
            if let last = out.last, last.upperBound == i { out[out.count - 1] = last.lowerBound..<(i + 1) } else { out.append(i..<(i + 1)) }
        }
        return out
    }

    /// First and last index holding the middle (1 - 2 × trim) of the counts.
    private static func span(_ counts: [Int], _ total: Int, _ trim: Double) -> (Int, Int) {
        let low = Int(Double(total) * trim), high = total - low
        var sum = 0, first = 0, last = counts.count - 1, started = false
        for (i, c) in counts.enumerated() {
            sum += c
            if !started && sum > low { first = i; started = true }
            if sum >= high { last = i; break }
        }
        return (first, last)
    }

    /// A stored name picture (a JPEG data URL, as in the scans table) as a grayscale strip.
    static func strip(dataURL: String) -> GrayStrip? {
        guard let comma = dataURL.firstIndex(of: ","), let data = Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...])),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        let w = image.width, h = image.height
        var pixels = [UInt8](repeating: 255, count: w * h)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let ctx = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return drawn ? GrayStrip(width: w, height: h, pixels: pixels) : nil
    }
}

/// Learns what each student's handwritten name looks like from the sheets matched to them, so a rough name can be
/// recognized by the writing itself: a student's next sheet usually looks like their last one even when the letters
/// don't read. It learns from every scan that has a student, whether it was matched on this phone or in the portal,
/// and follows fixes: when a scan moves to another student, so does its sample. Kept on the phone, one file per account.
actor HandwritingMemory {
    static let shared = HandwritingMemory()

    struct Sample: Codable {
        let id: String          // the scan
        var studentId: String?  // nil until someone is matched
        let print: Data         // Handwriting.print, as Float32s
        let date: Date
    }

    private static let perStudent = 6   // the newest sheets of each student are enough; writing changes over a year
    private var user: String?
    private var samples: [String: Sample] = [:]
    private var vectors: [String: [Float]] = [:]
    private var sameWriter = 0.85   // print distance where writing stops looking like one student's; see calibrate()
    private var lastSync = Date.distantPast
    private var syncing = false

    /// How much more likely the writing is each remembered student's than anyone's: up to 20× for a very close match,
    /// down to ½ for writing unlike theirs. Students with nothing remembered are left out (count as 1).
    func likelihoods(_ print: [Float]?, user: String) -> [String: Double] {
        load(user)
        guard let print else { return [:] }
        var nearest: [String: Float] = [:]
        for (id, sample) in samples {
            guard let student = sample.studentId, let vector = vectors[id] else { continue }
            nearest[student] = min(nearest[student] ?? .infinity, Handwriting.distance(print, vector))
        }
        return nearest.mapValues { exp(max(-0.7, min(3, 10 * (sameWriter - Double($0))))) }
    }

    /// Keeps a scan's handwriting under the student it was matched to (nil: nobody yet; the server says later).
    func remember(_ scanId: String, studentId: String?, print: [Float]?, user: String) {
        load(user)
        guard let print else { return }
        add(Sample(id: scanId, studentId: studentId, print: print.withUnsafeBufferPointer { Data(buffer: $0) }, date: Date()))
        trim()
        save()
    }

    /// Brings every sample's student up to date with the server (fixes made on the phone or in the portal), and learns
    /// the handwriting of matched scans this phone hasn't seen, such as older sheets. At most every five minutes.
    func sync(user: String, token: String) async {
        load(user)
        guard !syncing, Date().timeIntervalSince(lastSync) > 300 else { return }
        syncing = true
        defer { syncing = false }
        struct Row: Decodable { let id: String; let student_id: String?; let scanned_at: String? }
        struct Picture: Decodable { let id: String; let student_id: String?; let name_image: String? }
        guard let rows: [Row] = try? await get("/rest/v1/scans?select=id,student_id,scanned_at&name_image=not.is.null&order=scanned_at.desc&limit=1000", token),
              self.user == user else { return }
        lastSync = Date()
        let server = Dictionary(rows.map { ($0.id, $0.student_id) }, uniquingKeysWith: { first, _ in first })
        let stale = Date().addingTimeInterval(-3 * 86_400)
        for (id, sample) in samples {
            if let student = server[id] { samples[id]?.studentId = student }
            else if sample.date < stale, rows.count < 1000 { samples[id] = nil; vectors[id] = nil }   // deleted or rejected
        }
        // Matched scans this phone has no sample of, newest first, until each student has enough.
        var count: [String: Int] = [:]
        for sample in samples.values { if let student = sample.studentId { count[student, default: 0] += 1 } }
        var wanted: [Row] = []
        for row in rows where wanted.count < 240 {
            guard let student = row.student_id, samples[row.id] == nil, count[student, default: 0] < Self.perStudent else { continue }
            count[student, default: 0] += 1
            wanted.append(row)
        }
        for start in stride(from: 0, to: wanted.count, by: 40) {
            let batch = wanted[start..<min(start + 40, wanted.count)]
            guard let pictures: [Picture] = try? await get("/rest/v1/scans?select=id,student_id,name_image&id=in.(\(batch.map(\.id).joined(separator: ",")))", token),
                  self.user == user else { break }
            let prints = await Task.detached(priority: .utility) {
                pictures.compactMap { p in p.name_image.flatMap(Handwriting.strip(dataURL:)).flatMap(Handwriting.print).map { (p, $0) } }
            }.value
            for (picture, print) in prints where samples[picture.id] == nil {
                let date = batch.first { $0.id == picture.id }?.scanned_at.flatMap(Self.date) ?? Date()
                add(Sample(id: picture.id, studentId: picture.student_id, print: print.withUnsafeBufferPointer { Data(buffer: $0) }, date: date))
            }
        }
        trim()
        calibrate()
        save()
    }

    // MARK: Storage

    private func add(_ sample: Sample) {
        samples[sample.id] = sample
        vectors[sample.id] = sample.print.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    /// The newest `perStudent` samples of each student, and of scans with nobody yet the newest 300.
    private func trim() {
        for (student, list) in Dictionary(grouping: samples.values, by: { $0.studentId ?? "" }) {
            let keep = student.isEmpty ? 300 : Self.perStudent
            for sample in list.sorted(by: { $0.date > $1.date }).dropFirst(keep) {
                samples[sample.id] = nil
                vectors[sample.id] = nil
            }
        }
    }

    /// How close writing gets to a student's samples when it isn't theirs, in this class: the distance only one in fifty
    /// other students' samples come within. Writing counts for a student only when it's closer than that.
    private func calibrate() {
        let byStudent = Dictionary(grouping: samples.values.filter { $0.studentId != nil }, by: { $0.studentId! })
            .mapValues { $0.compactMap { vectors[$0.id] } }
        guard byStudent.count >= 10 else { sameWriter = 0.85; return }
        var others: [Float] = []
        for (student, vectors) in byStudent.shuffled().prefix(40) {
            guard let v = vectors.first else { continue }
            for (other, theirs) in byStudent where other != student {
                if let d = theirs.map({ Handwriting.distance(v, $0) }).min() { others.append(d) }
            }
        }
        guard others.count >= 100 else { return }
        others.sort()
        sameWriter = min(0.9, max(0.6, Double(others[others.count / 50])))
    }

    private func load(_ user: String) {
        guard self.user != user else { return }
        self.user = user
        samples = [:]
        vectors = [:]
        lastSync = .distantPast
        if let data = try? Data(contentsOf: file(user)), let list = try? JSONDecoder().decode([Sample].self, from: data) {
            list.forEach(add)
        }
        calibrate()
    }

    private func save() {
        guard let user else { return }
        let url = file(user)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(Array(samples.values)).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private func file(_ user: String) -> URL {
        URL.applicationSupportDirectory.appendingPathComponent("Handwriting", isDirectory: true).appendingPathComponent("\(user).json")
    }

    private func get<T: Decodable>(_ path: String, _ token: String) async throws -> T {
        guard let url = URL(string: Config.supabaseURL + path) else { throw URLError(.badURL) }
        var request = URLRequest(url: url)
        request.setValue(Config.supabaseKey, forHTTPHeaderField: "apikey")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private static func date(_ text: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return withFraction.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}
