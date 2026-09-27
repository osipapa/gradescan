import AVFoundation
import Combine
import SwiftUI
import UIKit

/// The camera and what it captured: the batch and its review, or the single-mode card.
@MainActor
final class ScanSession: ObservableObject {
    enum Mode: String, CaseIterable { case single, batch }

    struct Pill: Equatable {
        enum Tone { case plain, good, warn }
        var text: String
        var tone: Tone = .plain
    }

    struct CardRef: Identifiable, Equatable { let id: String }

    @Published var mode: Mode {
        didSet {
            guard mode != oldValue else { return }
            UserDefaults.standard.set(mode.rawValue, forKey: "scanMode")
            card = nil
            if let single { finishSingle(single) }
            scanner.configure(single: mode == .single, expect: nil)
            scanner.resume(rescan: false)
        }
    }
    @Published private(set) var items: [ScanItem] = [] { didSet { photosChanged() } }   // the batch, in scan order
    @Published private(set) var single: ScanItem? { didSet { photosChanged() } }        // single mode's card
    @Published var card: CardRef?           // a card open over the camera
    @Published var showReview = false
    @Published var reviewId: String?   // the sheet showing in review
    @Published private(set) var rescanning: String?
    @Published private(set) var pill = Pill(text: "Point at a sheet")
    @Published private(set) var unknownTest = false
    @Published private(set) var cameraDenied = false
    @Published private(set) var note: String?
    @Published private(set) var torch = false
    /// The test ZipGrade sheets are for (they carry no test code). Remembered until the teacher changes it.
    @Published var zipgradeQuizId: String? {
        didSet {
            UserDefaults.standard.set(zipgradeQuizId, forKey: "zipgradeQuiz")
            scanner.setZipGrade(zipgradeQuizId.flatMap(quiz))
        }
    }
    @Published var askZipGrade = false            // a ZipGrade sheet is in view and no test is chosen yet
    @Published private(set) var zipgradeInView = false
    private var zipgradeQuietUntil = Date.distantPast

    let scanner = Scanner()
    let preview = PreviewView()
    private let store: AppStore
    private var fallbackNames: [String: GrayStrip] = [:]   // video-frame names, in case the photo fails
    private var fallbackPeriods: [String: GrayStrip] = [:] // ZipGrade: video-frame period boxes, in case the photo fails
    private var periodStrips: [String: GrayStrip] = [:]    // ZipGrade: period boxes waiting to be read
    private var fallbackDates: [String: GrayStrip] = [:]   // ZipGrade: video-frame date boxes, in case the photo fails
    private var dateStrips: [String: GrayStrip] = [:]      // ZipGrade: date boxes waiting to be read
    private var captureShown: (pill: Pill, at: Date, id: String)?
    private var capturedTogether = 0
    private var rescanFromReview = false
    private var heldForCard = false
    private var watch: AnyCancellable?
    private var conflictWatch: AnyCancellable?
    private lazy var haptics: UINotificationFeedbackGenerator = {
        if #available(iOS 17.5, *) { return UINotificationFeedbackGenerator(view: preview) }
        return UINotificationFeedbackGenerator()
    }()

    init(store: AppStore) {
        self.store = store
        mode = Mode(rawValue: UserDefaults.standard.string(forKey: "scanMode") ?? "") ?? .batch
        zipgradeQuizId = UserDefaults.standard.string(forKey: "zipgradeQuiz")
        preview.previewLayer.session = scanner.session
        scanner.configure(single: mode == .single, expect: nil)
        scanner.onEvent = { [weak self] event in
            Task { @MainActor [weak self] in self?.handle(event) }
        }
        watch = store.$tests.sink { [weak self] tests in
            guard let self else { return }
            self.scanner.setTests(tests)
            self.scanner.setZipGrade(self.zipgradeQuizId.flatMap { id in tests.first { $0.id == id } })
        }
        // A scan saved without its student because the student already had one: the teacher compares the two.
        conflictWatch = store.$conflicts.sink { [weak self] conflicts in
            guard let self else { return }
            for (id, other) in conflicts {
                guard var item = self.item(id), item.duplicateOf == nil else { continue }
                item.duplicateOf = other
                item.suggestedId = item.studentId ?? item.suggestedId
                item.studentId = nil
                self.update(item)
            }
        }
        loadBatch()
    }

    // MARK: Camera

    func appear() {
        guard !showReview else { return }
        scanner.start()
    }

    func disappear() {
        scanner.stop()
    }

    func toggleTorch() {
        torch.toggle()
        scanner.setTorch(torch)
    }

    /// iOS 27: scan at a lower frame rate while the system asks apps to reduce resource usage.
    func followResourceUsagePreference() async {
        guard #available(iOS 27.0, *) else { return }
        scanner.setReducedResourceUsage(UIApplication.shared.systemPrefersReducedResourceUsage)
        for await _ in NotificationCenter.default.notifications(named: UIApplication.systemPrefersReducedResourceUsageDidChangeNotification) {
            scanner.setReducedResourceUsage(UIApplication.shared.systemPrefersReducedResourceUsage)
        }
    }

    // MARK: Looking up items

    func item(_ id: String) -> ScanItem? { items.first { $0.id == id } ?? (single?.id == id ? single : nil) }
    func quiz(_ id: String) -> Quiz? { store.tests.first { $0.id == id } }

    /// The teacher closed the ZipGrade test picker without choosing: don't ask again for a few seconds.
    func zipgradeAskDismissed() {
        askZipGrade = false
        zipgradeQuietUntil = Date().addingTimeInterval(8)
    }
    func student(_ id: String?) -> Student? { id.flatMap { id in store.students.first { $0.id == id } } }
    func isBatch(_ id: String) -> Bool { items.contains { $0.id == id } }
    func position(_ id: String) -> Int? { items.firstIndex { $0.id == id }.map { $0 + 1 } }

    private func update(_ item: ScanItem) {
        if let i = items.firstIndex(where: { $0.id == item.id }) { items[i] = item } else if single?.id == item.id { single = item }
        if isBatch(item.id) { saveBatch() }
    }

    /// The period on the sheet isn't the one the student has on the class list.
    private func mismatch(_ item: ScanItem) -> Bool {
        guard let p = item.period, let listed = student(item.studentId)?.period else { return false }
        return p != listed
    }

    /// Notes that belong on an item's card.
    func notes(_ item: ScanItem) -> [String] {
        var out: [String] = []
        if item.periodMismatch, let p = item.period, let s = student(item.studentId), let listed = s.period {
            out.append("Period \(p) on the sheet, but \(s.name) is in period \(listed) on your class list.")
        }
        if item.photoFailed { out.append("No clear photo. Check this sheet on paper.") }
        if item.duplicateOf == nil, isBatch(item.id), let j = BatchRules.lookalike(item, in: items), let n = position(items[j].id) {
            out.append("Looks like the same sheet as #\(n).")
        }
        return out
    }

    // MARK: Events

    private func handle(_ event: ScanEvent) {
        switch event {
        case .cameraDenied:
            cameraDenied = true
            setPill(Pill(text: "Camera access is off", tone: .warn))
        case .frame(let f):
            let zipgrade = f.sheets.contains { $0.zipgrade }
            if zipgradeInView != zipgrade { zipgradeInView = zipgrade }
            if f.sheets.contains(where: \.needsTest), !askZipGrade, Date() > zipgradeQuietUntil { askZipGrade = true }
            preview.show(f.sheets.compactMap { sheet in
                guard let map = sheet.map else { return nil }
                let look: PreviewView.Look
                switch sheet.gate {
                case .locking(let p): look = sheet.unknownTest || sheet.wrongTest ? .warn : .locking(p)
                case .waiting, .fire: look = .done
                case .blank: look = .warn
                case .idle: look = sheet.unknownTest || sheet.wrongTest || sheet.needsTest ? .warn : .plain
                }
                return (sheet.track, (sheet.layout?.cornerPoints ?? BoxFinder.unitCorners).map { map.apply($0) }, look)
            })
            let unknown = f.sheets.contains(where: \.unknownTest)
            if unknownTest != unknown {
                unknownTest = unknown
                if unknown { haptics.notificationOccurred(.warning) }
            }
            updatePill(f)
        case .captured(let c):
            captured(c)
        case .photo(let p):
            photoArrived(p)
        }
    }

    private func updatePill(_ f: FrameInfo) {
        if let shown = captureShown, Date().timeIntervalSince(shown.at) < 1.6 { return setPill(shown.pill) }
        if f.sheets.contains(where: \.unknownTest) { return setPill(Pill(text: "Not one of your tests", tone: .warn)) }
        if f.sheets.contains(where: \.needsTest) { return setPill(Pill(text: "ZipGrade sheet: which test?", tone: .warn)) }
        if let q = f.sheets.first(where: \.wrongTest)?.quiz { return setPill(Pill(text: "This sheet is for \(q.title)", tone: .warn)) }
        let gates = f.sheets.map(\.gate)
        let several = f.sheets.count > 1 ? "\(f.sheets.count) sheets · " : ""
        if gates.isEmpty {
            return setPill(store.loaded && store.tests.isEmpty ? Pill(text: "No tests yet. Create one first.", tone: .warn)
                                                               : Pill(text: rescanning == nil ? "Point at the sheets" : "Point at the sheet to rescan"))
        }
        if gates.contains(where: { if case .locking = $0 { return true } else { return false } }) { return setPill(Pill(text: several + "Hold steady")) }
        if gates.contains(.blank) { return setPill(Pill(text: several + "Nothing filled in", tone: .warn)) }
        if gates.allSatisfy({ $0 == .waiting || { if case .fire = $0 { return true } else { return false } }($0) }) {
            return setPill(Pill(text: mode == .batch ? (f.sheets.count > 1 ? "All captured · next ones" : "Next sheet") : "Captured", tone: .good))
        }
        setPill(Pill(text: several + "Hold steady"))
    }

    private func setPill(_ p: Pill) { if pill != p { pill = p } }

    private func captured(_ c: Capture) {
        var item = ScanItem(id: c.id, quizId: c.quiz.id, answers: c.answers, period: c.period, scannedAt: c.scannedAt)
        if c.kind == .zipgrade20 {
            item.form = SheetKind.zipgrade20.rawValue
            if let box = c.periodBox { fallbackPeriods[c.id] = box }
            if let box = c.dateBox { fallbackDates[c.id] = box }
        }
        if let number = c.number, let student = store.students.first(where: { $0.number == number }) {
            item.studentId = student.id
            item.studentName = student.name
            if item.period == nil { item.period = student.period }
        }
        if let name = c.name { fallbackNames[c.id] = name }
        preview.flash(c.track)
        haptics.notificationOccurred(.success)
        // Several sheets captured together: count them rather than showing one score.
        let together = captureShown.map { Date().timeIntervalSince($0.at) < 0.5 } ?? false
        capturedTogether = together ? capturedTogether + 1 : 1
        captureShown = (capturedTogether > 1
                        ? Pill(text: "✓ \(capturedTogether) sheets captured", tone: .good)
                        : Pill(text: "✓ \(c.quiz.scoreText(c.answers))\(item.studentName.map { " · \(Self.short($0))" } ?? "")", tone: .good),
                        Date(), c.id)
        setPill(captureShown!.pill)

        if let target = rescanning {
            // A rescan takes the old scan's place in the batch.
            rescanning = nil
            scanner.configure(single: mode == .single, expect: nil)
            scanner.resume(rescan: false)
            if let i = items.firstIndex(where: { $0.id == target }) {
                let old = items[i]
                items[i] = item
                drop(old)
            } else {
                items.append(item)
            }
            saveBatch()
            if rescanFromReview {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.openReview(at: item.id) }
            }
        } else if mode == .single {
            if let old = single { finishSingle(old) }
            single = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                guard let self, self.single?.id == item.id else { return }
                self.preview.freeze(true)
                self.card = CardRef(id: item.id)
            }
        } else {
            items.append(item)
            saveBatch()
        }
    }

    private func photoArrived(_ p: PhotoResult) {
        guard var item = self.item(p.id) else { fallbackNames[p.id] = nil; return }
        if let answers = p.answers {
            item.answers = answers
            item.rows = p.rows
        } else if let quiz = quiz(item.quizId) {
            item.rows = Review.rows(item.answers, marks: [:], key: quiz.answerKey).rows   // video only: marks not known
        }
        if let period = p.period { item.period = period }
        if let jpeg = p.jpeg { item.photo = Photos.save(jpeg, id: item.id) } else { item.photoFailed = true }
        update(item)
        let strip = p.name ?? fallbackNames[p.id]
        fallbackNames[p.id] = nil
        if let box = p.periodBox ?? fallbackPeriods[p.id] { periodStrips[p.id] = box }
        fallbackPeriods[p.id] = nil
        if let box = p.dateBox ?? fallbackDates[p.id] { dateStrips[p.id] = box }
        fallbackDates[p.id] = nil
        Task { await finalize(p.id, strip) }
    }

    /// Reads the handwritten name, matches it to the class list, applies the one-scan-per-student rule, and uploads.
    private func finalize(_ id: String, _ strip: GrayStrip?) async {
        var read: String?
        if let strip { read = await NameReader.read(strip) }
        var writtenPeriod: Int?   // ZipGrade: the period is written in a box, not bubbled
        if let box = periodStrips.removeValue(forKey: id) { writtenPeriod = await NameReader.readPeriod(box) }
        var writtenDate: String?
        if let box = dateStrips.removeValue(forKey: id) { writtenDate = await NameReader.readDate(box) }
        guard var item = self.item(id) else { return }
        if item.period == nil { item.period = writtenPeriod }
        if item.takenOn == nil { item.takenOn = writtenDate }
        item.read = read
        item.nameImage = strip?.jpegDataURL()
        if item.studentId == nil {
            // Students already scanned for this test are less likely to be this sheet.
            let taken = Set(items.filter { $0.quizId == item.quizId && $0.id != id }.compactMap(\.studentId))
            let guess = NameMatch.decide(read, among: store.students, period: item.period, taken: taken)
            if let student = guess.assign {
                item.studentId = student.id
                item.studentName = student.name
                if item.period == nil { item.period = student.period }
            } else {
                item.suggestedId = guess.suggest?.id
            }
        }
        if item.studentName == nil { item.studentName = read }
        item.processing = false
        item.periodMismatch = mismatch(item)
        if isBatch(id), let j = BatchRules.duplicate(item, in: items) {
            // The same student again: nothing is replaced. This one waits, without the student, for the teacher to compare.
            let other = items[j]
            item.duplicateOf = other.id
            item.suggestedId = item.studentId ?? other.studentId ?? item.suggestedId
            item.studentId = nil
        }
        update(item)
        store.enqueue(item.upload)
        if let shown = captureShown, shown.id == id, capturedTogether <= 1, let name = item.studentName {
            captureShown?.pill = Pill(text: "✓ \(quiz(item.quizId)?.scoreText(item.answers) ?? "") · \(Self.short(name))", tone: .good)
            if Date().timeIntervalSince(shown.at) < 1.6 { setPill(captureShown!.pill) }
        }
    }

    private func note(_ text: String) {
        note = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in if self?.note == text { self?.note = nil } }
    }

    // MARK: Fixing an item

    func assign(_ id: String, to student: Student?) {
        guard var item = self.item(id) else { return }
        // One scan per student per test: if the student already has one in this batch, the teacher compares the two.
        if let student, let other = items.first(where: { $0.id != id && $0.quizId == item.quizId && $0.studentId == student.id }) {
            item.duplicateOf = other.id
            item.suggestedId = student.id
            save(item)
            return
        }
        item.suggestedId = nil
        item.duplicateOf = nil
        item.studentId = student?.id
        item.studentName = student?.name ?? item.read
        if item.period == nil { item.period = student?.period }
        item.periodMismatch = mismatch(item)
        save(item)
    }

    func setPeriod(_ id: String, _ period: Int?) {
        guard var item = self.item(id) else { return }
        item.period = period
        item.periodMismatch = mismatch(item)
        save(item)
    }

    /// Settles a row: the answer the teacher picked (a letter, or "-" for none). Undo puts the row back.
    func settle(_ id: String, question: Int, answer: Character) {
        guard var item = self.item(id), question < item.answers.count else { return }
        var chars = Array(item.answers)
        chars[question] = answer
        item.answers = String(chars)
        item.rows[question]?.result = String(answer)
        save(item)
    }

    func undoSettle(_ id: String, question: Int) {
        guard var item = self.item(id), let row = item.rows[question], question < item.answers.count, let flag = row.flag.first else { return }
        var chars = Array(item.answers)
        chars[question] = flag
        item.answers = String(chars)
        item.rows[question]?.result = nil
        save(item)
    }

    private func save(_ item: ScanItem) {
        update(item)
        guard !item.processing else { return }   // not uploaded yet; it goes up with these changes
        Task { await store.fix(item.id, studentId: item.studentId, name: item.studentName, period: item.period, answers: item.answers,
                               review: Review.stored(item.rows) ?? [:], quizId: item.quizId) }
    }

    /// Two scans of one student: keeps one and deletes the other. The kept one gets the student.
    func keep(_ id: String, mine keepMine: Bool) {
        guard let item = item(id), let otherId = item.duplicateOf else { return }
        let student = student(item.suggestedId)
        store.conflicts[id] = nil
        if !keepMine {
            discard(id)
            return
        }
        Task {
            if isBatch(otherId) { discard(otherId) } else { await store.remove(otherId) }
            guard var kept = self.item(id) else { return }
            kept.duplicateOf = nil
            kept.suggestedId = nil
            if let student {
                kept.studentId = student.id
                kept.studentName = student.name
                if kept.period == nil { kept.period = student.period }
            }
            save(kept)
        }
    }

    /// Deletes an item here and on the server.
    func discard(_ id: String) {
        if let i = items.firstIndex(where: { $0.id == id }) {
            let item = items.remove(at: i)
            drop(item)
            saveBatch()
            if reviewId == id { reviewId = (items.indices.first { $0 >= i && !items[$0].decided }.map { items[$0] } ?? items.first { !$0.decided })?.id }
        } else if let item = single, item.id == id {
            single = nil
            drop(item)
            preview.freeze(false)
            scanner.resume(rescan: false)
        }
    }

    private func drop(_ item: ScanItem) {
        fallbackNames[item.id] = nil
        fallbackPeriods[item.id] = nil
        periodStrips[item.id] = nil
        fallbackDates[item.id] = nil
        dateStrips[item.id] = nil
        if !item.processing { Task { await store.remove(item.id) } }
        if let photo = item.photo { Photos.remove(photo) }
    }

    /// Forgets an item that's done on the phone; its upload continues.
    private func release(_ item: ScanItem) {
        guard let photo = item.photo, !store.pending.contains(where: { $0.id == item.id }) else { return }
        Photos.remove(photo)
    }

    private func photosChanged() {
        store.keepPhotos = Set((items + [single].compactMap { $0 }).compactMap(\.photo))
    }

    // MARK: Single mode

    func nextSheet() {
        card = nil
        if let single { finishSingle(single) }
    }

    func rescanSingle() {
        guard let item = single else { return }
        single = nil
        card = nil
        drop(item)
        preview.freeze(false)
        scanner.resume(rescan: true)
    }

    private func finishSingle(_ item: ScanItem) {
        single = nil
        release(item)
        preview.freeze(false)
        scanner.resume(rescan: false)
    }

    /// A card over the camera was swiped away.
    func cardDismissed() {
        if let single { finishSingle(single) }
        if heldForCard {
            heldForCard = false
            scanner.hold(false)
        }
    }

    /// Opens a batch item's card over the camera; scanning waits meanwhile.
    func openCard(_ id: String) {
        heldForCard = true
        scanner.hold(true)
        card = CardRef(id: id)
    }

    // MARK: Review

    var unreviewed: Int { items.filter { !$0.decided }.count }
    var undecided: Int { unreviewed }
    var reviewItem: ScanItem? { reviewId.flatMap { id in items.first { $0.id == id } } }

    func openReview(at id: String? = nil) {
        reviewId = id ?? items.first { !$0.decided }?.id
        showReview = true
        scanner.stop()
    }

    func reviewClosed() {
        guard rescanning == nil, store.tab == .scan else { return }
        scanner.start()
    }

    func approve(_ id: String) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].reviewed = true
        items[i].rejected = false
        saveBatch()
    }

    /// Rejected in review: it stays (dimmed, with Undo) until the batch is finished, then it's deleted.
    func reject(_ id: String) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].rejected = true
        items[i].reviewed = false
        saveBatch()
    }

    func unreject(_ id: String) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].rejected = false
        saveBatch()
    }

    /// The next sheet after `id` that hasn't been approved or rejected, wrapping around.
    func nextUndecided(after id: String) -> String? {
        let i = items.firstIndex { $0.id == id } ?? -1
        return (items.indices.filter { $0 > i && !items[$0].decided }.first.map { items[$0] } ?? items.first { !$0.decided })?.id
    }

    /// Rescans one batch item: the camera captures just that test once, and the new scan takes its place.
    func startRescan(_ id: String) {
        guard let item = items.first(where: { $0.id == id }) else { return }
        rescanFromReview = showReview
        rescanning = id
        showReview = false
        card = nil
        heldForCard = false
        scanner.hold(false)
        scanner.configure(single: true, expect: item.quizId)
        scanner.reset()
        scanner.start()
    }

    func cancelRescan() {
        guard let id = rescanning else { return }
        rescanning = nil
        scanner.configure(single: mode == .single, expect: nil)
        scanner.resume(rescan: false)
        if rescanFromReview { openReview(at: id) }
    }

    var average: Double? {
        let percents = items.compactMap { item in quiz(item.quizId).flatMap { q in q.maxScore > 0 ? q.score(item.answers) / q.maxScore * 100 : nil } }
        return percents.isEmpty ? nil : percents.reduce(0, +) / Double(percents.count)
    }

    /// Ends the batch after review: rejected sheets are deleted, the rest stay saved (their uploads keep going).
    func finishBatch() {
        for item in items { if item.rejected { drop(item) } else { release(item) } }
        items = []
        reviewId = nil
        saveBatch()
    }

    /// Throws the whole batch away: every sheet in it is deleted, here and in the portal.
    func discardBatch() {
        for item in items { drop(item) }
        items = []
        reviewId = nil
        saveBatch()
    }

    // MARK: Saving the batch

    private static var batchURL: URL {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("batch.json")
    }

    private func saveBatch() {
        try? JSONEncoder().encode(items).write(to: Self.batchURL, options: .atomic)
    }

    private func loadBatch() {
        guard let data = try? Data(contentsOf: Self.batchURL), var saved = try? JSONDecoder().decode([ScanItem].self, from: data) else {
            Photos.prune(keeping: Set(store.pending.compactMap(\.localPhoto)))
            return
        }
        // Closed mid-read: keep what the video read and upload it.
        for i in saved.indices where saved[i].processing {
            saved[i].processing = false
            if saved[i].photo == nil { saved[i].photoFailed = true }
            if !store.pending.contains(where: { $0.id == saved[i].id }) { store.enqueue(saved[i].upload) }
        }
        items = saved
        Photos.prune(keeping: Set(saved.compactMap(\.photo) + store.pending.compactMap(\.localPhoto)))
    }

    /// "Maria Gonzalez" → "Maria G."
    static func short(_ name: String) -> String {
        let words = name.split(separator: " ")
        guard words.count > 1, let initial = words.last?.first else { return name }
        return "\(words[0]) \(initial)."
    }
}
