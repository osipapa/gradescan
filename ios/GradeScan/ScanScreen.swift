import SwiftUI

/// The camera: Single or Batch, a status pill, and in batch mode a tray of what's been captured.
struct ScanScreen: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var scan: ScanSession

    var body: some View {
        ZStack {
            CameraView(preview: scan.preview).ignoresSafeArea()
            VStack(spacing: 10) {
                topBar
                if let id = scan.rescanning { rescanBanner(id) }
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
                pill
                if let problem = store.problem {
                    Button { Task { await store.send() } } label: {
                        Label("\(problem) Retry", systemImage: "exclamationmark.triangle.fill").font(.footnote).lineLimit(2)
                    }
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 16).padding(.vertical, 10).glassCapsule()
                } else if !store.pending.isEmpty {
                    Text("Uploading \(store.pending.count)…").font(.footnote).foregroundStyle(.white.opacity(0.85))
                }
                if scan.rescanning == nil {
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
        .sheet(isPresented: $scan.askZipGrade, onDismiss: { if scan.askZipGrade == false && scan.zipgradeQuizId == nil { scan.zipgradeAskDismissed() } }) {
            ZipGradeTestPicker().environmentObject(store).environmentObject(scan)
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
            Menu {
                Button("Reload tests", systemImage: "arrow.clockwise") { Task { await store.reload() } }
                Button("Retry uploads", systemImage: "arrow.up.circle") { Task { await store.send() } }
                Button("Sign out", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) { store.signOut() }
            } label: {
                Image(systemName: "ellipsis").font(.title3).frame(width: 46, height: 46)
            }
            .glassCapsule()
            .accessibilityLabel("More")
        }
        .foregroundStyle(.white)
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
                Text("Scan the sheets one after another, then tap Done.")
                    .font(.footnote).foregroundStyle(.white.opacity(0.9))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            } else {
                ForEach(scan.items.suffix(4)) { item in
                    Button { scan.openCard(item.id) } label: { Thumb(item: item) }
                }
                Text("\(scan.items.count)").font(.headline.monospacedDigit()).foregroundStyle(.white).padding(.leading, 2)
                Spacer()
                Button { scan.openReview() } label: {
                    Text("Done").font(.headline).padding(.horizontal, 22).padding(.vertical, 11)
                }
                .background(Brand.sage, in: Capsule())
                .foregroundStyle(Brand.ink)
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
                    Text("ZipGrade sheets don't say which test they're for. Pick the one with the right answer key; ZipGrade sheets go to it until you change it.")
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
                    Button("New test") {
                        before = Set(store.tests.map(\.id))
                        creating = true
                    }
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
