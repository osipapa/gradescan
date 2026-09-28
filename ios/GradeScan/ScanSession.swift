import AVFoundation
import Combine
import SwiftUI
import UIKit

/// The camera and what it captured: the batch and its review, or the single-mode card.
@MainActor
final class ScanSession: ObservableObject {
    /// Single: one sheet, result right away. Batch: sheet after sheet, reviewed at the end. Stand: batch with the
    /// phone propped up over the table and sheets slid under it, a tick for each one.
    enum Mode: String, CaseIterable { case single, batch, stand }

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
            if mode == .stand { note("Prop the phone up over the table and slide the sheets under it, one after another. You'll hear a tick for each.") }
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
    private var torchTurnedOff = false
    /// The test this batch's ZipGrade sheets are for (they carry no test code). The teacher is asked for every batch:
    /// it's forgotten when the batch is finished or thrown away, and never saved.
    @Published var zipgradeQuizId: String? {
        didSet { scanner.setZipGrade(zipgradeQuizId.flatMap(quiz)) }
    }
    @Published var askZipGrade = false                        // the ZipGrade test list is open
    @Published private(set) var zipgradeInView = false
    @Published private(set) var zipgradeNeedsTest = false     // a ZipGrade sheet is in view and this batch has no test yet
    private var zipgradeLastNeeded = Date.distantPast
    /// Reading an answer key: a sheet with every answer right, to set up a new test from.
    @Published private(set) var capturingKey = false
    @Published var keyDraft: KeyDraft?                        // the key just read, for the new test form
    private var keyCaptureId: String?
    private var keyAnswers: String?
    private var fallbackPictures: [String: Data] = [:]      // video-frame sheet pictures, in case the photo fails

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
    private var importWatch: AnyCancellable?
    private lazy var haptics: UINotificationFeedbackGenerator = {
        if #available(iOS 17.5, *) { return UINotificationFeedbackGenerator(view: preview) }
        return UINotificationFeedbackGenerator()
    }()

    init(store: AppStore) {
        self.store = store
        mode = Mode(rawValue: UserDefaults.standard.string(forKey: "scanMode") ?? "") ?? .batch
        UserDefaults.standard.removeObject(forKey: "zipgradeQuiz")   // earlier versions remembered it
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
        // Off to import the class list: the review and any card over the camera close; the batch waits here.
        importWatch = store.$importingClass.sink { [weak self] on in
            guard on, let self else { return }
            self.showReview = false
            self.card = nil
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
        if items.isEmpty && rescanning == nil { zipgradeQuizId = nil }   // no batch going: the next scan asks again
    }

    /// Keeps what the camera sees right now, for a sheet that won't scan (Settings › Help improve scanning).
    func saveProblemFrame() {
        scanner.saveNextFrame { [weak self] jpeg, note in
            Task { @MainActor [weak self] in
                guard let jpeg else { return }
                ProblemFrames.save(jpeg, note: note)
                self?.note("Frame saved. Share it from Settings.")
            }
        }
    }

    func toggleTorch() {
        torch.toggle()
        if !torch { torchTurnedOff = true }   // it doesn't come back on by itself after that
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

    // MARK: Answer key

    /// The stand-in test an answer key sheet is read against: all of ZipGrade's 20 rows, A–E.
    static let keyQuiz = Quiz(id: "answer-key", title: "Answer key", numQuestions: 20, numChoices: 5, answerKey: String(repeating: "*", count: 20),
                              pointsPerQuestion: 1, bonusCount: 0, layout: nil, code: nil)

    /// Reads the next ZipGrade sheet held up as the answer key for a new test.
    func startKeyCapture() {
        askZipGrade = false
        capturingKey = true
        keyCaptureId = nil
        keyAnswers = nil
        card = nil
        scanner.configure(single: true, expect: nil)
        scanner.setZipGrade(Self.keyQuiz)
        scanner.setAnswerKey(true)   // not the sheet already in view; hold the key steady a moment
        setPill(Pill(text: "Hold up the answer key"))
    }

    func cancelKeyCapture() {
        capturingKey = false
        keyCaptureId = nil
        scanner.setAnswerKey(false)
        restoreScanning()
    }

    /// The new test form closed: with the test made from the key, this batch's ZipGrade sheets go to it.
    func keyTestDone(_ quiz: Quiz?) {
        keyDraft = nil
        capturingKey = false
        keyCaptureId = nil
        if let quiz { zipgradeQuizId = quiz.id }
        scanner.setAnswerKey(false)
        scanner.ignoreInView()   // the key sheet itself isn't a student's
        restoreScanning()
    }

    private func restoreScanning() {
        scanner.configure(single: mode == .single, expect: nil)
        scanner.setZipGrade(zipgradeQuizId.flatMap(quiz))
        scanner.resume(rescan: false)
    }

    /// The key as read: a letter per question up to the last one answered; rows it couldn't read are left to fill in.
    private func showKey(_ answers: String) {
        let letters = answers.map { "ABCDE".contains($0) ? $0 : nil } as [Character?]
        let count = (letters.lastIndex { $0 != nil } ?? 19) + 1
        keyDraft = KeyDraft(key: Array(letters.prefix(count)), choices: 5)   // ZipGrade's form has A–E
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
            if f.hint == .dark && !torch && !torchTurnedOff {
                torch = true
                scanner.setTorch(true)
            }
            let zipgrade = f.sheets.contains { $0.zipgrade }
            if zipgradeInView != zipgrade { zipgradeInView = zipgrade }
            // Asked on the camera, not in a pop-up that opens by itself: the teacher taps to choose.
            if f.sheets.contains(where: \.needsTest) { zipgradeLastNeeded = Date() }
            let needs = !capturingKey && Date().timeIntervalSince(zipgradeLastNeeded) < 1.5
            if zipgradeNeedsTest != needs { zipgradeNeedsTest = needs }
            preview.show(f.sheets.compactMap { sheet in
                guard let map = sheet.map else { return nil }
                var look: PreviewView.Look
                switch sheet.gate {
                case .locking(let p): look = sheet.unknownTest || sheet.wrongTest ? .warn : .locking(p)
                case .waiting, .fire: look = .done
                case .blank: look = .warn
                case .idle: look = sheet.unknownTest || sheet.wrongTest || sheet.needsTest ? .warn : .plain
                }
                if sheet.partial { look = .warn }
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
        case .alreadyScanned:
            captureShown = (Pill(text: "Already scanned", tone: .good), Date(), "")
            setPill(captureShown!.pill)
        }
    }

    private func updatePill(_ f: FrameInfo) {
        if let shown = captureShown, Date().timeIntervalSince(shown.at) < 1.6 { return setPill(shown.pill) }
        if f.sheets.contains(where: \.unknownTest) { return setPill(Pill(text: "Not one of your tests", tone: .warn)) }
        switch f.hint {
        case .corners?: return setPill(Pill(text: "Keep all four corners in view", tone: .warn))
        case .dark?: return setPill(Pill(text: torch ? "Still too dark; move to more light" : "Too dark"))
        case .glare?: return setPill(Pill(text: "Glare on the sheet; tilt it a little"))
        case .far?: return setPill(Pill(text: "Move closer"))
        case nil: break
        }

        if let q = f.sheets.first(where: \.wrongTest)?.quiz { return setPill(Pill(text: "This sheet is for \(q.title)", tone: .warn)) }
        let gates = f.sheets.map(\.gate)
        let several = f.sheets.count > 1 ? "\(f.sheets.count) sheets · " : ""
        if capturingKey { return setPill(Pill(text: gates.isEmpty ? "Hold up the answer key" : "Hold steady")) }
        if gates.isEmpty {
            return setPill(Pill(text: rescanning != nil ? "Point at the sheet to rescan" : mode == .stand ? "Slide a sheet under the phone" : "Point at the sheets"))
        }
        if gates.contains(where: { if case .locking = $0 { return true } else { return false } }) { return setPill(Pill(text: several + "Hold steady")) }
        if gates.contains(.blank) { return setPill(Pill(text: several + "Nothing filled in", tone: .warn)) }
        if gates.allSatisfy({ $0 == .waiting || { if case .fire = $0 { return true } else { return false } }($0) }) {
            return setPill(Pill(text: mode == .single ? "Captured" : f.sheets.count > 1 ? "All captured · next ones" : "Next sheet", tone: .good))
        }
        setPill(Pill(text: several + "Hold steady"))
    }

    private func setPill(_ p: Pill) { if pill != p { pill = p } }

    private func captured(_ c: Capture) {
        if c.quiz.id == Self.keyQuiz.id {
            // The answer key: wait for the sharper photo's reading (or the video's, if the photo doesn't come).
            keyCaptureId = c.id
            keyAnswers = c.answers
            preview.flash(c.track)
            haptics.notificationOccurred(.success)
            setPill(Pill(text: "Reading the answer key…"))
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
                guard let self, self.keyCaptureId == c.id, self.keyDraft == nil, let answers = self.keyAnswers else { return }
                self.showKey(answers)
            }
            return
        }
        if let picture = c.picture { fallbackPictures[c.id] = picture }
        var item = ScanItem(id: c.id, quizId: c.quiz.id, answers: c.answers, period: c.period, scannedAt: c.scannedAt)
        if c.kind == .zipgrade20 {
            item.form = SheetKind.zipgrade20.rawValue
            if let box = c.periodBox { fallbackPeriods[c.id] = box }
        }
        if let box = c.dateBox { fallbackDates[c.id] = box }   // ZipGrade sheets, and ours printed with a Date line
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
            scanner.setZipGrade(zipgradeQuizId.flatMap(quiz))
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
            if mode == .stand { Tick.play() }
            items.append(item)
            saveBatch()
        }
    }

    private func photoArrived(_ p: PhotoResult) {
        if p.id == keyCaptureId {
            if keyDraft == nil { showKey(p.answers ?? keyAnswers ?? "") }
            return
        }
        let picture = fallbackPictures.removeValue(forKey: p.id)
        guard var item = self.item(p.id) else { fallbackNames[p.id] = nil; return }
        if let answers = p.answers {
            item.answers = answers
            item.rows = p.rows
        } else if let quiz = quiz(item.quizId) {
            item.rows = Review.rows(item.answers, marks: [:], key: quiz.answerKey).rows   // video only: marks not known
        }
        if let period = p.period { item.period = period }
        // Without a photo, the video frame's picture of the sheet: less sharp, but the teacher can check the marks.
        if let jpeg = p.jpeg ?? picture { item.photo = Photos.save(jpeg, id: item.id) } else { item.photoFailed = true }
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
        var reading = NameReader.Result()
        if let strip { reading = await NameReader.read(strip, names: store.students.map(\.name)) }
        let read = reading.text
        // How much the writing looks like each student's earlier sheets.
        let looks = await HandwritingMemory.shared.likelihoods(reading.handwriting, user: store.session?.userId ?? "local")
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
            let guess = NameMatch.decide(reading.readings, among: store.students, period: item.period, taken: taken, handwriting: looks)
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
        learn(item, reading.handwriting)
        if let shown = captureShown, shown.id == id, capturedTogether <= 1, let name = item.studentName {
            captureShown?.pill = Pill(text: "✓ \(quiz(item.quizId)?.scoreText(item.answers) ?? "") · \(Self.short(name))", tone: .good)
            if Date().timeIntervalSince(shown.at) < 1.6 { setPill(captureShown!.pill) }
        }
    }

    /// Adds the sheet's handwriting to what the phone knows of the student's writing, and now and then catches up with
    /// the server: fixes made later (here or in the portal) move the sample, and older sheets are learned too.
    private func learn(_ item: ScanItem, _ handwriting: [Float]?) {
        let session = store.session, user = session?.userId ?? "local"
        Task {
            await HandwritingMemory.shared.remember(item.id, studentId: item.studentId, print: handwriting, user: user)
            if let session, session.expiresAt > Date().addingTimeInterval(120) {
                await HandwritingMemory.shared.sync(user: session.userId, token: session.accessToken)
            }
        }
    }

    private func note(_ text: String) {
        note = text
        let seconds = max(2.5, Double(text.count) / 18)   // long enough to read
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in if self?.note == text { self?.note = nil } }
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

    // MARK: Review

    var unreviewed: Int { items.filter { !$0.decided }.count }

    /// Opens the review at a sheet, or (nil) at the first that needs a look.
    func openReview(at id: String? = nil) {
        reviewId = id
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
        if item.form == SheetKind.zipgrade20.rawValue { scanner.setZipGrade(quiz(item.quizId)) }   // it's already known
        scanner.reset()
        scanner.start()
    }

    func cancelRescan() {
        guard let id = rescanning else { return }
        rescanning = nil
        scanner.configure(single: mode == .single, expect: nil)
        scanner.setZipGrade(zipgradeQuizId.flatMap(quiz))
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
        zipgradeQuizId = nil
        saveBatch()
    }

    /// Throws the whole batch away: every sheet in it is deleted, here and in the portal.
    func discardBatch() {
        for item in items { drop(item) }
        items = []
        reviewId = nil
        zipgradeQuizId = nil
        saveBatch()
    }

    // TESTING ONLY — remove before production, with the wipe in Settings.
    /// Forgets the batch on this phone; the wipe deletes the server's copies itself.
    func forgetBatch() {
        for item in items { if let photo = item.photo { Photos.remove(photo) } }
        items = []
        reviewId = nil
        card = nil
        zipgradeQuizId = nil
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

/// An answer key read from a sheet, for the new test form.
struct KeyDraft: Identifiable {
    let id = UUID()
    let key: [Character?]
    let choices: Int
}
