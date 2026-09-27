import SwiftUI

/// The camera: Single or Batch, a status pill, and in batch mode a tray of what's been captured.
struct ScanScreen: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var scan: ScanSession
    @State private var confirmDiscardBatch = false

    var body: some View {
        ZStack {
            CameraView(preview: scan.preview).ignoresSafeArea()
            VStack(spacing: 10) {
                topBar
                if let id = scan.rescanning { rescanBanner(id) }
                if scan.capturingKey { keyBanner }
                if let note = scan.note {
                    Text(note).font(.subheadline.weight(.medium)).foregroundStyle(.white)
                        .padding(.horizontal, 16).padding(.vertical, 10).glassCapsule()
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                Spacer()
                if scan.zipgradeInView, let id = scan.zipgradeQuizId, let quiz = scan.quiz(id) {
                    Button { scan.askZipGrade = true } label: {
                        Text("ZipGrade · \(quiz.title)").font(.footnote.weight(.medium)).lineLimit(1)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                    }
                    .foregroundStyle(.white)
                    .glassCapsule()
                }
                if scan.zipgradeNeedsTest && scan.rescanning == nil { zipgradePrompt } else { pill }
                if store.problem != nil && !store.pending.isEmpty {
                    Text("\(store.pending.count) waiting to upload. It keeps trying.").font(.footnote).foregroundStyle(.white.opacity(0.85))
                        .padding(.horizontal, 14).padding(.vertical, 8).glassCapsule()
                } else if !store.pending.isEmpty {
                    Text("Uploading \(store.pending.count)…").font(.footnote).foregroundStyle(.white.opacity(0.85))
                }
                if scan.rescanning == nil && !scan.capturingKey {
                    if scan.mode == .batch { tray } else if !scan.items.isEmpty { reviewBatchButton }
                    modePicker
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .animation(.snappy, value: scan.note)
        }
        .sheet(item: $scan.card, onDismiss: scan.cardDismissed) { ref in
            ItemCardSheet(id: ref.id).environmentObject(store).environmentObject(scan)
        }
        .confirmationDialog("Discard this batch?", isPresented: $confirmDiscardBatch, titleVisibility: .visible) {
            Button("Discard \(scan.items.count) scans", role: .destructive) { scan.discardBatch() }
        } message: {
            Text("They're deleted here and in the portal.")
        }
        .sheet(isPresented: $scan.askZipGrade) {
            ZipGradeTestPicker().environmentObject(store).environmentObject(scan)
        }
        .sheet(item: $scan.keyDraft, onDismiss: { if scan.capturingKey { scan.keyTestDone(nil) } }) { draft in
            NewTestView(draft: draft) { quiz in scan.keyTestDone(quiz) }.environmentObject(store)
        }
        .fullScreenCover(isPresented: $scan.showReview, onDismiss: scan.reviewClosed) {
            ReviewScreen().environmentObject(store).environmentObject(scan)
        }
        .task { await store.reload() }
        .task { await scan.followResourceUsagePreference() }
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            scan.appear()
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            scan.disappear()
        }
        .toolbarColorScheme(.dark, for: .tabBar)   // the tab bar sits on the camera, so keep its icons light
    }

    private var topBar: some View {
        HStack {
            Button { scan.toggleTorch() } label: {
                Image(systemName: scan.torch ? "flashlight.on.fill" : "flashlight.off.fill").font(.title3).frame(width: 46, height: 46)
            }
            .glassCapsule()
            .accessibilityLabel(scan.torch ? "Turn flashlight off" : "Turn flashlight on")
            Spacer()
        }
        .foregroundStyle(.white)
    }

    /// A ZipGrade sheet is in view and this batch has no test for it yet.
    private var zipgradePrompt: some View {
        let hasTests = store.tests.contains(where: ZipGrade.fits)
        return VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("ZipGrade sheet").font(.headline)
                Text(hasTests ? "Which test is it for?" : "Set up its test from an answer key: a sheet with every answer right.")
                    .font(.subheadline).foregroundStyle(.white.opacity(0.85))
            }
            HStack(spacing: 10) {
                if hasTests {
                    Button { scan.askZipGrade = true } label: { Text("Choose test").bold().frame(maxWidth: .infinity) }
                        .primaryButton()
                }
                Button { scan.startKeyCapture() } label: { Text("Scan answer key").frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered)
                    .tint(.white)
            }
            .controlSize(.large)
        }
        .foregroundStyle(.white)
        .padding(16)
        .glassPanel()
    }

    private var keyBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "key").font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text("Answer key").font(.headline)
                Text("Hold up a sheet with every answer right").font(.caption).lineLimit(1)
            }
            Spacer()
            Button("Cancel") { scan.cancelKeyCapture() }.bold()
        }
        .foregroundStyle(.white)
        .padding(14)
        .glassPanel()
    }

    private func rescanBanner(_ id: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "camera.viewfinder").font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text("Rescan").font(.headline)
                if let item = scan.item(id) {
                    Text([scan.position(id).map { "Sheet \($0)" }, item.studentName.map(ScanSession.short), scan.quiz(item.quizId)?.title]
                        .compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).lineLimit(1)
                }
            }
            Spacer()
            Button("Cancel") { scan.cancelRescan() }.bold()
        }
        .foregroundStyle(.white)
        .padding(14)
        .glassPanel()
    }

    private var pill: some View {
        HStack(spacing: 10) {
            Text(scan.pill.text).font(.headline).lineLimit(1).minimumScaleFactor(0.7)
            if scan.unknownTest {
                Button("Reload") { Task { await store.reload() } }.font(.subheadline.bold())
            }
            if scan.cameraDenied, let url = URL(string: UIApplication.openSettingsURLString) {
                Button("Open Settings") { UIApplication.shared.open(url) }.font(.subheadline.bold())
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
        .glassCapsule(scan.pill.tone == .good ? Brand.moss : scan.pill.tone == .warn ? .orange : nil)
        .animation(.snappy, value: scan.pill)
    }

    private var tray: some View {
        HStack(spacing: 8) {
            if scan.items.isEmpty {
                Text("Scan your sheets")
                    .font(.footnote).foregroundStyle(.white.opacity(0.9))
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 8)
            } else {
                Button { confirmDiscardBatch = true } label: {
                    Image(systemName: "xmark").font(.subheadline.weight(.semibold)).frame(width: 30, height: 44)
                }
                .foregroundStyle(.white.opacity(0.85))
                .accessibilityLabel("Discard batch")
                ForEach(scan.items.suffix(4)) { item in
                    Button { scan.openReview(at: item.id) } label: { Thumb(item: item) }
                }
                Text("\(scan.items.count)").font(.headline.monospacedDigit()).foregroundStyle(.white).padding(.leading, 2)
                Spacer()
                Button { scan.openReview() } label: {
                    Text("Review").font(.headline).padding(.horizontal, 22).padding(.vertical, 11)
                }
                .background(Brand.sage, in: Capsule())
                .foregroundStyle(Brand.onSage)
            }
        }
        .padding(10)
        .glassPanel()
    }

    private var reviewBatchButton: some View {
        Button { scan.openReview() } label: {
            Label("Review batch (\(scan.unreviewed))", systemImage: "square.stack.3d.up").font(.subheadline.weight(.semibold))
                .padding(.horizontal, 16).padding(.vertical, 10)
        }
        .foregroundStyle(.white)
        .glassCapsule()
    }

    private var modePicker: some View {
        Picker("Mode", selection: $scan.mode) {
            Text("Single").tag(ScanSession.Mode.single)
            Text("Batch").tag(ScanSession.Mode.batch)
        }
        .pickerStyle(.segmented)
        .frame(width: 220)
        .padding(6)
        .glassCapsule()
    }
}

/// A captured sheet in the tray: its marked photo, with an amber dot when something needs a look.
struct Thumb: View {
    let item: ScanItem

    var body: some View {
        ZStack {
            if let name = item.photo, let image = Thumbs.image(name) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Color.white.opacity(0.85)
                if item.processing { ProgressView().controlSize(.small) }
            }
        }
        .frame(width: 34, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(alignment: .topTrailing) {
            if !item.processing && item.needsLook {
                Circle().fill(.orange).frame(width: 10, height: 10).offset(x: 3, y: -3)
            }
        }
    }
}

/// Small, cached versions of the marked photos for the tray.
enum Thumbs {
    private static let cache = NSCache<NSString, UIImage>()

    static func image(_ name: String) -> UIImage? {
        if let hit = cache.object(forKey: name as NSString) { return hit }
        guard let full = UIImage(contentsOfFile: Photos.url(name).path), full.size.width > 0 else { return nil }
        let size = CGSize(width: 90, height: 90 * full.size.height / full.size.width)
        let thumb = full.preparingThumbnail(of: size) ?? full
        cache.setObject(thumb, forKey: name as NSString)
        return thumb
    }
}

/// ZipGrade sheets carry no test code, so the teacher says which test a ZipGrade stack is for.
struct ZipGradeTestPicker: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var scan: ScanSession
    @Environment(\.dismiss) private var dismiss
    @State private var creating = false
    @State private var before: Set<String> = []

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("ZipGrade sheets don't say which test they're for. Pick the one with the right answer key; this batch's ZipGrade sheets go to it.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Section("Your tests") {
                    let fitting = store.tests.filter(ZipGrade.fits)
                    if fitting.isEmpty { Text("No tests with 20 questions or fewer yet.").foregroundStyle(.secondary) }
                    ForEach(fitting) { test in
                        Button {
                            scan.zipgradeQuizId = test.id
                            dismiss()
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(test.title).foregroundStyle(.primary)
                                    Text(test.summary).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if test.id == scan.zipgradeQuizId { Image(systemName: "checkmark").foregroundStyle(Brand.sageStrong) }
                            }
                        }
                    }
                }
                Section {
                    Button("New test from an answer key sheet") { scan.startKeyCapture() }
                    Button("Set up a new test by hand") {
                        before = Set(store.tests.map(\.id))
                        creating = true
                    }
                } footer: {
                    Text("From an answer key: hold up a sheet with every answer right, then name the test.")
                }
            }
            .navigationTitle("ZipGrade sheets")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .sheet(isPresented: $creating, onDismiss: {
                // A test just created here is the one for this stack.
                if let new = store.tests.first(where: { !before.contains($0.id) }), ZipGrade.fits(new) {
                    scan.zipgradeQuizId = new.id
                    dismiss()
                }
            }) {
                NewTestView().environmentObject(store)
            }
        }
    }
}
