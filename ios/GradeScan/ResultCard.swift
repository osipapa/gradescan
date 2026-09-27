import SwiftUI

/// What a result card shows. Built from a scan on the phone or one from the server.
struct CardData {
    var quiz: Quiz?
    var answers: String
    var override: Double?
    var period: Int?
    var studentId: String?
    var studentName: String?
    var read: String?
    var nameImage: String?
    var localPhoto: String?
    var photoPath: String?
    var processing = false
    var notes: [String] = []
    var suggestion: Student?          // who the handwriting probably is, to confirm with one tap
    var rows: [Int: RowReview] = [:]  // rows to check, and ones already settled (shown with Undo)
    var duplicate = false             // the student already has another scan for this test: compare and keep one
    var layout: SheetLayout?          // the photo's sheet when it isn't the test's own (a ZipGrade form)
}

/// One scanned sheet: the photo with its ✓ and ✗, who it is and the score, and any rows waiting for the teacher.
/// Used by single mode, the batch review, and a test's results.
struct ResultCard: View {
    @EnvironmentObject var store: AppStore
    let data: CardData
    let assign: (Student?) -> Void
    let setPeriod: (Int?) -> Void
    let settle: (Int, Character) -> Void   // settle a row to a letter, or "-" for no answer
    let undo: (Int) -> Void
    var compare: () -> Void = {}
    @State private var picking = false
    @State private var remote: UIImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            photo
            header
            who
            if let quiz = data.quiz { decisions(quiz) }
            ForEach(data.notes, id: \.self) { Text($0).font(.footnote).foregroundStyle(.secondary) }
        }
        .sheet(isPresented: $picking) {
            StudentPicker(read: data.read, handwriting: UIImage(dataURL: data.nameImage), period: data.period, current: data.studentId ?? data.suggestion?.id, pick: assign)
                .environmentObject(store)
        }
        .task(id: data.photoPath) {
            if data.localPhoto == nil, let path = data.photoPath { remote = await store.photo(path) }
        }
    }

    private var localImage: UIImage? { data.localPhoto.flatMap { UIImage(contentsOfFile: Photos.url($0).path) } }

    private var photo: some View {
        Group {
            if let image = localImage ?? remote {
                Image(uiImage: image).resizable().scaledToFit()
                    .overlay {
                        if let quiz = data.quiz, let layout = data.layout ?? quiz.layout {
                            SheetMarks(quiz: quiz, layout: layout, answers: data.answers, rows: data.rows,
                                       clean: data.localPhoto != nil || data.photoPath?.hasSuffix(".clean.jpg") == true)
                            Highlights(boxes: Highlights.rows(data.rows.filter { $0.value.result == nil }.keys.sorted(), layout,
                                                              choices: quiz.numChoices), layout: layout)
                        }
                    }
                    .frame(maxHeight: 420)
            } else {
                ZStack {
                    Color(.secondarySystemBackground)
                    if data.processing { ProgressView() } else { Text(data.photoPath == nil ? "No photo" : "Loading…").foregroundStyle(.secondary) }
                }
                .frame(height: 200)
            }
        }
        .frame(maxWidth: .infinity)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    /// Name and score on one line; what the handwriting read and the period underneath.
    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Button { picking = true } label: {
                    HStack(spacing: 6) {
                        Text(data.studentId != nil ? (data.studentName ?? "Student") : data.suggestion.map { "\($0.name)?" } ?? "Who is this?")
                            .font(.title3.weight(.semibold)).foregroundStyle(.primary)
                        Image(systemName: "chevron.down").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
                HStack(spacing: 6) {
                    if let read = data.read, data.studentId == nil || read.lowercased() != data.studentName?.lowercased() {
                        Text("“\(read)”")
                        Text("·")
                    } else if data.processing {
                        Text("Reading the name…")
                        Text("·")
                    }
                    Menu {
                        ForEach(1...9, id: \.self) { p in Button("Period \(p)") { setPeriod(p) } }
                    } label: {
                        Text(data.period.map { "Period \($0)" } ?? "No period").foregroundStyle(data.period == nil ? Brand.warn : .secondary)
                    }
                }
                .font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            if let quiz = data.quiz {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(quiz.scoreText(data.answers, override: data.override)).font(.title3.weight(.semibold)).monospacedDigit()
                    if let p = quiz.percent(data.answers, override: data.override) {
                        Text("\(p)%").font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            }
        }
    }

    /// The one thing to do about who it is, if anything: confirm the likely student, or compare two scans.
    @ViewBuilder private var who: some View {
        if data.duplicate {
            VStack(alignment: .leading, spacing: 8) {
                Text("\(data.suggestion?.name ?? "This student") already has a scan for this test.").font(.subheadline).foregroundStyle(.secondary)
                Button("Compare and keep one", action: compare).buttonStyle(.bordered)
            }
        } else if data.studentId == nil, let suggestion = data.suggestion {
            HStack(spacing: 16) {
                Button("Yes, \(suggestion.name)") { assign(suggestion) }.primaryButton()
                Button("Someone else") { picking = true }.buttonStyle(.borderless)
            }
        }
    }

    /// Rows the phone couldn't call: a ✓ or ✗ from the teacher each. Once decided they stay as one line with Undo.
    @ViewBuilder private func decisions(_ quiz: Quiz) -> some View {
        let key = Array(quiz.answerKey.uppercased())
        let questions = data.rows.keys.sorted()
        if !questions.isEmpty {
            VStack(alignment: .leading, spacing: 18) {
                ForEach(questions, id: \.self) { q in
                    if let row = data.rows[q] { decision(q, row, key: q < key.count ? key[q] : "?") }
                }
            }
        }
    }

    @ViewBuilder private func decision(_ q: Int, _ row: RowReview, key: Character) -> some View {
        if let result = row.result {
            let right = result.first == key
            HStack(spacing: 8) {
                Text("Question \(q + 1)")
                Image(systemName: right ? "checkmark" : "xmark").fontWeight(.bold).foregroundStyle(right ? Brand.good : Brand.bad)
                Spacer()
                Button("Undo") { undo(q) }
            }
            .font(.subheadline).foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                (Text("Question \(q + 1)").fontWeight(.semibold) + Text("  \(describe(row)) · answer \(String(key))").foregroundStyle(.secondary))
                    .font(.subheadline)
                HStack(spacing: 10) {
                    Button { settle(q, key) } label: { Label("Right", systemImage: "checkmark").frame(maxWidth: .infinity) }
                    Button { settle(q, Character(Review.noCredit(row, key: key))) } label: { Label("Wrong", systemImage: "xmark").frame(maxWidth: .infinity) }
                }
                .buttonStyle(.bordered)
                .tint(.primary)
            }
        }
    }

    /// "marked A and C", "unclear mark on B"
    private func describe(_ row: RowReview) -> String {
        let letters = row.marks.map(String.init)
        guard let last = letters.last else { return row.flag == "*" ? "more than one mark" : "unclear mark" }
        if letters.count == 1 { return row.flag == "*" ? "marked \(last)" : "unclear mark on \(last)" }
        return "marked " + letters.dropLast().joined(separator: ", ") + " and " + last
    }
}

/// Picks the student for a scan: best matches for the handwriting first, then the rest of the class.
struct StudentPicker: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let read: String?
    let handwriting: UIImage?
    let period: Int?
    let current: String?
    let pick: (Student?) -> Void
    @State private var search = ""

    var body: some View {
        NavigationStack {
            List {
                if handwriting != nil || read != nil {
                    Section {
                        if let handwriting {
                            Image(uiImage: handwriting).resizable().scaledToFit().frame(maxHeight: 60)
                                .background(.white).clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        Text(read.map { "Read as “\($0)”" } ?? "Couldn't read the name").foregroundStyle(.secondary)
                    }
                }
                Section(read == nil ? (period.map { "Period \($0) first" } ?? "Class list") : "Best matches first") {
                    ForEach(ranked) { student in
                        Button {
                            pick(student)
                            dismiss()
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(student.name).foregroundStyle(.primary)
                                    if let p = student.period { Text("Period \(p)").font(.caption).foregroundStyle(.secondary) }
                                }
                                Spacer()
                                if student.id == current { Image(systemName: "checkmark").foregroundStyle(Brand.sageStrong) }
                            }
                        }
                    }
                }
                Section {
                    Button("Not on the list") {
                        pick(nil)
                        dismiss()
                    }
                }
            }
            .overlay {
                if store.students.isEmpty {
                    ContentUnavailableView("No class list", systemImage: "person.2", description: Text("Add students in the portal."))
                }
            }
            .searchable(text: $search, prompt: "Search names")
            .navigationTitle("Who is this?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }

    private var ranked: [Student] {
        let list = NameMatch.guesses(read, among: store.students, period: period).map(\.student)
        return search.isEmpty ? list : list.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }
}

/// The card for a scan on the phone, wired to the scan session.
struct ItemCard: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var scan: ScanSession
    let item: ScanItem
    @State private var comparing = false

    var body: some View {
        ResultCard(data: CardData(quiz: scan.quiz(item.quizId), answers: item.answers, period: item.period, studentId: item.studentId,
                                  studentName: item.studentName, read: item.read, nameImage: item.nameImage, localPhoto: item.photo,
                                  processing: item.processing, notes: scan.notes(item), suggestion: scan.student(item.suggestedId),
                                  rows: item.rows, duplicate: item.duplicateOf != nil, layout: item.layout(scan.quiz(item.quizId))),
                   assign: { scan.assign(item.id, to: $0) },
                   setPeriod: { scan.setPeriod(item.id, $0) },
                   settle: { scan.settle(item.id, question: $0, answer: $1) },
                   undo: { scan.undoSettle(item.id, question: $0) },
                   compare: { comparing = true })
        .sheet(isPresented: $comparing) {
            if let quiz = scan.quiz(item.quizId), let otherId = item.duplicateOf {
                CompareSheet(quiz: quiz, student: scan.student(item.suggestedId), mine: ScanSide(item), otherId: otherId,
                             localOther: scan.item(otherId).map(ScanSide.init)) { keepMine in scan.keep(item.id, mine: keepMine) }
                    .environmentObject(store)
            }
        }
    }
}

/// A card over the camera: the single-mode result, or a batch sheet tapped in the tray.
struct ItemCardSheet: View {
    @EnvironmentObject var scan: ScanSession
    @Environment(\.dismiss) private var dismiss
    let id: String
    @State private var confirmDiscard = false

    var body: some View {
        let isSingle = scan.single?.id == id
        NavigationStack {
            ScrollView {
                if let item = scan.item(id) {
                    ItemCard(item: item).padding()
                } else {
                    ContentUnavailableView("Scan removed", systemImage: "trash")
                }
            }
            .safeAreaInset(edge: .bottom) {
                if scan.item(id) != nil {
                    HStack(spacing: 10) {
                        Button(role: .destructive) { confirmDiscard = true } label: {
                            Image(systemName: "trash").frame(width: 28)
                        }
                        .buttonStyle(.bordered)
                        .tint(.secondary)
                        .accessibilityLabel("Delete")
                        Button {
                            if isSingle { scan.rescanSingle() } else { scan.startRescan(id) }
                        } label: {
                            Label("Rescan", systemImage: "camera.viewfinder").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        Button {
                            if isSingle { scan.nextSheet() } else { dismiss() }
                        } label: {
                            Text(isSingle ? "Next sheet" : "Done").bold().frame(maxWidth: .infinity)
                        }
                        .primaryButton()
                    }
                    .controlSize(.large)
                    .padding()
                    .background(.bar)
                }
            }
            .navigationTitle(isSingle ? (scan.single.flatMap { scan.quiz($0.quizId)?.title } ?? "Result")
                                      : scan.position(id).map { "Sheet \($0) of \(scan.items.count)" } ?? "Sheet")
            .navigationBarTitleDisplayMode(.inline)
            .confirmationDialog("Delete this scan?", isPresented: $confirmDiscard, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    scan.discard(id)
                    if isSingle { scan.nextSheet() } else { dismiss() }
                }
            } message: {
                Text("It's removed from the portal too.")
            }
        }
        .presentationDragIndicator(.visible)
    }
}

/// One side of a comparison: a scan of the same student for the same test.
struct ScanSide {
    let id: String
    let answers: String
    let override: Double?
    let scannedAt: Date
    let localPhoto: String?
    let photoPath: String?
    let rows: [Int: RowReview]
    var form: String?
}

extension ScanSide {
    init(_ record: ScanRecord) {
        self.init(id: record.id, answers: record.answers, override: record.scoreOverride, scannedAt: record.scannedAt,
                  localPhoto: nil, photoPath: record.photoPath, rows: Review.loaded(record.review), form: record.form)
    }

    init(_ item: ScanItem) {
        self.init(id: item.id, answers: item.answers, override: nil, scannedAt: item.scannedAt, localPhoto: item.photo, photoPath: nil,
                  rows: item.rows, form: item.form)
    }
}

/// Two scans for one student: both sheets side by side, the questions where they differ outlined on both, and a pick.
/// Nothing is replaced until the teacher chooses.
struct CompareSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let quiz: Quiz
    let student: Student?
    let mine: ScanSide
    let otherId: String
    var localOther: ScanSide?
    let keep: (_ keepMine: Bool) -> Void
    @State private var other: ScanSide?
    @State private var failed = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let other {
                        let diff = differences(other)
                        Text(diff.isEmpty
                             ? "The answers are the same on both. Keep the one that matches the paper; the other is deleted."
                             : "They differ on \(diff.count == 1 ? "question" : "questions") \(diff.map { String($0 + 1) }.joined(separator: ", ")), outlined on both sheets. Keep the one that matches the paper; the other is deleted.")
                            .font(.subheadline).foregroundStyle(.secondary)
                        if !diff.isEmpty { table(diff, other) }
                        HStack(alignment: .top, spacing: 12) {
                            side(mine, "This scan", diff, keepMine: true)
                            side(other, "Other scan", diff, keepMine: false)
                        }
                    } else if failed {
                        ContentUnavailableView("Couldn't load the other scan", systemImage: "wifi.exclamationmark",
                                               description: Text("Check the connection and try again."))
                    } else {
                        ProgressView().frame(maxWidth: .infinity).padding(40)
                    }
                }
                .padding()
            }
            .navigationTitle(student.map { "\($0.name) has two scans" } ?? "Two scans of one sheet")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .task {
                guard other == nil else { return }
                if let localOther { other = localOther } else if let record = await store.record(otherId) { other = ScanSide(record) } else { failed = true }
            }
        }
    }

    private func differences(_ other: ScanSide) -> [Int] {
        let a = Array(mine.answers), b = Array(other.answers)
        return (0..<quiz.numQuestions).filter { ($0 < a.count ? a[$0] : "-") != ($0 < b.count ? b[$0] : "-") }
    }

    private func table(_ diff: [Int], _ other: ScanSide) -> some View {
        let key = Array(quiz.answerKey.uppercased())
        return Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
            GridRow {
                Text("Question")
                Text("This scan")
                Text("Other scan")
                Text("Answer")
            }
            .font(.caption).foregroundStyle(.secondary)
            ForEach(diff, id: \.self) { q in
                GridRow {
                    Text("\(q + 1)").monospacedDigit()
                    cell(mine.answers, q, key)
                    cell(other.answers, q, key)
                    Text(q < key.count ? String(key[q]) : "?")
                }
                .font(.subheadline)
            }
        }
    }

    private func cell(_ answers: String, _ q: Int, _ key: [Character]) -> some View {
        let chars = Array(answers)
        let a: Character = q < chars.count ? chars[q] : "-"
        let right = q < key.count && (key[q] == "*" || a == key[q])
        let label = a == "-" ? "Blank" : a == "*" ? "Two marks" : a == "?" ? "Unclear" : String(a)
        return Text("\(label) \(right ? "✓" : "✗")").foregroundStyle(right ? Brand.good : Brand.bad)
    }

    private func side(_ scan: ScanSide, _ label: String, _ diff: [Int], keepMine: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SidePhoto(quiz: quiz, side: scan, outline: diff)
            Text(label).font(.subheadline.weight(.semibold))
            Text("\(quiz.scoreText(scan.answers, override: scan.override)) · \(scan.scannedAt.formatted(.relative(presentation: .named)))")
                .font(.caption).foregroundStyle(.secondary)
            Button {
                keep(keepMine)
                dismiss()
            } label: {
                Text("Keep this one").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity)
    }
}

/// A scan's sheet photo for the comparison, with its ✓ and ✗ and the rows that differ outlined.
struct SidePhoto: View {
    @EnvironmentObject var store: AppStore
    let quiz: Quiz
    let side: ScanSide
    let outline: [Int]
    @State private var remote: UIImage?

    var body: some View {
        Group {
            if let image = side.localPhoto.flatMap({ UIImage(contentsOfFile: Photos.url($0).path) }) ?? remote {
                Image(uiImage: image).resizable().scaledToFit()
                    .overlay {
                        if let layout = side.form == SheetKind.zipgrade20.rawValue ? ZipGrade.form20 : quiz.layout {
                            SheetMarks(quiz: quiz, layout: layout, answers: side.answers, rows: side.rows,
                                       clean: side.localPhoto != nil || side.photoPath?.hasSuffix(".clean.jpg") == true)
                            Highlights(boxes: Highlights.rows(outline, layout, choices: quiz.numChoices), layout: layout)
                        }
                    }
            } else {
                Color(.secondarySystemBackground).frame(height: 180).overlay { if side.photoPath != nil { ProgressView() } }
            }
        }
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
        .task(id: side.photoPath) {
            if side.localPhoto == nil, let path = side.photoPath { remote = await store.photo(path) }
        }
    }
}

/// Dims the sheet except the parts to look at, which get an amber outline.
struct Highlights: View {
    let boxes: [CGRect]      // sheet inches
    let layout: SheetLayout

    var body: some View {
        Canvas { ctx, size in
            guard !boxes.isEmpty, layout.w > 0, layout.h > 0 else { return }
            let sx = size.width / layout.w, sy = size.height / layout.h
            let rects = boxes.map { CGRect(x: $0.minX * sx, y: $0.minY * sy, width: $0.width * sx, height: $0.height * sy) }
            var dim = Path(CGRect(origin: .zero, size: size))
            for rect in rects { dim.addRoundedRect(in: rect, cornerSize: CGSize(width: 6, height: 6)) }
            ctx.fill(dim, with: .color(.white.opacity(0.5)), style: FillStyle(eoFill: true))
            for rect in rects { ctx.stroke(Path(roundedRect: rect, cornerRadius: 6), with: .color(Brand.warn), lineWidth: 1.5) }
        }
        .allowsHitTesting(false)
    }

    /// The box around one row of bubbles and its number, in sheet inches.
    static func row(_ bubbles: [[Double]], _ layout: SheetLayout, choices: Int) -> CGRect? {
        let r = layout.r
        guard let first = bubbles.first, let last = bubbles.prefix(max(1, choices)).last, first.count == 2, last.count == 2 else { return nil }
        return CGRect(x: first[0] - r - 0.42, y: first[1] - r - 0.05, width: last[0] - first[0] + 2 * r + 0.5, height: 2 * r + 0.1)
    }

    static func rows(_ questions: [Int], _ layout: SheetLayout, choices: Int) -> [CGRect] {
        questions.compactMap { $0 < layout.questions.count ? row(layout.questions[$0], layout, choices: min(choices, 5)) : nil }
    }
}

/// The ✓ and ✗ over the sheet photo, from the current answers, so a teacher's call shows up right away.
/// Older photos have their marks printed in; on those only the rows the teacher settled are redrawn, over a white patch.
struct SheetMarks: View {
    let quiz: Quiz
    let layout: SheetLayout
    let answers: String
    let rows: [Int: RowReview]
    let clean: Bool

    var body: some View {
        Canvas { ctx, size in
            guard layout.w > 0, layout.h > 0 else { return }
            ctx.scaleBy(x: size.width / layout.w, y: size.height / layout.h)   // sheet inches
            let waiting = Set(rows.filter { $0.value.result == nil }.keys)
            var marks = Grader.marks(quiz, layout, answers, waiting: waiting)
            if !clean {
                let settled = Set(rows.filter { $0.value.result != nil }.keys)
                marks = marks.filter { settled.contains($0.question) }
                for m in marks {
                    ctx.fill(Path(CGRect(x: m.label.x - 0.1, y: m.label.y - 0.1, width: 0.2, height: 0.2)), with: .color(.white))
                }
            }
            for part in MarkPaths(marks, radius: layout.r).all {
                ctx.stroke(Path(part.path), with: .color(Color(cgColor: part.color)),
                           style: StrokeStyle(lineWidth: 0.032, lineCap: .round, lineJoin: .round))
            }
        }
        .allowsHitTesting(false)
    }
}
