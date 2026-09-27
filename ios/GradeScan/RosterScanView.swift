import AVFoundation
import Combine
import CoreImage
import PhotosUI
import SwiftUI

/// Importing a class list: point the camera at a class page in Jupiter and the names are read and added on their
/// own, to the period open on the page. Open another class and it's added too. A screenshot works the same way.
struct RosterScanView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var live = RosterLive()
    @State private var picked: PhotosPickerItem?

    var body: some View {
        ZStack {
            RosterPreview(session: live.camera.session).ignoresSafeArea()
            VStack(spacing: 12) {
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").font(.title3).frame(width: 46, height: 46)
                    }
                    .glassCapsule()
                    .accessibilityLabel("Close")
                    Spacer()
                    PhotosPicker(selection: $picked, matching: .images) {
                        Image(systemName: "photo").font(.title3).frame(width: 46, height: 46)
                    }
                    .glassCapsule()
                    .accessibilityLabel("Use a screenshot")
                }
                .foregroundStyle(.white)
                Spacer()
                panel
                    .foregroundStyle(.white)
                    .animation(.snappy, value: live.phase)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            UIDevice.current.beginGeneratingDeviceOrientationNotifications()
            live.start(store)
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            UIDevice.current.endGeneratingDeviceOrientationNotifications()
            live.stop()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            live.camera.follow(UIDevice.current.orientation)
        }
        .onChange(of: picked) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) { live.read(image) }
                picked = nil
            }
        }
    }

    @ViewBuilder private var panel: some View {
        switch live.phase {
        case .looking:
            Text("Point at a class page in Jupiter")
                .font(.headline)
                .padding(.horizontal, 18).padding(.vertical, 11)
                .glassCapsule()
        case .reading:
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    ProgressView().tint(.white)
                    Text(live.names.isEmpty ? "Reading…" : heading).font(.headline)
                }
                names
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassPanel()
        case .askPeriod:
            VStack(alignment: .leading, spacing: 12) {
                Text("Which period is this?").font(.headline)
                Text("\(live.names.count) \(live.names.count == 1 ? "name" : "names"). The page doesn't show which class is open.")
                    .font(.subheadline).foregroundStyle(.white.opacity(0.8))
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 5), spacing: 8) {
                    ForEach(1...9, id: \.self) { p in
                        Button("\(p)") { live.choose(p) }
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .background(.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }
                Button("Not now") { live.notNow() }.font(.subheadline.weight(.medium))
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassPanel()
        case .saving:
            HStack(spacing: 10) {
                ProgressView().tint(.white)
                Text("Adding…").font(.headline)
            }
            .padding(.horizontal, 18).padding(.vertical, 11)
            .glassCapsule()
        case .added(let period, let count, let skipped):
            VStack(alignment: .leading, spacing: 8) {
                Label(count == 0 ? "Period \(period): everyone's already on your list" : "Added \(count) to Period \(period)",
                      systemImage: "checkmark.circle.fill")
                    .font(.headline)
                if count > 0 && skipped > 0 {
                    Text("\(skipped) were already on your list.").font(.subheadline).foregroundStyle(.white.opacity(0.8))
                }
                Text("Open another class to add it too.").font(.subheadline).foregroundStyle(.white.opacity(0.8))
                HStack {
                    if count > 0 { Button("Undo") { live.undo() }.font(.subheadline.weight(.semibold)) }
                    Spacer()
                    Button("Done") { dismiss() }.font(.subheadline.weight(.semibold))
                }
                .padding(.top, 4)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassPanel()
        case .failed:
            VStack(alignment: .leading, spacing: 10) {
                Text("Couldn't add them. Check the connection.").font(.headline)
                Button("Try again") { live.retry() }.font(.subheadline.weight(.semibold))
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassPanel()
        }
    }

    private var heading: String {
        (live.period.map { "Period \($0) · " } ?? "") + "\(live.names.count) \(live.names.count == 1 ? "name" : "names")"
    }

    private var names: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(live.names, id: \.self) { Text($0).font(.subheadline) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 150)
        .scrollIndicators(.hidden)
    }
}

/// What the live import has read and what it's doing about it.
@MainActor
final class RosterLive: ObservableObject {
    enum Phase: Equatable {
        case looking                                    // no class page in view
        case reading                                    // names coming in; waiting for them to settle
        case askPeriod                                  // settled, but the page doesn't show the period
        case saving
        case added(period: Int, count: Int, skipped: Int)
        case failed
    }

    @Published private(set) var phase: Phase = .looking
    @Published private(set) var names: [String] = []
    @Published private(set) var period: Int?
    let camera = RosterCamera()

    private var consensus = RosterConsensus()
    private weak var store: AppStore?
    private var chosen: Int?                    // the period the teacher picked for the page in view
    private var done: [Int: Set<String>] = [:]  // names added this session, by period
    private var declined: Set<String> = []      // names on pages the teacher said "Not now" to
    private var last: (period: Int, students: [Student], names: [String])?
    private lazy var haptics = UINotificationFeedbackGenerator()

    func start(_ store: AppStore) {
        self.store = store
        camera.onRead = { [weak self] page in Task { @MainActor [weak self] in self?.take(page, still: false) } }
        camera.start()
    }

    func stop() { camera.stop() }

    /// A photo or screenshot of a class page.
    func read(_ image: UIImage) {
        guard let cg = Self.upright(image) else { return }
        phase = .reading
        Task { take(await RosterReader.read(cg), still: true) }
    }

    func choose(_ period: Int) {
        chosen = period
        add(to: period)
    }

    func notNow() {
        declined.formUnion(names)
        phase = .looking
    }

    /// Takes back the last students added. The period may have been wrong, so it asks which one it is.
    func undo() {
        guard let last, let store else { return }
        phase = .saving
        Task {
            if await store.removeStudents(last.students) {
                done[last.period]?.subtract(last.names)
                self.last = nil
                phase = .askPeriod
            } else {
                phase = .added(period: last.period, count: last.students.count, skipped: last.names.count - last.students.count)
            }
        }
    }

    func retry() {
        guard let period = consensus.period ?? chosen else { phase = .askPeriod; return }
        add(to: period)
    }

    private func take(_ page: RosterReader.Page, still: Bool) {
        if phase == .saving || phase == .askPeriod { return }
        consensus.add(page, still: still)
        names = consensus.names
        period = consensus.period
        if names.isEmpty { chosen = nil }
        let effective = consensus.period ?? chosen
        let waiting = effective.map(pending) ?? names.filter { !declined.contains($0) }
        if waiting.isEmpty {
            // Nothing new on the page: keep showing what was just added; otherwise it's looking or still reading.
            if case .added = phase { return }
            phase = names.isEmpty || effective != nil ? .looking : .reading
            return
        }
        if case .failed = phase, !consensus.steady { return }
        // A real class page lists several students; a stray "Last, First" elsewhere on the screen isn't one.
        guard consensus.steady, still || names.count >= 3 else {
            phase = .reading
            return
        }
        if let effective { add(to: effective) } else { phase = .askPeriod }
    }

    /// Names on the page not added yet. A spelling a letter off one just added is the same student read better.
    private func pending(_ period: Int) -> [String] {
        let added = (done[period] ?? []).map(NameMatch.tokens)
        return names.filter { name in
            let words = NameMatch.tokens(name)
            return !declined.contains(name) && !added.contains { NameMatch.distance(words, $0) <= 0.2 }
        }
    }

    private func add(to period: Int) {
        guard let store else { return }
        let list = pending(period)
        guard !list.isEmpty else { phase = .added(period: period, count: 0, skipped: 0); return }
        phase = .saving
        Task {
            guard let added = await store.importStudents(list.map { (name: $0, period: Optional(period)) }) else {
                phase = .failed
                return
            }
            done[period, default: []].formUnion(list)
            last = (period, added, list)
            phase = .added(period: period, count: added.count, skipped: list.count - added.count)
            haptics.notificationOccurred(.success)
        }
    }

    /// The photo turned the way it was taken, so where things are on the page matches what's read.
    private static func upright(_ image: UIImage) -> CGImage? {
        if image.imageOrientation == .up, let cg = image.cgImage { return cg }
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: image.size, format: format).image { _ in image.draw(at: .zero) }.cgImage
    }
}

/// The back camera, reading the newest frame whenever the last reading is done (a few times a second).
final class RosterCamera: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    var onRead: ((RosterReader.Page) -> Void)?

    private let queue = DispatchQueue(label: "gradescan.roster.camera")
    private let output = AVCaptureVideoDataOutput()
    private let context = CIContext()
    private var configured = false
    private var busy = false
    private var orientation = CGImagePropertyOrientation.right   // how the frames sit when the phone is upright

    func start() {
        queue.async { [self] in
            if !configured { configure() }
            if !session.isRunning { session.startRunning() }
        }
    }

    func stop() {
        queue.async { [self] in if session.isRunning { session.stopRunning() } }
    }

    /// The phone turned: turn the frames with it, so the page's text reads upright.
    func follow(_ device: UIDeviceOrientation) {
        let o: CGImagePropertyOrientation
        switch device {
        case .portrait: o = .right
        case .portraitUpsideDown: o = .left
        case .landscapeLeft: o = .up
        case .landscapeRight: o = .down
        default: return
        }
        queue.async { self.orientation = o }
    }

    private func configure() {
        configured = true
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .hd1920x1080
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else { return }
        session.addInput(input)
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)
        if (try? device.lockForConfiguration()) != nil {
            if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
            device.unlockForConfiguration()
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard !busy, let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let image = CIImage(cvPixelBuffer: pixels).oriented(orientation)
        guard let frame = context.createCGImage(image, from: image.extent) else { return }
        busy = true
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let page = RosterReader.readNow(frame, live: true)
            queue.async { self.busy = false }
            onRead?(page)
        }
    }
}

/// The live camera picture.
struct RosterPreview: UIViewRepresentable {
    let session: AVCaptureSession

    final class PreviewLayerView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var preview: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> PreviewLayerView {
        let view = PreviewLayerView()
        view.preview.session = session
        view.preview.videoGravity = .resizeAspectFill
        view.backgroundColor = .black
        return view
    }

    func updateUIView(_ uiView: PreviewLayerView, context: Context) {}
}
