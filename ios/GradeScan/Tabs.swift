import SwiftUI

/// Scan, Tests, Students and Settings, one tap apart.
struct MainTabs: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        TabView(selection: $store.tab) {
            ScanScreen().tabItem { Label("Scan", systemImage: "viewfinder") }.tag(AppStore.Tab.scan)
            TestsView().tabItem { Label("Tests", systemImage: "list.bullet.rectangle") }.tag(AppStore.Tab.tests)
            StudentsView().tabItem { Label("Students", systemImage: "person.2") }.tag(AppStore.Tab.students)
            SettingsView().tabItem { Label("Settings", systemImage: "gearshape") }.tag(AppStore.Tab.settings)
        }
    }
}

struct TestsView: View {
    @EnvironmentObject var store: AppStore
    @State private var creating = false

    var body: some View {
        NavigationStack {
            List {
                if store.tests.isEmpty {
                    ContentUnavailableView("No tests yet", systemImage: "doc.text", description: Text("Tap + to create one, then print its sheet from the portal."))
                }
                ForEach(store.tests) { test in
                    NavigationLink(value: test.id) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(test.title).font(.headline)
                            Text(line(test)).font(.subheadline).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
            .navigationTitle("Tests")
            .navigationDestination(for: String.self) { id in
                if let quiz = store.tests.first(where: { $0.id == id }) { TestDetailView(quiz: quiz) }
            }
            .refreshable { await store.reload() }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("New test", systemImage: "plus") { creating = true }
                }
            }
            .sheet(isPresented: $creating) { NewTestView().environmentObject(store) }
        }
    }

    private func line(_ test: Quiz) -> String {
        guard let s = store.summaries[test.id], s.count > 0 else { return "No scans yet" }
        return "\(s.count) scanned" + (s.average.map { " · average \(Int($0.rounded()))%" } ?? "")
    }
}

struct NewTestView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    /// An answer key read from a sheet, filled in to check; `done` hears the new test (nil if cancelled).
    var draft: KeyDraft? = nil
    var done: ((Quiz?) -> Void)? = nil
    @State private var filled = false
    @FocusState private var naming: Bool
    @State private var title = ""
    @State private var questions = 20
    @State private var choices = 4
    @State private var points = 1.0
    @State private var bonus = 0
    @State private var key: [Character?] = Array(repeating: nil, count: 20)
    @State private var saving = false

    var body: some View {
        NavigationStack {
            Form {
                if draft != nil {
                    Section {
                        Text("Read from the answer key sheet. Check the answers, give the test a name, and create it.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                Section {
                    TextField("Name (same as in Jupiter)", text: $title)
                        .focused($naming)
                    Stepper("\(questions) questions", value: $questions, in: 1...50)
                    Picker("Answer choices", selection: $choices) {
                        ForEach(2...5, id: \.self) { Text("A–\(String(Grader.letters[$0 - 1]))").tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Stepper("\(fmt(points)) \(points == 1 ? "point" : "points") each", value: $points, in: 0.25...10, step: 0.25)
                    Stepper(bonus == 0 ? "No bonus questions" : "Last \(bonus) are bonus", value: $bonus, in: 0...max(0, questions - 1))
                }
                Section {
                    ForEach(0..<questions, id: \.self) { i in
                        HStack(spacing: 10) {
                            Text("\(i + 1)").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary).frame(width: 26, alignment: .trailing)
                            ForEach(0..<choices, id: \.self) { j in
                                let letter = Grader.letters[j]
                                Button(String(letter)) { key[i] = key[i] == letter ? nil : letter }
                                    .buttonStyle(BubbleStyle(on: key[i] == letter))
                            }
                            Spacer()
                        }
                    }
                } header: {
                    HStack { Text("Answer key"); Spacer(); Text("\(key.prefix(questions).compactMap { $0 }.count) / \(questions)") }
                }
            }
            .navigationTitle("New test")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                guard let draft, !filled else { return }
                filled = true
                questions = max(1, draft.key.count)
                choices = draft.choices
                key = draft.key + Array(repeating: nil, count: max(0, 20 - draft.key.count))
                naming = true
            }
            .onChange(of: questions) { _, n in key = (0..<n).map { $0 < key.count ? key[$0] : nil } }
            .onChange(of: choices) { _, c in key = key.map { $0.flatMap { Grader.letters.prefix(c).contains($0) ? $0 : nil } } }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        done?(nil)
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "Saving…" : "Create") { save() }.disabled(!ready || saving)
                }
            }
        }
    }

    private var ready: Bool {
        !title.trimmingCharacters(in: .whitespaces).isEmpty && key.prefix(questions).allSatisfy { $0 != nil } && bonus < questions
    }

    private func save() {
        saving = true
        let answerKey = String(key.prefix(questions).compactMap { $0 })
        Task {
            if let quiz = await store.createTest(title: title.trimmingCharacters(in: .whitespaces), questions: questions, choices: choices,
                                                 key: answerKey, points: points, bonus: bonus) {
                done?(quiz)
                dismiss()
            }
            saving = false
        }
    }
}

/// A round answer bubble, filled in sage when chosen.
struct BubbleStyle: ButtonStyle {
    let on: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .frame(width: 34, height: 34)
            .foregroundStyle(on ? Brand.onSage : .secondary)
            .background(Circle().fill(on ? Brand.sage : .clear))
            .overlay(Circle().strokeBorder(on ? Brand.sage : Color.secondary.opacity(0.4), lineWidth: 1.5))
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
