import Combine
import SwiftUI
import UIKit

/// Account, tests, the class list, and the upload queue. Scanning itself lives in `ScanSession`.
@MainActor
final class AppStore: ObservableObject {
    enum Tab: Hashable { case scan, tests, students, settings }

    @Published var session: Session?
    @Published var tests: [Quiz] = []
    @Published var loaded = false
    @Published var students: [Student] = []   // the class list, for matching names; managed in the portal
    @Published var summaries: [String: TestSummary] = [:]   // by test id
    @Published var studentSummaries: [String: TestSummary] = [:]   // by student id: tests scanned and average percent
    @Published var pending: [ScanUpload] = []
    @Published var problem: String?
    @Published var tab: Tab = .scan

    /// Local photos still shown on the phone; the upload queue keeps them after uploading.
    var keepPhotos: Set<String> = []
    /// Scans saved without their student because the student already had a scan for the test: scan id → the other scan.
    @Published var conflicts: [String: String] = [:]

    struct TestSummary {
        let count: Int
        let average: Double?
    }

    private var sending = false
    private var deleted: Set<String> = []    // removed while their upload was in flight

    init() {
        session = Keychain.get("session").flatMap { try? JSONDecoder().decode(Session.self, from: $0) }
        Keychain.set("nameKey", nil)   // left over from the roster passphrase in earlier versions
        pending = UserDefaults.standard.data(forKey: "pending").flatMap { try? API.decoder.decode([ScanUpload].self, from: $0) } ?? []
    }

    // MARK: Account

    func signIn(email: String, password: String) async {
        problem = nil
        do {
            var s = try await API.signIn(email: email.trimmingCharacters(in: .whitespaces), password: password)
            s.email = email.trimmingCharacters(in: .whitespaces)
            Keychain.set("session", try? JSONEncoder().encode(s))
            session = s
        } catch {
            problem = error.localizedDescription
        }
    }

    func signOut() {
        session = nil
        tab = .scan
        Keychain.set("session", nil)
        tests = []
        students = []
        summaries = [:]
        studentSummaries = [:]
    }

    private func validToken() async throws -> String {
        guard var s = session else { throw APIError(status: 401, message: "Signed out") }
        if s.expiresAt < Date().addingTimeInterval(60) {
            do {
                let email = s.email
                s = try await API.refresh(s.refreshToken)
                s.email = email
            } catch let e as APIError where (400..<500).contains(e.status) {
                signOut()
                throw e
            }
            session = s
            Keychain.set("session", try? JSONEncoder().encode(s))
        }
        return s.accessToken
    }

    // MARK: Tests

    func reload() async {
        problem = nil
        do {
            let token = try await validToken()
            tests = try await API.tests(token).filter(\.scannable)
            loaded = true
            students = try await API.students(token)
            await loadSummaries()
            await send()
        } catch {
            problem = error.localizedDescription
        }
    }

    /// Scanned count and average for each test (the Tests list) and each student (the Students list).
    func loadSummaries() async {
        guard let token = try? await validToken(), let rows = try? await API.scanSummaries(token) else { return }
        var out: [String: TestSummary] = [:]
        for (quizId, scans) in Dictionary(grouping: rows, by: \.quizId) {
            guard let quiz = tests.first(where: { $0.id == quizId }) else { continue }
            let stats = TestStats(quiz: quiz, sheets: scans.map { ScoredSheet(answers: $0.answers, period: nil, override: $0.scoreOverride) })
            out[quizId] = TestSummary(count: stats.count, average: stats.average)
        }
        summaries = out
        let byTest = Dictionary(tests.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var perStudent: [String: TestSummary] = [:]
        for (studentId, scans) in Dictionary(grouping: rows.filter { $0.studentId != nil }, by: { $0.studentId ?? "" }) {
            let percents = scans.compactMap { row in byTest[row.quizId].flatMap { $0.percent(row.answers, override: row.scoreOverride) } }
            perStudent[studentId] = TestSummary(count: percents.count,
                                                average: percents.isEmpty ? nil : Double(percents.reduce(0, +)) / Double(percents.count))
        }
        studentSummaries = perStudent
    }

    /// Creates a test; returns it, or nil if it couldn't be saved.
    func createTest(title: String, questions: Int, choices: Int, key: String, points: Double, bonus: Int) async -> Quiz? {
        do {
            let token = try await validToken()
            let used = Set(tests.compactMap(\.sheetCode))
            let code = (1...4095).filter { !used.contains($0) }.randomElement() ?? 1
            let quiz = try await API.createTest(title: title, questions: questions, choices: choices, key: key,
                                                points: points, bonus: bonus, code: code, token)
            tests.insert(quiz, at: 0)
            return quiz
        } catch {
            problem = error.localizedDescription
            return nil
        }
    }

    /// A test's scans from the server, plus any still waiting to upload.
    func scans(for quiz: Quiz) async throws -> [ScanRecord] {
        let token = try await validToken()
        let server = try await API.scans(quiz.id, token)
        let local = pending.filter { $0.quizId == quiz.id && !server.map(\.id).contains($0.id) }.map(ScanRecord.init)
        return local + server
    }

    /// A student's scans across tests, newest first.
    func scans(forStudent id: String) async throws -> [ScanRecord] {
        let token = try await validToken()
        let server = try await API.scans(studentId: id, token)
        let local = pending.filter { $0.studentId == id && !server.map(\.id).contains($0.id) }.map(ScanRecord.init)
        return local + server
    }

    /// One saved scan (the other half of a comparison).
    func record(_ id: String) async -> ScanRecord? {
        guard let token = try? await validToken() else { return nil }
        return try? await API.scan(id, token)
    }

    /// A marked sheet photo from storage.
    func photo(_ path: String) async -> UIImage? {
        guard let token = try? await validToken(), let data = try? await API.photo(path, token) else { return nil }
        return UIImage(data: data)
    }

    /// Keeps the app current on its own: retries uploads every half minute while any are waiting.
    func keepSending() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(30))
            if !pending.isEmpty { await send() }
        }
    }

    // MARK: Class list

    /// Adds students (skipping anyone already on the list for that period). Returns how many were added.
    func addStudents(_ list: [(name: String, period: Int?)]) async -> Int {
        await importStudents(list)?.count ?? 0
    }

    /// Adds students, skipping anyone already on the list for that period. Returns those added, or nil if it failed.
    func importStudents(_ list: [(name: String, period: Int?)]) async -> [Student]? {
        let key: (String, Int?) -> String = { NameMatch.tokens($0).sorted().joined(separator: " ") + "|\($1 ?? 0)" }
        let known = Set(students.map { key($0.name, $0.period) })
        var seen = Set<String>()
        let new = list.filter { !known.contains(key($0.name, $0.period)) && seen.insert(key($0.name, $0.period)).inserted }
        guard !new.isEmpty else { return [] }
        do {
            let added = try await API.addStudents(new, try await validToken())
            students = (students + added).sorted { $0.name < $1.name }
            return added
        } catch {
            problem = error.localizedDescription
            return nil
        }
    }

    /// Takes back students just added (Undo after an import).
    func removeStudents(_ list: [Student]) async -> Bool {
        do {
            try await API.deleteStudents(list.map(\.id), try await validToken())
            let ids = Set(list.map(\.id))
            students.removeAll { ids.contains($0.id) }
            return true
        } catch {
            problem = "Couldn't undo: \(error.localizedDescription)"
            return false
        }
    }

    /// Saves a student's name and period. Returns whether it saved.
    @discardableResult
    func updateStudent(_ student: Student, name: String, period: Int?) async -> Bool {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return false }
        do {
            try await API.updateStudent(student.id, name: name, period: period, try await validToken())
            if let i = students.firstIndex(where: { $0.id == student.id }) {
                students[i] = Student(id: student.id, name: name, period: period, number: student.number)
                students.sort { $0.name < $1.name }
            }
            return true
        } catch {
            problem = "Couldn't save: \(error.localizedDescription)"
            return false
        }
    }

    /// Takes a student off the class list. Their scans stay, without the student.
    func removeStudent(_ student: Student) async {
        do {
            try await API.deleteStudent(student.id, try await validToken())
            students.removeAll { $0.id == student.id }
            studentSummaries[student.id] = nil
        } catch {
            problem = "Couldn't remove: \(error.localizedDescription)"
        }
    }

    // TESTING ONLY — remove before production (with API.wipeEverything and the Testing section in SettingsView).
    /// Deletes everything on this account: scans, students, tests and sheet photos, and anything waiting to upload.
    func wipeEverything() async -> Bool {
        do {
            guard let user = session?.userId else { return false }
            pending.forEach { if let file = $0.localPhoto { Photos.remove(file) } }
            pending = []
            savePending()
            try await API.wipeEverything(userId: user, try await validToken())
            tests = []
            students = []
            summaries = [:]
            studentSummaries = [:]
            conflicts = [:]
            return true
        } catch {
            problem = "Couldn't delete everything: \(error.localizedDescription)"
            return false
        }
    }

    // MARK: Uploads

    func enqueue(_ upload: ScanUpload) {
        pending.append(upload)
        savePending()
        Task { await send() }
    }

    func send() async {
        guard !sending, session != nil else { return }
        sending = true
        defer { sending = false }
        while var next = pending.first {
            do {
                let token = try await validToken()
                if next.photoPath == nil, let file = next.localPhoto, let data = Photos.load(file), let user = session?.userId {
                    let path = "\(user)/\(next.id).clean.jpg"   // no marks on it: the apps draw them
                    try await API.uploadPhoto(path, data, token)
                    next.photoPath = path
                    if let i = pending.firstIndex(where: { $0.id == next.id }) { pending[i].photoPath = path; savePending() }
                }
                do {
                    try await API.insert(next, token)
                } catch let e as APIError where e.status == 409 && next.studentId != nil {
                    // The student already has a scan for this test. Save this one without the student; the teacher compares.
                    let other = try await API.scanId(quizId: next.quizId, studentId: next.studentId ?? "", token)
                    next.studentId = nil
                    try await API.insert(next, token)
                    if let i = pending.firstIndex(where: { $0.id == next.id }) { pending[i].studentId = nil; savePending() }
                    if let other { conflicts[next.id] = other }
                }
                if let file = next.localPhoto, !keepPhotos.contains(file) { Photos.remove(file) }
                // Fixed or removed while it was uploading: apply that now.
                if deleted.remove(next.id) != nil {
                    try await API.delete(next.id, token)
                } else if let now = pending.first(where: { $0.id == next.id }),
                          now.studentId != next.studentId || now.studentName != next.studentName || now.period != next.period
                            || now.answers != next.answers || now.review != next.review {
                    try await API.update(next.id, ScanPatch(studentId: now.studentId, studentName: now.studentName, period: now.period,
                                                            answers: now.answers, review: now.review), token)
                }
            } catch {
                problem = "Not uploaded yet: \(error.localizedDescription)"
                return
            }
            pending.removeAll { $0.id == next.id }
            savePending()
        }
        problem = nil
        await loadSummaries()
    }

    /// Removes a scan, from the queue or from the server.
    func remove(_ id: String) async {
        if let i = pending.firstIndex(where: { $0.id == id }) {
            if sending && i == 0 { deleted.insert(id) } else { pending.remove(at: i); savePending() }
            return
        }
        do {
            try await API.delete(id, try await validToken())
            await loadSummaries()
        } catch {
            problem = "Couldn't delete: \(error.localizedDescription)"
        }
    }

    /// Saves a fix to a scan: in the queue if it hasn't uploaded yet, otherwise on the server.
    /// If the student already has another scan for the test (`quizId`), the fix is saved without the student and the
    /// pair is reported in `conflicts`, for the teacher to compare.
    func fix(_ id: String, studentId: String?, name: String?, period: Int?, answers: String? = nil, review: [String: RowReview]? = nil,
             quizId: String? = nil) async {
        let name = name?.trimmingCharacters(in: .whitespaces).nilIfEmpty
        if let i = pending.firstIndex(where: { $0.id == id }) {
            pending[i].studentId = studentId
            pending[i].studentName = name
            pending[i].period = period
            if let answers { pending[i].answers = answers }
            if let review { pending[i].review = review }
            savePending()
            return
        }
        do {
            let token = try await validToken()
            do {
                try await API.update(id, ScanPatch(studentId: studentId, studentName: name, period: period, answers: answers, review: review), token)
            } catch let e as APIError where e.status == 409 && studentId != nil && quizId != nil {
                try await API.update(id, ScanPatch(studentId: nil, studentName: name, period: period, answers: answers, review: review), token)
                if let other = try await API.scanId(quizId: quizId ?? "", studentId: studentId ?? "", token) { conflicts[id] = other }
            }
            await loadSummaries()
        } catch {
            problem = "Couldn't save the fix: \(error.localizedDescription)"
        }
    }

    private func savePending() {
        UserDefaults.standard.set(try? API.encoder.encode(pending), forKey: "pending")
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

extension UIImage {
    /// A picture from a data URL such as the handwritten name stored with each scan.
    convenience init?(dataURL: String?) {
        guard let url = dataURL, let comma = url.firstIndex(of: ","),
              let data = Data(base64Encoded: String(url[url.index(after: comma)...])) else { return nil }
        self.init(data: data)
    }
}
