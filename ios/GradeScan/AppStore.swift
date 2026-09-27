import AVFoundation
import SwiftUI
import UIKit

@MainActor
final class AppStore: ObservableObject {
    @Published var session: Session?
    @Published var status = "Point the camera at an answer sheet"
    @Published var detail = ""
    @Published var sent = 0
    @Published var pending: [ScanUpload] = []
    @Published var problem: String?

    let scanner = Scanner()
    let preview = PreviewView()

    private var quizzes: [String: Quiz] = [:]
    private var names: [String: String] = [:]
    private var candidate = ""
    private var streak = 0
    private var lastSaved = ""
    private var sending = false
    private let voice = AVSpeechSynthesizer()

    /// Identical reads in a row before a sheet is accepted (filters motion blur and hands).
    private let framesToAccept = 5

    init() {
        session = Keychain.get("session").flatMap { try? JSONDecoder().decode(Session.self, from: $0) }
        pending = UserDefaults.standard.data(forKey: "pending").flatMap { try? API.decoder.decode([ScanUpload].self, from: $0) } ?? []
        preview.previewLayer.session = scanner.session
        try? AVAudioSession.sharedInstance().setCategory(.playback, options: .duckOthers)
        scanner.onEvent = { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
    }

    // MARK: Account

    func signIn(email: String, password: String, passphrase: String) async {
        problem = nil
        do {
            let s = try await API.signIn(email: email.trimmingCharacters(in: .whitespaces), password: password)
            Keychain.set("nameKey", passphrase.isEmpty ? nil : NameCrypto.deriveKey(passphrase, userId: s.userId))
            Keychain.set("session", try? JSONEncoder().encode(s))
            session = s
        } catch {
            problem = error.localizedDescription
        }
    }

    func signOut() {
        session = nil
        Keychain.set("session", nil)
        Keychain.set("nameKey", nil)
        quizzes = [:]
        names = [:]
        scanner.setQuizzes([:])
    }

    private func validToken() async throws -> String {
        guard var s = session else { throw APIError(status: 401, message: "Signed out") }
        if s.expiresAt < Date().addingTimeInterval(60) {
            do {
                s = try await API.refresh(s.refreshToken)
            } catch let e as APIError where (400..<500).contains(e.status) {
                signOut()
                throw e
            }
            session = s
            Keychain.set("session", try? JSONEncoder().encode(s))
        }
        return s.accessToken
    }

    // MARK: Data

    func reload() async {
        do {
            let token = try await validToken()
            let list = try await API.quizzes(token)
            quizzes = Dictionary(list.map { ($0.code, $0) }, uniquingKeysWith: { first, _ in first })
            scanner.setQuizzes(quizzes)
            names = [:]
            var note = ""
            if let key = Keychain.get("nameKey") {
                let rows = try await API.students(token)
                for row in rows { names[row.code] = NameCrypto.decrypt(row.nameEnc, key) }
                if !rows.isEmpty && names.isEmpty { note = "Roster passphrase doesn't match — showing Student # only." }
            }
            show("\(quizzes.count) quizzes loaded — point at a sheet", note)
            await send()
        } catch {
            problem = error.localizedDescription
        }
    }

    func send() async {
        guard !sending, session != nil else { return }
        sending = true
        defer { sending = false }
        problem = nil
        while let next = pending.first {
            do {
                let token = try await validToken()
                try await API.upsert(next, token)
            } catch {
                problem = "Not sent yet: \(error.localizedDescription) Tap ⋯ › Retry sending."
                return
            }
            pending.removeFirst()
            sent += 1
            savePending()
        }
    }

    private func savePending() {
        UserDefaults.standard.set(try? API.encoder.encode(pending), forKey: "pending")
    }

    // MARK: Scanning

    private func handle(_ event: ScanEvent) {
        switch event {
        case .nothing:
            streak = 0
            preview.draw([], nil)
        case .cameraDenied:
            show("Camera access is off", "Turn it on in Settings › GradeScan › Camera.")
        case .unknownQuiz(let code):
            streak = 0
            preview.draw([], nil)
            show("Quiz \(code) isn't loaded", "Create it in the portal, then tap ⋯ › Reload.")
        case .sheet(let quiz, let student, let answers, let map):
            preview.draw(Grader.marks(quiz, answers), map)
            let key = "\(quiz.code)|\(student ?? "?")|\(answers)"
            if key == candidate { streak += 1 } else { candidate = key; streak = 1 }
            guard streak == framesToAccept, key != lastSaved else { return }
            lastSaved = key
            accept(quiz, student, answers)
        }
    }

    private func accept(_ quiz: Quiz, _ student: String?, _ answers: String) {
        let g = Grader.grade(quiz, answers)
        let who = student.map { names[$0] ?? "Student #\($0)" } ?? "Student # unreadable (fix it in the portal)"
        show("\(who): \(fmt(g.score))/\(fmt(g.max))",
             g.missed.isEmpty ? "No misses" : "Missed " + g.missed.map(String.init).joined(separator: ", "))
        voice.speak(AVSpeechUtterance(string: "\(fmt(g.score)) out of \(fmt(g.max))"))
        UINotificationFeedbackGenerator().notificationOccurred(student == nil ? .warning : .success)
        // An unreadable Student # is saved as "?XX" so scanning never stops; she fixes it in the portal.
        let code = student ?? "?" + String((0..<2).map { _ in "ABCDEFGHJKMNPQRSTUVWXYZ23456789".randomElement()! })
        pending.append(ScanUpload(quizId: quiz.id, studentCode: code, answers: answers, scannedAt: Date()))
        savePending()
        Task { await send() }
    }

    private func show(_ newStatus: String, _ newDetail: String) {
        if status != newStatus { status = newStatus }
        if detail != newDetail { detail = newDetail }
    }
}
