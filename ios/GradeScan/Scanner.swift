import AVFoundation
import UIKit

enum ScanEvent {
    case cameraDenied
    case frame(FrameInfo)     // every camera frame: what's in view, for the outline and the status
    case captured(Capture)    // a sheet was captured (from the video, right away)
    case photo(PhotoResult)   // its full-resolution photo was read, a moment later
}

struct FrameInfo {
    let quiz: Quiz?           // the sheet's test (nil: no sheet, or a sheet of an unknown test)
    let map: Homography?      // sheet inches → image points; corner-to-corner units for an unknown test
    let unknownTest: Bool
    let wrongTest: Bool       // a known test, but not the one being rescanned
    let gate: GateOutput
}

struct Capture {
    let id: String
    let quiz: Quiz
    let number: Int?          // printed student number (named sheets)
    let period: Int?
    let answers: String
    let name: GrayStrip?      // the handwritten name from the video frame, in case the photo fails
    let scannedAt: Date
}

struct PhotoResult {
    let id: String
    let answers: String?      // the photo's reading merged with the video's; nil if the photo couldn't be read
    let period: Int?
    let name: GrayStrip?
    let jpeg: Data?           // the straightened sheet with the marks drawn on
    var rows: [Int: RowReview] = [:]   // rows left for the teacher to check
}

/// Runs the camera, finds an answer sheet by its black squares, reads it, and captures it once when it's steady.
/// Every mutable property is only touched on `queue`, which is what makes `@unchecked Sendable` safe here.
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
    private var lastCorners: [CGPoint] = []
    private var lastCode: Int?
    private var lastNumber: Int?
    private var gate = CaptureGate()
    private var expected: String?   // during a rescan, the only test that may be captured
    private var held = false        // frames are ignored, e.g. while a card is open over the camera

    func setTests(_ list: [Quiz]) {
        let byCode = Dictionary(list.compactMap { q in q.sheetCode.map { ($0, q) } }, uniquingKeysWith: { first, _ in first })
        queue.async { self.tests = byCode }
    }

    /// Single mode pauses after each capture; `expect` limits captures to one test (rescans).
    func configure(single: Bool, expect quizId: String?) {
        queue.async {
            self.gate.pausesAfterCapture = single
            self.expected = quizId
        }
    }

    /// Ready to capture whatever is in view, even the sheet that was just captured.
    func reset() { queue.async { self.gate.reset() } }

    /// Continue after a pause: `rescan` captures the sheet in view again; otherwise wait for the next sheet.
    func resume(rescan: Bool) { queue.async { self.gate.resume(rescan: rescan) } }

    func hold(_ on: Bool) { queue.async { self.held = on } }

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
        guard !held, let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pixels, 0) else { return }
        let image = LumaImage(base: base.assumingMemoryBound(to: UInt8.self),
                              width: CVPixelBufferGetWidthOfPlane(pixels, 0),
                              height: CVPixelBufferGetHeightOfPlane(pixels, 0),
                              bytesPerRow: CVPixelBufferGetBytesPerRowOfPlane(pixels, 0))
        let nothing = GateFrame(time: time, sheet: nil)
        guard let corners = finder.find(image), let unit = Homography(BoxFinder.unitCorners, corners) else {
            lastCorners = []
            emit(nil, nil, gate.step(nothing))
            return
        }
        // The printed codes can blur for a frame; a sheet that hasn't moved keeps the codes it had.
        let steady = lastCorners.count == 4 && zip(corners, lastCorners).allSatisfy { hypot($0.x - $1.x, $0.y - $1.y) < 0.02 }
        lastCorners = corners
        guard let code = Reader.testCode(image, unit) ?? (steady ? lastCode : nil) else {
            lastCode = nil
            emit(nil, nil, gate.step(nothing))
            return
        }
        lastCode = code
        guard let quiz = tests[code], let layout = quiz.layout, let map = Homography(layout.cornerPoints, corners) else {
            emit(nil, unit, gate.step(nothing), unknown: true)
            return
        }
        if let expected, quiz.id != expected {
            emit(quiz, map, gate.step(nothing), wrong: true)
            return
        }
        let number = Reader.studentNumber(image, unit) ?? (steady ? lastNumber : nil)
        lastNumber = number
        let read = Reader.read(quiz, layout, image, map)
        let out = gate.step(GateFrame(time: time, sheet: SheetRead(corners: corners, identity: "\(quiz.id)|\(number ?? 0)",
                                                                  period: read.period, answers: read.answers)))
        if case .fire(let period, let answers) = out {
            let capture = Capture(id: UUID().uuidString.lowercased(), quiz: quiz, number: number, period: period, answers: answers,
                                  name: Reader.nameStrip(layout, image, map), scannedAt: Date())
            onEvent?(.captured(capture))
            takePhoto(capture)
        }
        emit(quiz, map, out)
    }

    private func emit(_ quiz: Quiz?, _ map: Homography?, _ gate: GateOutput, unknown: Bool = false, wrong: Bool = false) {
        onEvent?(.frame(FrameInfo(quiz: quiz, map: map, unknownTest: unknown, wrongTest: wrong, gate: gate)))
    }

    /// One full-resolution, silent (where iOS allows) photo of the captured sheet. It settles answers the video
    /// couldn't read, reads the handwritten name better, and is kept, marked, for the record.
    private func takePhoto(_ capture: Capture) {
        let failed = PhotoResult(id: capture.id, answers: nil, period: nil, name: nil, jpeg: nil)
        guard session.isRunning, let layout = capture.quiz.layout,
              photoOutput.availablePhotoPixelFormatTypes.contains(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) else {
            onEvent?(.photo(failed))
            return
        }
        let settings = AVCapturePhotoSettings(format: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange])
        settings.maxPhotoDimensions = photoOutput.maxPhotoDimensions
        settings.photoQualityPrioritization = .balanced
        if #available(iOS 18.0, *), photoOutput.isShutterSoundSuppressionSupported { settings.isShutterSoundSuppressionEnabled = true }
        let id = settings.uniqueID
        let job = PhotoJob { [weak self] pixels in
            guard let self else { return }
            self.queue.async { self.photoJobs[id] = nil }
            self.photoQueue.async {
                self.onEvent?(.photo(self.read(pixels, capture, layout) ?? failed))
            }
        }
        photoJobs[id] = job
        photoOutput.capturePhoto(with: settings, delegate: job)
    }

    private func read(_ pixels: CVPixelBuffer?, _ capture: Capture, _ layout: SheetLayout) -> PhotoResult? {
        guard let pixels else { return nil }
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pixels, 0) else { return nil }
        let image = LumaImage(base: base.assumingMemoryBound(to: UInt8.self),
                              width: CVPixelBufferGetWidthOfPlane(pixels, 0), height: CVPixelBufferGetHeightOfPlane(pixels, 0),
                              bytesPerRow: CVPixelBufferGetBytesPerRowOfPlane(pixels, 0))
        let quiz = capture.quiz
        guard let corners = photoFinder.find(image), let unit = Homography(BoxFinder.unitCorners, corners),
              Reader.testCode(image, unit) == quiz.sheetCode, let map = Homography(layout.cornerPoints, corners) else { return nil }
        let read = Reader.read(quiz, layout, image, map, align: true)
        guard read.answers.count == capture.answers.count else { return nil }
        // The photo is sharper, so its reading wins. Rows it couldn't call are settled when no mark could be right.
        let review = Review.rows(read.answers, marks: read.marks, key: quiz.answerKey)
        // The photo is kept clean; the ✓ and ✗ are drawn over it when shown, so they always match the teacher's calls.
        return PhotoResult(id: capture.id, answers: review.answers, period: read.period,
                           name: Reader.nameStrip(layout, image, map, pixelsPerInch: 200),
                           jpeg: Reader.sheetJPEG(layout, [], image, map, pixelsPerInch: 150),
                           rows: review.rows)
    }
}

/// Camera preview with the found sheet outlined. While a sheet locks on, a sage stroke grows around it.
final class PreviewView: UIView {
    enum Look { case plain, locking(Double), done, warn }

    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

    private let outline = CAShapeLayer()
    private let progress = CAShapeLayer()
    private let flashLayer = CAShapeLayer()
    private var misses = 0
    private var shown: [CGPoint] = []   // outline corners on screen, smoothed
    private(set) var frozen = false

    private static let white = UIColor.white.withAlphaComponent(0.9).cgColor
    private static let sage = UIColor(red: 0x98 / 255, green: 0xA8 / 255, blue: 0x69 / 255, alpha: 1).cgColor
    private static let amber = UIColor(cgColor: MarkPaths.amber).cgColor

    /// Holds the picture still (single mode, while the result card is up).
    func freeze(_ on: Bool) {
        frozen = on
        previewLayer.connection?.isEnabled = !on
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        previewLayer.videoGravity = .resizeAspectFill
        for shape in [outline, progress] {
            shape.fillColor = UIColor.clear.cgColor
            shape.lineJoin = .round
            shape.lineCap = .round
            layer.addSublayer(shape)
        }
        outline.lineWidth = 3
        outline.strokeColor = Self.white
        progress.lineWidth = 6
        progress.strokeColor = Self.sage
        progress.strokeEnd = 0
        flashLayer.fillColor = UIColor.white.withAlphaComponent(0.6).cgColor
        flashLayer.opacity = 0
        layer.addSublayer(flashLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        for shape in [outline, progress, flashLayer] { shape.frame = bounds }
    }

    /// Outlines the sheet. `quad` is its corners in capture-device points (0–1), or nil when no sheet is in view.
    func show(_ quad: [CGPoint]?, _ look: Look) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        if frozen { return }
        guard let quad, quad.count == 4 else {
            misses += 1
            if misses > 12 {   // about 0.4 s without a sheet; short misses don't make the outline flash
                outline.path = nil
                progress.path = nil
                shown = []
            }
            return
        }
        misses = 0
        let target = quad.map { previewLayer.layerPointConverted(fromCaptureDevicePoint: $0) }
        let close = shown.count == 4 && zip(target, shown).allSatisfy { hypot($0.x - $1.x, $0.y - $1.y) < 40 }
        shown = close ? zip(target, shown).map { CGPoint(x: 0.5 * $0.x + 0.5 * $1.x, y: 0.5 * $0.y + 0.5 * $1.y) } : target
        let path = quadPath()
        outline.path = path
        progress.path = path
        switch look {
        case .plain:
            outline.strokeColor = Self.white
            progress.strokeEnd = 0
        case .locking(let p):
            outline.strokeColor = Self.white
            progress.strokeEnd = p
        case .done:
            outline.strokeColor = Self.sage
            progress.strokeEnd = 0
        case .warn:
            outline.strokeColor = Self.amber
            progress.strokeEnd = 0
        }
    }

    /// A quick white flash over the sheet when it's captured.
    func flash() {
        guard shown.count == 4 else { return }
        flashLayer.path = quadPath()
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.duration = 0.35
        flashLayer.add(fade, forKey: "flash")
    }

    private func quadPath() -> CGPath {
        let path = UIBezierPath()
        for (k, p) in shown.enumerated() {
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
