import SwiftUI

/// The class list by period, like the portal's Students page. Each student opens their results across tests.
struct StudentsView: View {
    @EnvironmentObject var store: AppStore
    @State private var filter: Int? = nil   // a period; nil shows every period
    @State private var search = ""
    @State private var adding = false
    @State private var importing = false
    @State private var removing: Student?

    private struct Group: Identifiable {
        let period: Int?
        let students: [Student]
        var id: Int { period ?? 0 }
        var title: String { period.map { "Period \($0)" } ?? "No period" }
    }

    var body: some View {
        NavigationStack {
            List {
                if !periods.isEmpty {
                    // The periods as chips, like the portal's period tabs.
                    ScrollView(.horizontal) {
                        HStack(spacing: 8) {
                            chip("All", count: store.students.count, on: filter == nil) { filter = nil }
                            ForEach(periods, id: \.self) { p in
                                chip("Period \(p)", count: store.students.filter { $0.period == p }.count, on: filter == p) { filter = p }
                            }
                        }
                        .padding(.horizontal, 20)
                    }
                    .scrollIndicators(.hidden)
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
                if store.students.isEmpty {
                    ContentUnavailableView {
                        Label("No students yet", systemImage: "person.2")
                    } description: {
                        Text("Take a photo of a class page in Jupiter, or add names one by one.")
                    } actions: {
                        Button("Import from Jupiter") { importing = true }.buttonStyle(.bordered)
                    }
                }
                ForEach(groups) { group in
                    Section {
                        ForEach(group.students) { student in
                            NavigationLink(value: student.id) { row(student) }
                                .swipeActions {
                                    Button("Remove", systemImage: "trash", role: .destructive) { removing = student }
                                }
                        }
                    } header: {
                        HStack {
                            Text(group.title)
                            Spacer()
                            Text("\(group.students.count)").monospacedDigit()
                        }
                    }
                }
            }
            .onChange(of: periods) { _, list in if let f = filter, !list.contains(f) { filter = nil } }
            .navigationTitle("Students")
            .searchable(text: $search, prompt: "Search")
            .navigationDestination(for: String.self) { id in StudentDetailView(studentId: id) }
            .refreshable { await store.reload() }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("Add a student", systemImage: "person.badge.plus") { adding = true }
                        Button("Import from Jupiter", systemImage: "camera.viewfinder") { importing = true }
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                }
            }
            .sheet(isPresented: $adding) { StudentForm().environmentObject(store) }
            .fullScreenCover(isPresented: $importing) { RosterScanView().environmentObject(store) }
            .confirmationDialog("Remove \(removing?.name ?? "")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                                titleVisibility: .visible) {
                Button("Remove", role: .destructive) {
                    if let student = removing { Task { await store.removeStudent(student) } }
                }
            } message: {
                Text("Their scans stay, without a name.")
            }
        }
    }

    private func chip(_ title: String, count: Int, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title)
                Text("\(count)").monospacedDigit().opacity(0.6)
            }
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .foregroundStyle(on ? Brand.onSage : Color.primary)
            .background(on ? Brand.sage : Color(.secondarySystemGroupedBackground), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func row(_ student: Student) -> some View {
        HStack {
            Text(student.name)
            Spacer()
            if let average = store.studentSummaries[student.id]?.average {
                Text("\(Int(average.rounded()))%").monospacedDigit().foregroundStyle(.secondary)
            }
        }
    }

    private var periods: [Int] { Set(store.students.compactMap(\.period)).sorted() }

    private var groups: [Group] {
        let term = search.trimmingCharacters(in: .whitespaces).lowercased()
        let shown = store.students.filter { student in
            (filter == nil || student.period == filter) && (term.isEmpty || student.name.lowercased().contains(term))
        }
        return Dictionary(grouping: shown, by: \.period)
            .map { Group(period: $0.key, students: $0.value.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }) }
            .sorted { ($0.period ?? 99) < ($1.period ?? 99) }
    }
}

/// One student across tests: each score, and the topics they miss most (weakest first), like the portal.
/// The name and period are edited right here and saved as they change.
struct StudentDetailView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let studentId: String
    @State private var scans: [ScanRecord] = []
    @State private var loading = true
    @State private var failed = false
    @State private var name = ""
    @State private var period: Int?
    @State private var ready = false        // name and period filled in from the class list
    @State private var saveFailed = false
    @State private var saving: Task<Void, Never>?
    @State private var confirmRemove = false
    @State private var open: ScanRecord?
    @FocusState private var editingName: Bool

    private struct Result: Identifiable {
        let quiz: Quiz
        let record: ScanRecord
        var id: String { record.id }
    }

    private struct Topic: Identifiable {
        let name: String
        let right: Int
        let total: Int
        var percent: Int { total > 0 ? Int((Double(right) / Double(total) * 100).rounded()) : 0 }
        var id: String { name }
    }

    private var student: Student? { store.students.first { $0.id == studentId } }

    var body: some View {
        List {
            Section {
                TextField("Name", text: $name)
                    .font(.title3.weight(.semibold))
                    .textContentType(.name)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .focused($editingName)
                    .onSubmit { save(now: true) }
                Picker("Period", selection: $period) {
                    Text("None").tag(Int?.none)
                    ForEach(1...9, id: \.self) { Text("Period \($0)").tag(Optional($0)) }
                }
            } footer: {
                Text(saveFailed ? "Couldn't save. Check the connection; it saves when you change it again." : summary)
                    .foregroundStyle(saveFailed ? Color.red : Color.secondary)
            }
            Section("Tests") {
                if results.isEmpty {
                    if loading {
                        HStack { Spacer(); ProgressView(); Spacer() }
                    } else {
                        Text(failed ? "Couldn't load scores. Pull to refresh." : "Scores show up here once their sheets are scanned.")
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(results) { result in
                    Button { open = result.record } label: { row(result) }
                        .foregroundStyle(.primary)
                }
            }
            Section {
                if topics.isEmpty {
                    Text("Tag each question with a topic on the test's page in the portal to see topics here.")
                        .foregroundStyle(.secondary)
                }
                ForEach(topics) { topic in
                    HStack(spacing: 12) {
                        Text(topic.name)
                        Spacer()
                        ProgressView(value: Double(topic.percent), total: 100).tint(Brand.sage).frame(width: 80)
                        Text("\(topic.percent)%").monospacedDigit().frame(width: 44, alignment: .trailing)
                    }
                }
            } header: {
                Text("Topics")
            } footer: {
                if !topics.isEmpty { Text("Weakest first.") }
            }
            Section {
                Button("Remove from class list", role: .destructive) { confirmRemove = true }
            }
        }
        .navigationTitle(name.isEmpty ? "Student" : name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
        .onAppear {
            guard !ready, let student else { return }
            name = student.name
            period = student.period
            ready = true
        }
        .onChange(of: name) { _, _ in save(now: false) }
        .onChange(of: period) { _, _ in save(now: true) }
        .onChange(of: editingName) { _, editing in if !editing { save(now: true) } }
        .onDisappear { save(now: true) }
        .sheet(item: $open) { record in
            if let quiz = store.tests.first(where: { $0.id == record.quizId }) {
                RecordSheet(quiz: quiz, record: record, others: []) { Task { await load() } }.environmentObject(store)
            }
        }
        .confirmationDialog("Remove \(student?.name ?? "this student")?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                guard let student else { return }
                saving?.cancel()
                Task {
                    await store.removeStudent(student)
                    dismiss()
                }
            }
        } message: {
            Text("Their scans stay, without a name.")
        }
    }

    /// Saves the name and period if they changed: right away, or a moment after typing stops.
    private func save(now: Bool) {
        guard ready else { return }
        saving?.cancel()
        saving = Task {
            if !now {
                try? await Task.sleep(for: .milliseconds(700))
                if Task.isCancelled { return }
            }
            guard let student, !name.trimmingCharacters(in: .whitespaces).isEmpty,
                  name.trimmingCharacters(in: .whitespaces) != student.name || period != student.period else { return }
            saveFailed = !(await store.updateStudent(student, name: name, period: period))
        }
    }

    private func load() async {
        do {
            scans = try await store.scans(forStudent: studentId)
            failed = false
        } catch {
            failed = true
        }
        loading = false
    }

    private var results: [Result] {
        let byId = Dictionary(store.tests.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return scans.compactMap { record in byId[record.quizId].map { Result(quiz: $0, record: record) } }
    }

    private var topics: [Topic] {
        var tally: [String: (right: Int, total: Int)] = [:]
        for result in results {
            let key = Array(result.quiz.answerKey.uppercased()), given = Array(result.record.answers)
            for i in 0..<result.quiz.numQuestions {
                guard let topic = result.quiz.topic(i), i < key.count else { continue }
                let right = key[i] == "*" || (i < given.count && given[i] == key[i])
                tally[topic, default: (0, 0)].total += 1
                if right { tally[topic, default: (0, 0)].right += 1 }
            }
        }
        return tally.map { Topic(name: $0.key, right: $0.value.right, total: $0.value.total) }
            .sorted { $0.percent < $1.percent || ($0.percent == $1.percent && $0.name < $1.name) }
    }

    private var summary: String {
        let percents = results.compactMap { $0.quiz.percent($0.record.answers, override: $0.record.scoreOverride) }
        var parts = ["\(percents.count) \(percents.count == 1 ? "test" : "tests")"]
        if !percents.isEmpty { parts.append("average \(Int((Double(percents.reduce(0, +)) / Double(percents.count)).rounded()))%") }
        return parts.joined(separator: " · ")
    }

    private func row(_ result: Result) -> some View {
        let quiz = result.quiz, record = result.record
        return HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(quiz.title)
                Text(record.takenOn.map { "Taken \($0)" } ?? record.scannedAt.formatted(.dateTime.month(.abbreviated).day()))
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(quiz.scoreText(record.answers, override: record.scoreOverride)).bold().monospacedDigit()
                if let percent = quiz.percent(record.answers, override: record.scoreOverride) {
                    Text("\(percent)%").font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
                }
            }
        }
        .contentShape(Rectangle())
    }
}

/// Adds a student to the class list.
struct StudentForm: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var period: Int?
    @State private var saving = false

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
                    .textContentType(.name)
                    .autocorrectionDisabled()
                Picker("Period", selection: $period) {
                    Text("None").tag(Int?.none)
                    ForEach(1...9, id: \.self) { Text("Period \($0)").tag(Optional($0)) }
                }
            }
            .navigationTitle("Add a student")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        saving = true
                        Task {
                            _ = await store.addStudents([(name: name.trimmingCharacters(in: .whitespaces), period: period)])
                            dismiss()
                        }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || saving)
                }
            }
        }
        .presentationDetents([.medium])
    }
}
