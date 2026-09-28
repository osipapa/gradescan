import SwiftUI

/// Fixing a test's answer key on the phone, for example after making it from a student's sheet that got one wrong.
/// Scores come from the key, so every scan of the test regrades when it's saved, this batch included.
struct KeyEditView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let quiz: Quiz
    @State private var key: [Character?] = []
    @State private var saving = false

    /// The saved key, one entry per question; "*" (any answer counts) shows as no bubble chosen.
    private var original: [Character?] {
        let saved = Array(quiz.answerKey.uppercased())
        return (0..<quiz.numQuestions).map { $0 < saved.count && saved[$0] != "*" ? saved[$0] : nil }
    }

    private var changed: Int { zip(key, original).filter { $0 != $1 }.count }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Tap the right answer for any question to fix it. Scores update when you save.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Section {
                    ForEach(0..<key.count, id: \.self) { i in
                        HStack(spacing: 10) {
                            Text("\(i + 1)").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary).frame(width: 26, alignment: .trailing)
                            ForEach(0..<quiz.numChoices, id: \.self) { j in
                                let letter = Grader.letters[j]
                                Button(String(letter)) { key[i] = letter }
                                    .buttonStyle(BubbleStyle(on: key[i] == letter))
                            }
                            Spacer()
                            if key[i] != original[i] {
                                Text("was \(original[i].map(String.init) ?? "any")").font(.caption).foregroundStyle(Brand.warn)
                            }
                        }
                    }
                } header: {
                    HStack { Text("Answer key"); Spacer(); if changed > 0 { Text("\(changed) changed") } }
                }
            }
            .navigationTitle(quiz.title)
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { if key.isEmpty { key = original } }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(saving ? "Saving…" : "Save") { save() }.disabled(changed == 0 || saving)
                }
            }
        }
    }

    private func save() {
        saving = true
        let answerKey = String(key.map { $0 ?? "*" })
        Task {
            if await store.updateKey(quiz, key: answerKey) { dismiss() }
            saving = false
        }
    }
}
