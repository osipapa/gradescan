import Charts
import SwiftUI

/// A test's stats: averages, grade spread, periods, the hardest questions, and every result by period.
struct TestDetailView: View {
    @EnvironmentObject var store: AppStore
    let quiz: Quiz
    @State private var scans: [ScanRecord] = []
    @State private var loading = true
    @State private var failed: String?
    @State private var allQuestions = false
    @State private var open: ScanRecord?

    private struct ResultGroup: Identifiable {
        let period: Int?
        let rows: [ScanRecord]
        var id: Int { period ?? 0 }
        var title: String { period.map { "Period \($0)" } ?? "No period" }
    }

    var body: some View {
        let stats = TestStats(quiz: quiz, sheets: scans.map { ScoredSheet(answers: $0.answers, period: $0.period, override: $0.scoreOverride) })
        List {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Text(quiz.summary).foregroundStyle(.secondary)
                    Button { store.tab = .scan } label: {
                        Label("Scan sheets", systemImage: "viewfinder").bold().frame(maxWidth: .infinity)
                    }
                    .primaryButton()
                    .controlSize(.large)
                }
                .padding(.vertical, 4)
            }
            if scans.isEmpty {
                Section {
                    if loading {
                        HStack { Spacer(); ProgressView(); Spacer() }.padding()
                    } else if let failed {
                        Text(failed).foregroundStyle(.red)
                    } else {
                        ContentUnavailableView("No scans yet", systemImage: "doc.viewfinder", description: Text("Scan this test's sheets to see stats here."))
                    }
                }
            } else {
                Section { tiles(stats) }
                Section("Grades") { grades(stats) }
                if stats.periods.contains(where: { $0.period != nil }) {
                    Section("By period") {
                        ForEach(stats.periods) { p in
                            HStack {
                                Text(p.period.map { "Period \($0)" } ?? "No period")
                                Text("\(p.count) scanned").font(.subheadline).foregroundStyle(.secondary)
                                Spacer()
                                Text("\(Int(p.average.rounded()))%").bold().monospacedDigit()
                            }
                        }
                    }
                }
                Section("Hardest questions") { questions(stats) }
                ForEach(groups) { group in
                    Section(group.title) {
                        ForEach(group.rows) { record in row(record) }
                    }
                }
            }
        }
        .navigationTitle(quiz.title)
        .refreshable { await load() }
        .task { await load() }
        .sheet(item: $open) { record in
            RecordSheet(quiz: quiz, record: record, others: scans) { Task { await load() } }.environmentObject(store)
        }
    }

    /// Rows the phone left for the teacher that are still waiting (older scans: rows it couldn't call).
    private func waiting(_ record: ScanRecord) -> Bool {
        let rows = record.review != nil ? Review.loaded(record.review) : Review.rows(record.answers, marks: [:], key: quiz.answerKey).rows
        return rows.values.contains { $0.result == nil }
    }

    private func load() async {
        do {
            scans = try await store.scans(for: quiz)
            failed = nil
        } catch {
            failed = "Couldn't load scans. Pull to refresh."
        }
        loading = false
    }

    private var groups: [ResultGroup] {
        Dictionary(grouping: scans, by: \.period)
            .map { ResultGroup(period: $0.key, rows: $0.value.sorted { ($0.studentName ?? "~") < ($1.studentName ?? "~") }) }
            .sorted { ($0.period ?? 99) < ($1.period ?? 99) }
    }

    private func tiles(_ stats: TestStats) -> some View {
        let whole: (Double?) -> String = { $0.map { "\(Int($0.rounded()))" } ?? "–" }
        return LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible())], spacing: 10) {
            tile("Average", stats.average.map { "\(Int($0.rounded()))%" } ?? "–")
            tile("Median", stats.median.map { "\(Int($0.rounded()))%" } ?? "–")
            tile("Scanned", "\(stats.count)")
            tile("High · low", "\(whole(stats.high)) · \(whole(stats.low))")
        }
        .padding(.vertical, 4)
    }

    private func tile(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title2.bold()).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(.tertiarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func grades(_ stats: TestStats) -> some View {
        Chart(stats.grades) { grade in
            BarMark(x: .value("Grade", grade.letter), y: .value("Students", grade.count))
                .foregroundStyle(grade.letter == "D" || grade.letter == "F" ? Color.gray.opacity(0.45) : Brand.sage)
                .cornerRadius(4)
                .annotation(position: .top) {
                    Text("\(grade.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
        }
        .chartYAxis(.hidden)
        .frame(height: 160)
        .padding(.vertical, 8)
    }

    @ViewBuilder private func questions(_ stats: TestStats) -> some View {
        let list = allQuestions ? stats.hardest : Array(stats.hardest.prefix(5))
        ForEach(list) { q in
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Q\(q.number)").bold().monospacedDigit()
                    Text(q.key == "*" ? "any answer" : "answer \(String(q.key))").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text("\(q.percentRight)%").bold().monospacedDigit().foregroundStyle(q.percentRight < 50 ? Brand.warn : Color.primary)
                }
                ProgressView(value: Double(q.percentRight), total: 100).tint(q.percentRight < 50 ? Brand.warn : Brand.sage)
                if let wrong = q.wrong {
                    Text("\(TestStats.wrongLabel(wrong)) (\(q.wrongCount))").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 2)
        }
        if stats.questions.count > 5 {
            Button(allQuestions ? "Show fewer" : "All \(stats.questions.count) questions") {
                withAnimation { allQuestions.toggle() }
            }
        }
    }

    private func row(_ record: ScanRecord) -> some View {
        Button { open = record } label: {
            HStack(spacing: 10) {
                if record.studentId == nil {
                    if let hand = UIImage(dataURL: record.nameImage) {
                        Image(uiImage: hand).resizable().scaledToFit().frame(maxWidth: 140, maxHeight: 28)
                            .background(.white).clipShape(RoundedRectangle(cornerRadius: 6))
                    } else {
                        Text(record.studentName.map { "“\($0)”" } ?? "No name").foregroundStyle(.primary)
                    }
                } else {
                    Text(record.studentName ?? "Student").foregroundStyle(.primary)
                }
                Spacer()
                if record.studentId == nil || record.period == nil || waiting(record) {
                    // Needs a look: the same amber dot as the card and the portal.
                    Circle().fill(Brand.warn).frame(width: 7, height: 7).accessibilityLabel("Needs a look")
                }
                Text(quiz.scoreText(record.answers, override: record.scoreOverride)).monospacedDigit().foregroundStyle(.primary)
            }
        }
    }
}

/// One saved result from a test's page: fix the student, period or rows it couldn't call, or delete it.
struct RecordSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let quiz: Quiz
    @State private var record: ScanRecord
    @State private var rows: [Int: RowReview]
    let others: [ScanRecord]   // the test's other scans, for one scan per student
    let changed: () -> Void
    @State private var confirmDelete = false
    @State private var comparing: (student: Student, other: ScanRecord)?

    init(quiz: Quiz, record: ScanRecord, others: [ScanRecord], changed: @escaping () -> Void) {
        self.quiz = quiz
        self.others = others.filter { $0.id != record.id }
        _record = State(initialValue: record)
        // Rows the phone left for the teacher (with the marks it saw); older scans: every row it couldn't call.
        _rows = State(initialValue: record.review != nil ? Review.loaded(record.review)
                                                         : Review.rows(record.answers, marks: [:], key: quiz.answerKey).rows)
        self.changed = changed
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                ResultCard(data: CardData(quiz: quiz, answers: record.answers, override: record.scoreOverride, period: record.period,
                                          studentId: record.studentId, studentName: record.studentName,
                                          read: record.studentId == nil ? record.studentName : nil,
                                          nameImage: record.nameImage, photoPath: record.photoPath,
                                          suggestion: record.studentId == nil
                                              ? NameMatch.decide(record.studentName, among: store.students, period: record.period).suggest : nil,
                                          rows: rows, layout: record.layout(quiz)),
                           assign: { student in
                               // One scan per student per test: if they already have one, compare the two first.
                               if let student, let other = others.first(where: { $0.studentId == student.id }) {
                                   comparing = (student, other)
                               } else {
                                   take(student)
                               }
                           },
                           setPeriod: { record.period = $0; save() },
                           settle: { q, answer in
                               rows[q]?.result = String(answer)
                               set(q, answer)
                           },
                           undo: { q in
                               guard let flag = rows[q]?.flag.first else { return }
                               rows[q]?.result = nil
                               set(q, flag)
                           })
                .padding()
            }
            .navigationTitle(record.studentName ?? "Scan")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .topBarLeading) {
                    Button("Delete", systemImage: "trash", role: .destructive) { confirmDelete = true }
                }
            }
            .sheet(isPresented: Binding(get: { comparing != nil }, set: { if !$0 { comparing = nil } })) {
                if let pair = comparing {
                    CompareSheet(quiz: quiz, student: pair.student, mine: ScanSide(record), otherId: pair.other.id,
                                 localOther: ScanSide(pair.other)) { keepMine in keep(mine: keepMine, pair.student, pair.other) }
                        .environmentObject(store)
                }
            }
            .confirmationDialog("Delete this scan?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete scan", role: .destructive) {
                    Task {
                        await store.remove(record.id)
                        changed()
                        dismiss()
                    }
                }
            } message: {
                Text("The student's score is removed from this test.")
            }
        }
    }

    private func take(_ student: Student?) {
        record.studentId = student?.id
        if let student { record.studentName = student.name }
        if record.period == nil { record.period = student?.period }
        save()
    }

    /// Two scans for one student: the one the teacher keeps gets the student; the other is deleted.
    private func keep(mine: Bool, _ student: Student, _ other: ScanRecord) {
        Task {
            if mine {
                await store.remove(other.id)
                take(student)
            } else {
                await store.remove(record.id)
                changed()
                dismiss()
            }
        }
    }

    private func set(_ q: Int, _ answer: Character) {
        var chars = Array(record.answers)
        guard q < chars.count else { return }
        chars[q] = answer
        record.answers = String(chars)
        save()
    }

    private func save() {
        let r = record, review = Review.stored(rows) ?? [:], quizId = quiz.id
        Task {
            await store.fix(r.id, studentId: r.studentId, name: r.studentName, period: r.period, answers: r.answers, review: review, quizId: quizId)
            changed()
        }
    }
}
