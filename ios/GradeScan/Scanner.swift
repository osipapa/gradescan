import AVFoundation
import UIKit
import Vision

enum ScanEvent {
    case nothing
    case cameraDenied
    case unknownQuiz(String)
    case sheet(Quiz, student: String?, answers: String, map: Homography)
}

/// Runs the camera, finds the four corner QR codes, and reads the bubbles on every frame.
final class Scanner: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    var onEvent: ((ScanEvent) -> Void)?

    private let queue = DispatchQueue(label: "gradescan.scanner")
    private var quizzes: [String: Quiz] = [:]   // only touched on `queue`
    private var configured = false

    func setQuizzes(_ list: [String: Quiz]) {
        queue.async { self.quizzes = list }
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

    private func configure() {
        configured = true
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device) else { return }
        session.beginConfiguration()
        if session.canAddInput(input) { session.addInput(input) }
        if session.canSetSessionPreset(.hd1920x1080) { session.sessionPreset = .hd1920x1080 }
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(output) { session.addOutput(output) }
        session.commitConfiguration()
        if (try? device.lockForConfiguration()) != nil {
            if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
            if device.isAutoFocusRangeRestrictionSupported { device.autoFocusRangeRestriction = .near }
            device.unlockForConfiguration()
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        try? VNImageRequestHandler(cvPixelBuffer: pixels, orientation: .up).perform([request])

        // Corner QR codes read "GS|<quiz code>|TL" (TR, BL, BR). Vision is bottom-left origin; flip to top-left.
        var corners: [String: CGPoint] = [:]
        var codes = Set<String>()
        for barcode in request.results ?? [] {
            let parts = (barcode.payloadStringValue ?? "").split(separator: "|").map(String.init)
            guard parts.count == 3, parts[0] == "GS", SheetLayout.anchors[parts[2]] != nil else { continue }
            let pts = [barcode.topLeft, barcode.topRight, barcode.bottomLeft, barcode.bottomRight]
            corners[parts[2]] = CGPoint(x: pts.map(\.x).reduce(0, +) / 4, y: 1 - pts.map(\.y).reduce(0, +) / 4)
            codes.insert(parts[1])
        }
        guard corners.count == 4, codes.count == 1, let code = codes.first else { onEvent?(.nothing); return }
        guard let quiz = quizzes[code] else { onEvent?(.unknownQuiz(code)); return }
        let order = ["TL", "TR", "BL", "BR"]
        guard let map = Homography(order.compactMap { SheetLayout.anchors[$0] }, order.compactMap { corners[$0] }) else {
            onEvent?(.nothing)
            return
        }

        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pixels, 0) else { return }
        let image = LumaImage(base: base.assumingMemoryBound(to: UInt8.self),
                              width: CVPixelBufferGetWidthOfPlane(pixels, 0),
                              height: CVPixelBufferGetHeightOfPlane(pixels, 0),
                              bytesPerRow: CVPixelBufferGetBytesPerRowOfPlane(pixels, 0))
        let read = Reader.read(quiz, image, map)
        onEvent?(.sheet(quiz, student: read.student, answers: read.answers, map: map))
    }
}

/// Camera preview with red X marks on wrong answers and green rings on the right ones.
final class PreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

    private let red = CAShapeLayer()
    private let green = CAShapeLayer()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        previewLayer.videoGravity = .resizeAspectFill
        for (shape, color) in [(red, UIColor.systemRed), (green, UIColor.systemGreen)] {
            shape.strokeColor = color.cgColor
            shape.fillColor = UIColor.clear.cgColor
            shape.lineWidth = 4
            shape.lineCap = .round
            layer.addSublayer(shape)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        red.frame = bounds
        green.frame = bounds
    }

    func draw(_ marks: [Mark], _ map: Homography?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard let map, !marks.isEmpty else {
            red.path = nil
            green.path = nil
            return
        }
        let point: (CGFloat, CGFloat) -> CGPoint = { x, y in
            self.previewLayer.layerPointConverted(fromCaptureDevicePoint: map.apply(CGPoint(x: x, y: y)))
        }
        let x = UIBezierPath(), ring = UIBezierPath()
        for mark in marks {
            let c = mark.center
            if mark.wrong {
                x.move(to: point(c.x - 0.13, c.y - 0.13)); x.addLine(to: point(c.x + 0.13, c.y + 0.13))
                x.move(to: point(c.x - 0.13, c.y + 0.13)); x.addLine(to: point(c.x + 0.13, c.y - 0.13))
            } else {
                for k in 0...16 {
                    let a = CGFloat(k) / 16 * 2 * .pi
                    let p = point(c.x + 0.15 * cos(a), c.y + 0.15 * sin(a))
                    if k == 0 { ring.move(to: p) } else { ring.addLine(to: p) }
                }
            }
        }
        red.path = x.cgPath
        green.path = ring.cgPath
    }
}
