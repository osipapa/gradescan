import AVFoundation
import UIKit

enum ScanEvent {
    case cameraDenied
    case frame(FrameInfo)     // every camera frame: the sheets in view, for the outlines and the status
    case captured(Capture)    // a sheet was captured (from the video, right away)
    case photo(PhotoResult)   // its full-resolution photo was read, a moment later
    case alreadyScanned       // the sheet just captured came round again (lost for a moment, then found): not taken twice
}

/// One sheet in view, followed from frame to frame.
struct SheetInView {
    let track: Int            // the same number while the sheet stays in view
    var quiz: Quiz?           // its test (nil: a sheet of an unknown test, or its code didn't read this frame)
    var map: Homography?      // sheet inches → image points; corner-to-corner units when the layout isn't known
    var layout: SheetLayout?
    var unknownTest = false
    var wrongTest = false     // a known test, but not the one being rescanned
    var zipgrade = false      // a ZipGrade form
    var needsTest = false     // …and the teacher hasn't said which test ZipGrade sheets are for
    var partial = false       // a corner is out of sight (a thumb, glare): outlined where it was, not read
    var gate: GateOutput
}

struct FrameInfo {
    let sheets: [SheetInView]
    var hint: ScanHint?   // what to change, once nothing has locked on for a moment
}

/// What the teacher can do when no sheet locks on.
enum ScanHint: Equatable {
    case dark      // too dark (the flashlight comes on by itself)
    case glare     // light washing out part of the sheet
    case far       // too far away to be sure of the squares
    case corners   // a corner is out of view or covered
}

struct Capture {
    let id: String
    let quiz: Quiz
    let number: Int?          // printed student number (named sheets)
    let period: Int?
    let answers: String
    let name: GrayStrip?      // the handwritten name from the video frame, in case the photo fails
    let scannedAt: Date
    var kind: SheetKind = .gradescan
    var periodBox: GrayStrip?   // ZipGrade: the handwritten period, from the video frame
    var dateBox: GrayStrip?     // ZipGrade: the handwritten date, from the video frame
    var track = 0
    var corners: [CGPoint] = []   // where it was in the video frame (normalized), to find it again in the photo
    var videoAspect = 16.0 / 9
    var picture: Data?            // the straightened sheet from the video frame, in case the photo fails
}

struct PhotoResult {
    let id: String
    let answers: String?      // the photo's reading; nil if the photo couldn't be read
    let period: Int?
    let name: GrayStrip?
    let jpeg: Data?           // the straightened sheet (no marks; the apps draw them)
    var rows: [Int: RowReview] = [:]   // rows left for the teacher to check
    var periodBox: GrayStrip?          // ZipGrade: the handwritten period, from the photo
    var dateBox: GrayStrip?            // ZipGrade: the handwritten date, from the photo
}

/// Runs the camera, finds answer sheets by their black squares (several at once), reads them, and captures each one
/// once when it's steady. Every mutable property is only touched on `queue`, which is what makes `@unchecked Sendable` safe.
final class Scanner: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    /// Set once before `start()`. Called on the scanner queue.
    var onEvent: (@Sendable (ScanEvent) -> Void)?

    private let queue = DispatchQueue(label: "gradescan.scanner")
    private let photoQueue = DispatchQueue(label: "gradescan.photo")
    private var tests: [Int: Quiz] = [:]   // by the code printed on their sheets
    private var configured = false
    private var camera: AVCaptureDevice?
    private var pressureWatch: NSKeyValueObservation?
    private var reducedResourceUsage = false
    private var frameCap: Int32?   // nil = the camera's full frame rate

    private let finder = BoxFinder()
    private let photoOutput = AVCapturePhotoOutput()
    private let photoFinder = BoxFinder()           // only used on photoQueue
    private var photoJobs: [Int64: PhotoJob] = [:]

    /// A sheet followed from frame to frame, with its own capture gate, so each sheet in view is captured once.
    private struct Track {
        let id: Int
        var corners: [CGPoint]
        var gate = CaptureGate()
        var lastSeen: TimeInterval
        var lastCode: Int?
        var lastNumber: Int?
        var frames = 0   // frames it's been found in; it's outlined from the third, so one-frame flukes never show
        var ignored = false   // already used for something else (an answer key): passed over until it leaves the view
        var kind = SheetKind.gradescan
        var lastInfo: SheetInView?   // what was shown for it, kept while a corner is out of sight
        var center: CGPoint { CGPoint(x: corners.reduce(0) { $0 + $1.x } / 4, y: corners.reduce(0) { $0 + $1.y } / 4) }
    }
    private var tracks: [Track] = []
    private var nextTrack = 1
    /// What was captured lately: a sheet lost for a moment and found again comes back as a new track, with a new
    /// gate, and would be captured twice. The same test and student number, the same answers, in about the same
    /// place, a few seconds later, is the same sheet.
    private var recent: [(identity: String, answers: String, name: NameMark?, center: CGPoint, time: TimeInterval)] = []
    private var answerKey = false   // reading an answer key: a longer, deliberate hold
    private var searchingSince: TimeInterval?   // when the camera last stopped seeing a sheet it can read
    private var frameRequest: ((Data?, String) -> Void)?   // save the next frame, for a sheet that won't scan
    private var single = false      // one sheet at a time, and scanning waits after each capture
    private var paused = false      // single mode: waiting for the teacher after a capture
    private var expected: String?   // during a rescan, the only test that may be captured
    private var zipgradeQuiz: Quiz?   // the test ZipGrade sheets are for (they carry no test code)
    private var held = false        // frames are ignored, e.g. while a card is open over the camera

    /// Passes over the sheets in view until they leave it (the answer key just read, so it isn't scanned as a student's).
    func ignoreInView() {
        queue.async { for i in self.tracks.indices { self.tracks[i].ignored = true } }
    }

    /// Hands over the next camera frame as a JPEG, with a note of what the scanner made of it (JSON).
    func saveNextFrame(_ done: @escaping (Data?, String) -> Void) {
        queue.async { self.frameRequest = done }
    }

    /// Reading an answer key: the sheets already in view are passed over (the teacher is still looking for the key),
    /// and the key has to be held steady for a second before it's taken.
    func setAnswerKey(_ on: Bool) {
        queue.async {
            self.answerKey = on
            self.paused = false
            for i in self.tracks.indices {
                if on { self.tracks[i].ignored = true }
                self.tracks[i].gate.lockDuration = on ? 1.0 : CaptureGate.lockDuration
            }
        }
    }

    func setTests(_ list: [Quiz]) {
        let byCode = Dictionary(list.compactMap { q in q.sheetCode.map { ($0, q) } }, uniquingKeysWith: { first, _ in first })
        queue.async { self.tests = byCode }
    }

    /// Single mode captures one sheet and waits; batch mode captures every sheet in view. `expect` limits captures to
    /// one test (rescans).
    func configure(single: Bool, expect quizId: String?) {
        queue.async {
            self.single = single
            self.expected = quizId
        }
    }

    /// Ready to capture whatever is in view, even sheets that were just captured.
    func reset() {
        queue.async {
            self.tracks = []
            self.paused = false
        }
    }

    /// Continue after a pause: `rescan` captures the sheets in view again; otherwise wait for the next sheet.
    func resume(rescan: Bool) {
        queue.async {
            self.paused = false
            for i in self.tracks.indices { self.tracks[i].gate.resume(rescan: rescan) }
        }
    }

    func hold(_ on: Bool) { queue.async { self.held = on } }

    /// Which test ZipGrade sheets are for, as chosen by the teacher.
    func setZipGrade(_ quiz: Quiz?) { queue.async { self.zipgradeQuiz = quiz } }

    /// iOS 27 can ask apps to scale back, for example in Low Power Mode. Scanning then runs at a lower frame rate.
    func setReducedResourceUsage(_ on: Bool) {
        queue.async {
            self.reducedResourceUsage = on
            self.updateFrameRate()
        }
    }

    func start() {
        AVCaptureDevice.requestAccess(for: .video) { granted in
            guard granted else { self.onEvent?(.cameraDenied); return }
            self.queue.async {
                if !self.configured { self.configure() }
                if !self.session.isRunning { self.session.startRunning() }
            }
        }
    }

    func stop() {
        queue.async { if self.session.isRunning { self.session.stopRunning() } }
    }

    /// Flashlight for dim rooms.
    func setTorch(_ on: Bool) {
        queue.async {
            guard let camera = self.camera, camera.hasTorch, (try? camera.lockForConfiguration()) != nil else { return }
            camera.torchMode = on ? .on : .off
            camera.unlockForConfiguration()
        }
    }

    private func configure() {
        configured = true
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device) else { return }
        camera = device
        session.beginConfiguration()
        if session.canAddInput(input) { session.addInput(input) }
        if session.canSetSessionPreset(.hd1920x1080) { session.sessionPreset = .hd1920x1080 }
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(output) { session.addOutput(output) }
        if session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)
            // 12 MP is plenty for a sheet and much faster than 48 MP.
            let sizes = device.activeFormat.supportedMaxPhotoDimensions
            if let size = sizes.filter({ $0.width <= 4032 }).max(by: { $0.width < $1.width }) ?? sizes.first {
                photoOutput.maxPhotoDimensions = size
            }
        }
        session.commitConfiguration()
        if (try? device.lockForConfiguration()) != nil {
            if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
            if device.isAutoFocusRangeRestrictionSupported { device.autoFocusRangeRestriction = .near }
            if #available(iOS 27.0, *) {
                // Tell auto exposure it's looking at printed paper under classroom lights. On cameras that support it,
                // it keeps print sharp, avoids light flicker, and shortens the exposure while a sheet is still moving.
                let wanted = Set<AVCaptureDeviceExposureSignal>([.document, .flicker, .subjectMotion])
                    .intersection(device.supportedExposureSignals)
                if !wanted.isSubset(of: device.enabledExposureSignals) {
                    let enabled = device.enabledExposureSignals.union(wanted)
                    device.automaticallyEnablesExposureSignals = false
                    device.enabledExposureSignals = enabled
                }
            }
            device.unlockForConfiguration()
        }
        // A phone held over a stack of sheets runs the camera for a long time, so slow down before it overheats.
        pressureWatch = device.observe(\.systemPressureState, options: [.initial, .new]) { [weak self] _, _ in
            guard let self else { return }
            self.queue.async { self.updateFrameRate() }
        }
    }

    /// Caps scanning at 15 frames a second while the phone is hot, the battery is strained, or iOS asks apps
    /// to use less power. Returns to the full frame rate afterwards.
    private func updateFrameRate() {
        guard let camera else { return }
        let pressure = camera.systemPressureState
        var strained = pressure.level == .serious || pressure.level == .critical
        if #available(iOS 27.0, *), pressure.factors.contains(.batteryStress) { strained = true }
        let cap: Int32? = strained || reducedResourceUsage ? 15 : nil
        guard cap != frameCap else { return }
        if #available(iOS 18.0, *), camera.isAutoVideoFrameRateEnabled { return }
        if let cap, !camera.activeFormat.videoSupportedFrameRateRanges.contains(where: {
            ($0.minFrameRate...$0.maxFrameRate).contains(Double(cap))
        }) { return }
        guard (try? camera.lockForConfiguration()) != nil else { return }
        camera.activeVideoMinFrameDuration = cap.map { CMTime(value: 1, timescale: $0) } ?? .invalid
        camera.unlockForConfiguration()
        frameCap = cap
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard !held, !paused, let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pixels, 0) else { return }
        let image = LumaImage(base: base.assumingMemoryBound(to: UInt8.self),
                              width: CVPixelBufferGetWidthOfPlane(pixels, 0),
                              height: CVPixelBufferGetHeightOfPlane(pixels, 0),
                              bytesPerRow: CVPixelBufferGetBytesPerRowOfPlane(pixels, 0))
        // A candidate of ours is a real sheet if one of the teacher's tests' codes reads on it and that test's bubbles
        // are printed where its layout puts them; or, for a test not on this phone yet, if a code reads crisply
        // and the strip above the sheet is blank or a student number. A ZipGrade candidate needs its printed
        // bubbles where the form puts them. (A sheet whose code blurs for a frame is followed; see below.)
        let accept: (FoundSheet) -> Bool = { sheet in
            guard sheet.kind == .gradescan else { return ZipGrade.looksReal(image, corners: sheet.corners) }
            guard let unit = Homography(BoxFinder.unitCorners, sheet.corners) else { return false }
            if let code = Reader.testCode(image, unit), let quiz = self.tests[code] {
                guard let layout = quiz.layout, let map = Homography(layout.cornerPoints, sheet.corners) else { return false }
                return layout.printed(in: image, map: map)
            }
            return Reader.testCode(image, unit, strict: true) != nil && Self.topStripClean(image, unit)
        }
        // Single mode follows the sheet nearest the middle; batch mode every sheet laid out in view.
        let sheets = single ? finder.find(image, accept: accept).map { [FoundSheet(corners: $0.corners, kind: $0.kind)] } ?? []
                            : finder.findAll(image, limit: 6, accept: accept)

        // Match each sheet to the track it was in the frames before (by where its middle is); new sheets get a track.
        var free = Set(tracks.indices), matched: [(Int, FoundSheet)] = []
        for sheet in sheets {
            let c = sheet.center
            let near = free.min { hypot(tracks[$0].center.x - c.x, tracks[$0].center.y - c.y) < hypot(tracks[$1].center.x - c.x, tracks[$1].center.y - c.y) }
            if let t = near, hypot(tracks[t].center.x - c.x, tracks[t].center.y - c.y) < 0.12 {
                free.remove(t)
                matched.append((t, sheet))
            } else {
                var track = Track(id: nextTrack, corners: sheet.corners, lastSeen: time)
                track.gate.lockDuration = answerKey ? 1.0 : CaptureGate.lockDuration
                tracks.append(track)
                nextTrack += 1
                matched.append((tracks.count - 1, sheet))
            }
        }
        // A sheet the full search missed this frame but saw a moment ago (a corner blurred, caught the light, or went
        // under a thumb): its squares are looked for near where they were. With all four corners and its code
        // still reading, it's read as usual. With one corner out of sight, it's only outlined, and its gate waits:
        // it can't be captured, nor count as gone and be captured again.
        var partial = Set<Int>()
        for t in free.sorted() where !tracks[t].ignored && time - tracks[t].lastSeen < 0.5 {
            let track = tracks[t]
            guard let (sheet, carried) = finder.follow(FoundSheet(corners: track.corners, kind: track.kind), in: image) else { continue }
            // Read only when it's certainly the same sheet: all four corners, and its code (or ZipGrade's bubbles) still
            // there. Otherwise, a blurred frame say, it's only outlined.
            var same = false
            if !carried {
                if sheet.kind == .zipgrade20 {
                    same = ZipGrade.looksReal(image, corners: sheet.corners)
                } else if let code = Homography(BoxFinder.unitCorners, sheet.corners).flatMap({ Reader.testCode(image, $0) }) {
                    same = code == track.lastCode
                }
            }
            if !same { partial.insert(t) }
            free.remove(t)
            matched.append((t, sheet))
        }
        // A sheet that isn't in view: its gate hears "no sheet" (and re-arms once it's been gone a moment).
        for t in free { _ = tracks[t].gate.step(GateFrame(time: time, sheet: nil)) }

        var infos: [SheetInView] = [], captures: [Capture] = []
        for (t, sheet) in matched {
            if tracks[t].ignored {
                tracks[t].corners = sheet.corners
                tracks[t].lastSeen = time
                continue
            }
            if partial.contains(t) {
                tracks[t].corners = sheet.corners
                tracks[t].lastSeen = time
                if var info = tracks[t].lastInfo {
                    info.map = Homography(info.layout?.cornerPoints ?? BoxFinder.unitCorners, sheet.corners)
                    info.partial = true
                    infos.append(info)
                }
                continue
            }
            tracks[t].kind = sheet.kind
            let (info, capture) = follow(t, sheet, image, time)
            tracks[t].lastInfo = info
            tracks[t].frames += 1
            if tracks[t].frames >= 3 || capture != nil { infos.append(info) }
            if var capture {
                capture.videoAspect = Double(image.width) / Double(image.height)
                captures.append(capture)
            }
        }
        tracks.removeAll { time - $0.lastSeen > ($0.ignored ? 0.4 : 1.5) }
        let frameHint = hint(infos, time)
        onEvent?(.frame(FrameInfo(sheets: infos, hint: frameHint)))
        if let request = frameRequest {
            frameRequest = nil
            let look = finder.look
            let note: [String: Any] = [
                "found": sheets.map { ["kind": $0.kind.rawValue, "corners": $0.corners.map { [$0.x, $0.y] }] },
                "tracks": tracks.count, "hint": frameHint.map { "\($0)" } ?? "none", "single": single,
                "brightness": look.brightness, "glare": look.glare, "far": look.tiny,
                "size": [image.width, image.height], "app": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "",
            ]
            let json = (try? JSONSerialization.data(withJSONObject: note, options: [.prettyPrinted, .sortedKeys])).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            request(ProblemFrames.jpeg(image), json)
        }
        if !captures.isEmpty {
            for capture in captures { onEvent?(.captured(capture)) }
            takePhoto(captures)
            if single { paused = true }
        }
    }

    /// Once nothing readable has been in view for a moment, the likeliest reason: a covered corner, too little light,
    /// glare, or distance.
    private func hint(_ infos: [SheetInView], _ time: TimeInterval) -> ScanHint? {
        if infos.contains(where: { !$0.partial }) { searchingSince = nil; return nil }
        let since = searchingSince ?? time
        searchingSince = since
        guard time - since > 1.2 else { return nil }
        if !infos.isEmpty { return .corners }
        let look = finder.look
        if look.brightness < 55 { return .dark }
        if look.glare > 0.004 { return .glare }
        if look.tiny { return .far }
        return nil
    }

    /// Reads one sheet in view and steps its gate. Returns what to show for it, and a capture when the gate fires.
    private func follow(_ t: Int, _ sheet: FoundSheet, _ image: LumaImage, _ time: TimeInterval) -> (SheetInView, Capture?) {
        var track = tracks[t]
        defer { tracks[t] = track }
        let corners = sheet.corners, nothing = GateFrame(time: time, sheet: nil)
        // The printed codes can blur for a frame; a sheet that hasn't moved keeps the codes it had.
        let steady = zip(corners, track.corners).allSatisfy { hypot($0.x - $1.x, $0.y - $1.y) < 0.02 }
        track.corners = corners
        track.lastSeen = time
        guard let unit = Homography(BoxFinder.unitCorners, corners) else { return (SheetInView(track: track.id, gate: track.gate.step(nothing)), nil) }

        var quiz: Quiz?, layout: SheetLayout?, number: Int?, identity = ""
        if sheet.kind == .zipgrade20 {
            guard let chosen = zipgradeQuiz else {
                return (SheetInView(track: track.id, map: unit, zipgrade: true, needsTest: true, gate: track.gate.step(nothing)), nil)
            }
            quiz = chosen
            layout = ZipGrade.form20
            identity = "\(chosen.id)|zipgrade"
        } else {
            guard let code = Reader.testCode(image, unit) ?? (steady ? track.lastCode : nil) else {
                track.lastCode = nil
                return (SheetInView(track: track.id, map: unit, gate: track.gate.step(nothing)), nil)
            }
            track.lastCode = code
            guard let known = tests[code], known.layout != nil else {
                return (SheetInView(track: track.id, map: unit, unknownTest: true, gate: track.gate.step(nothing)), nil)
            }
            quiz = known
            layout = known.layout
            number = Reader.studentNumber(image, unit) ?? (steady ? track.lastNumber : nil)
            track.lastNumber = number
            identity = "\(known.id)|\(number ?? 0)"
        }
        guard let quiz, let layout, let map = Homography(layout.cornerPoints, corners) else {
            return (SheetInView(track: track.id, map: unit, gate: track.gate.step(nothing)), nil)
        }
        var info = SheetInView(track: track.id, quiz: quiz, map: map, layout: layout, zipgrade: sheet.kind == .zipgrade20, gate: .idle)
        if let expected, quiz.id != expected {
            info.wrongTest = true
            info.gate = track.gate.step(nothing)
            return (info, nil)
        }
        let read = Reader.read(quiz, layout, image, map), name = NameMark.read(layout, image, map)
        var frame = SheetRead(corners: corners, identity: identity, period: read.period, answers: read.answers)
        frame.name = name
        info.gate = track.gate.step(GateFrame(time: time, sheet: frame))
        guard case .fire(let period, let answers) = info.gate else { return (info, nil) }
        // Came round again: the same sheet captured a moment ago here, lost from view for a moment and found again:
        // the same answers, and not a different handwritten name. (A rescan is the teacher asking for it again.)
        let center = track.center
        recent.removeAll { time - $0.time > 15 }
        let seen = recent.contains { r in
            let otherName = r.name.map { old in name.map { $0.likeness(old) < 0.35 } ?? false } ?? false
            return r.identity == identity && hypot(r.center.x - center.x, r.center.y - center.y) < 0.2
                && zip(r.answers, answers).filter { $0 != $1 }.count <= 1 && !otherName
        }
        if expected == nil && seen {
            info.gate = .waiting
            onEvent?(.alreadyScanned)
            return (info, nil)
        }
        recent.append((identity, answers, name, center, time))
        var capture = Capture(id: UUID().uuidString.lowercased(), quiz: quiz, number: number, period: period, answers: answers,
                              name: Reader.nameStrip(layout, image, map), scannedAt: Date())
        capture.kind = sheet.kind
        capture.periodBox = layout.periodBox.flatMap { Reader.strip($0, image, map) }
        capture.dateBox = layout.dateBox.flatMap { Reader.strip($0, image, map) }
        capture.track = track.id
        capture.corners = corners
        capture.picture = Reader.sheetJPEG(layout, [], image, map, pixelsPerInch: 110)
        return (info, capture)
    }

    /// The strip between the top corner squares, where a named sheet has its student number: blank paper, or a
    /// number that reads. Filled bubbles that line up like a sheet leave ink there.
    private static func topStripClean(_ img: LumaImage, _ unit: Homography) -> Bool {
        if Reader.studentNumber(img, unit) != nil { return true }
        let width = Double(img.width), height = Double(img.height)
        return (0..<16).allSatisfy { i in
            let u = 0.2 + Double(i) * 0.04
            let c = unit.apply(CGPoint(x: u, y: 0)), next = unit.apply(CGPoint(x: u + 0.04, y: 0))
            let pitch = hypot((next.x - c.x) * width, (next.y - c.y) * height)
            let at: (Double, Double) -> Double = { dx, dy in img.at(CGPoint(x: c.x + dx / width, y: c.y + dy / height)) }
            let ink = at(0, 0), paper = (0..<8).map { k in at(0.5 * pitch * cos(Double(k) * .pi / 4), 0.5 * pitch * sin(Double(k) * .pi / 4)) }.max() ?? 0
            return paper > 0 && 1 - ink / paper < 0.2
        }
    }

    /// One full-resolution, silent (where iOS allows) photo for the sheets just captured. It settles answers the
    /// video couldn't read, reads the handwritten names better, and is kept, clean, for the record.
    private func takePhoto(_ captures: [Capture]) {
        let failed: (Capture) -> PhotoResult = { PhotoResult(id: $0.id, answers: nil, period: nil, name: nil, jpeg: nil) }
        guard session.isRunning, photoOutput.availablePhotoPixelFormatTypes.contains(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) else {
            for capture in captures { onEvent?(.photo(failed(capture))) }
            return
        }
        let settings = AVCapturePhotoSettings(format: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange])
        settings.maxPhotoDimensions = photoOutput.maxPhotoDimensions
        settings.photoQualityPrioritization = .speed   // quick, and the camera keeps running smoothly
        if #available(iOS 18.0, *), photoOutput.isShutterSoundSuppressionSupported { settings.isShutterSoundSuppressionEnabled = true }
        let id = settings.uniqueID
        let job = PhotoJob { [weak self] pixels in
            guard let self else { return }
            self.queue.async { self.photoJobs[id] = nil }
            self.photoQueue.async {
                for result in self.read(pixels, captures) { self.onEvent?(.photo(result)) }
            }
        }
        photoJobs[id] = job
        photoOutput.capturePhoto(with: settings, delegate: job)
    }

    private func read(_ pixels: CVPixelBuffer?, _ captures: [Capture]) -> [PhotoResult] {
        let failed: (Capture) -> PhotoResult = { PhotoResult(id: $0.id, answers: nil, period: nil, name: nil, jpeg: nil) }
        guard let pixels else { return captures.map(failed) }
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pixels, 0) else { return captures.map(failed) }
        let image = LumaImage(base: base.assumingMemoryBound(to: UInt8.self),
                              width: CVPixelBufferGetWidthOfPlane(pixels, 0), height: CVPixelBufferGetHeightOfPlane(pixels, 0),
                              bytesPerRow: CVPixelBufferGetBytesPerRowOfPlane(pixels, 0))
        let byCode = Dictionary(captures.compactMap { c in c.quiz.sheetCode.map { ($0, c.quiz) } }, uniquingKeysWith: { a, _ in a })
        let found = photoFinder.findAll(image, limit: 8, accept: { sheet in
            guard sheet.kind == .gradescan else { return ZipGrade.looksReal(image, corners: sheet.corners) }
            guard let code = Homography(BoxFinder.unitCorners, sheet.corners).flatMap({ Reader.testCode(image, $0) }),
                  let layout = byCode[code]?.layout, let map = Homography(layout.cornerPoints, sheet.corners) else { return false }
            return layout.printed(in: image, map: map)
        })
        let photoAspect = Double(image.width) / Double(image.height)
        return captures.map { capture in
            guard let sheet = match(capture, in: found, photoAspect: photoAspect), let layout = capture.kind.layout(for: capture.quiz),
                  let unit = Homography(BoxFinder.unitCorners, sheet.corners),
                  capture.kind == .zipgrade20 || Reader.testCode(image, unit) == capture.quiz.sheetCode,
                  let map = Homography(layout.cornerPoints, sheet.corners) else { return failed(capture) }
            let quiz = capture.quiz
            let read = Reader.read(quiz, layout, image, map, align: true)
            guard read.answers.count == capture.answers.count else { return failed(capture) }
            // The photo is sharper, so its reading wins. The photo is kept clean; the apps draw the ✓ and ✗ over it.
            let review = Review.rows(read.answers, marks: read.marks, key: quiz.answerKey)
            return PhotoResult(id: capture.id, answers: review.answers, period: read.period,
                               name: Reader.nameStrip(layout, image, map, pixelsPerInch: 200),
                               jpeg: Reader.sheetJPEG(layout, [], image, map, pixelsPerInch: 150),
                               rows: review.rows,
                               periodBox: layout.periodBox.flatMap { Reader.strip($0, image, map, pixelsPerInch: 200) },
                               dateBox: layout.dateBox.flatMap { Reader.strip($0, image, map, pixelsPerInch: 200) })
        }
    }

    /// The sheet in the photo that was at the capture's place in the video frame. The two can crop the sensor
    /// differently (16:9 video, 4:3 photo), so the video position is mapped into the photo's frame first.
    private func match(_ capture: Capture, in found: [FoundSheet], photoAspect: Double) -> FoundSheet? {
        let v = CGPoint(x: capture.corners.reduce(0) { $0 + $1.x } / 4, y: capture.corners.reduce(0) { $0 + $1.y } / 4)
        let p: CGPoint
        if photoAspect < capture.videoAspect {        // the photo shows more above and below
            p = CGPoint(x: v.x, y: 0.5 + (v.y - 0.5) * photoAspect / capture.videoAspect)
        } else {                                      // the photo shows more at the sides
            p = CGPoint(x: 0.5 + (v.x - 0.5) * capture.videoAspect / photoAspect, y: v.y)
        }
        let same = found.filter { $0.kind == capture.kind }
        guard let best = same.min(by: { hypot($0.center.x - p.x, $0.center.y - p.y) < hypot($1.center.x - p.x, $1.center.y - p.y) }),
              hypot(best.center.x - p.x, best.center.y - p.y) < 0.15 else { return nil }
        return best
    }
}

/// Camera preview with each sheet in view outlined. While a sheet locks on, a sage stroke grows around it.
final class PreviewView: UIView {
    enum Look { case plain, locking(Double), done, warn }

    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

    private final class Outline {
        let line = CAShapeLayer()
        let progress = CAShapeLayer()
        var shown: [CGPoint] = []   // corners on screen, smoothed
        var misses = 0
    }
    private var outlines: [Int: Outline] = [:]
    private let flashLayer = CAShapeLayer()
    private(set) var frozen = false

    private static let white = UIColor.white.withAlphaComponent(0.9).cgColor
    private static let sage = UIColor(red: 0x98 / 255, green: 0xA8 / 255, blue: 0x69 / 255, alpha: 1).cgColor
    private static let amber = MarkPaths.amber

    /// Holds the picture still (single mode, while the result card is up).
    func freeze(_ on: Bool) {
        frozen = on
        previewLayer.connection?.isEnabled = !on
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        previewLayer.videoGravity = .resizeAspectFill
        flashLayer.fillColor = UIColor.white.withAlphaComponent(0.6).cgColor
        flashLayer.opacity = 0
        layer.addSublayer(flashLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        flashLayer.frame = bounds
        for o in outlines.values { o.line.frame = bounds; o.progress.frame = bounds }
    }

    private func outline(_ id: Int) -> Outline {
        if let o = outlines[id] { return o }
        let o = Outline()
        for shape in [o.line, o.progress] {
            shape.frame = bounds
            shape.fillColor = UIColor.clear.cgColor
            shape.lineJoin = .round
            shape.lineCap = .round
            layer.insertSublayer(shape, below: flashLayer)
        }
        o.line.lineWidth = 3
        o.progress.lineWidth = 6
        o.progress.strokeColor = Self.sage
        o.progress.strokeEnd = 0
        outlines[id] = o
        return o
    }

    /// Outlines the sheets in view: each quad is a sheet's corners in capture-device points (0–1).
    func show(_ sheets: [(id: Int, quad: [CGPoint], look: Look)]) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        if frozen { return }
        let visible = Set(sheets.map(\.id))
        for (id, o) in outlines where !visible.contains(id) {
            o.misses += 1
            if o.misses > 12 {   // about 0.4 s out of view; short misses don't make the outline flash
                o.line.removeFromSuperlayer()
                o.progress.removeFromSuperlayer()
                outlines[id] = nil
            }
        }
        for sheet in sheets where sheet.quad.count == 4 {
            let o = outline(sheet.id)
            o.misses = 0
            let target = sheet.quad.map { previewLayer.layerPointConverted(fromCaptureDevicePoint: $0) }
            let close = o.shown.count == 4 && zip(target, o.shown).allSatisfy { hypot($0.x - $1.x, $0.y - $1.y) < 60 }
            // Ease toward the new corners so hand tremor doesn't make the outline jitter.
            o.shown = close ? zip(target, o.shown).map { CGPoint(x: 0.35 * $0.x + 0.65 * $1.x, y: 0.35 * $0.y + 0.65 * $1.y) } : target
            let path = Self.path(o.shown)
            o.line.path = path
            o.progress.path = path
            switch sheet.look {
            case .plain: o.line.strokeColor = Self.white; o.progress.strokeEnd = 0
            case .locking(let p): o.line.strokeColor = Self.white; o.progress.strokeEnd = p
            case .done: o.line.strokeColor = Self.sage; o.progress.strokeEnd = 0
            case .warn: o.line.strokeColor = Self.amber; o.progress.strokeEnd = 0
            }
        }
    }

    /// A quick white flash over a sheet when it's captured.
    func flash(_ id: Int) {
        guard let o = outlines[id], o.shown.count == 4 else { return }
        flashLayer.path = Self.path(o.shown)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.duration = 0.35
        flashLayer.add(fade, forKey: "flash")
    }

    private static func path(_ points: [CGPoint]) -> CGPath {
        let path = UIBezierPath()
        for (k, p) in points.enumerated() {
            if k == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        path.close()
        return path.cgPath
    }
}

/// Receives one photo and hands its pixels to a closure.
final class PhotoJob: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    private let handle: (CVPixelBuffer?) -> Void
    init(_ handle: @escaping (CVPixelBuffer?) -> Void) { self.handle = handle }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        handle(error == nil ? photo.pixelBuffer : nil)
    }
}
