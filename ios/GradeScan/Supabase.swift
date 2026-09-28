import Foundation
import Security

// Paste the same values as in portal/index.html (Supabase → Project Settings → API).
enum Config {
    static let supabaseURL = "https://rxpfbifdwnjwvfyxbtyy.supabase.co"
    static let supabaseKey = "sb_publishable_gG2malUV5jX565KBfF7w_g_VREOHTNJ"
}

struct Session: Codable, Sendable {
    var accessToken: String
    var refreshToken: String
    var userId: String
    var expiresAt: Date
    var email: String?

    /// The account's email: saved at sign-in, or read from the access token (sessions from earlier versions didn't save it).
    var accountEmail: String? {
        if let email, !email.isEmpty { return email }
        let parts = accessToken.split(separator: ".")
        guard parts.count > 1 else { return nil }
        var payload = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload += "=" }
        guard let data = Data(base64Encoded: payload),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return claims["email"] as? String
    }
}

/// A test as created in the portal. `layout` says where everything is printed on its answer sheet.
struct Quiz: Codable, Identifiable, Sendable {
    let id: String
    let title: String
    let numQuestions: Int
    let numChoices: Int
    let answerKey: String
    let pointsPerQuestion: Double
    let bonusCount: Int
    let layout: SheetLayout?
    let code: String?
    var questionTags: [String]? = nil   // one topic per question, set in the portal; "" = none

    /// Question i's topic, if it has one.
    func topic(_ i: Int) -> String? { questionTags.flatMap { $0.indices.contains(i) && !$0[i].isEmpty ? $0[i] : nil } }

    /// The number printed on this test's sheets, which is how the phone recognizes them.
    var sheetCode: Int? { code.flatMap { Int($0) }.flatMap { (1...4095).contains($0) ? $0 : nil } }

    /// Tests whose sheet the phone can read.
    var scannable: Bool { sheetCode != nil && layout?.fits(questions: numQuestions, choices: numChoices) == true }
}

/// A student on the class list.
struct Student: Codable, Identifiable, Sendable, Hashable {
    let id: String
    let name: String
    let period: Int?
    let number: Int?   // printed on the student's named sheets
}

struct ScanUpload: Codable, Sendable, Identifiable {
    var id = UUID().uuidString.lowercased()   // made on the phone, so a scan can be fixed or undone right away
    let quizId: String
    var studentId: String?
    var period: Int?
    var studentName: String?   // read from the handwriting; can be corrected on the phone or in the portal
    let nameImage: String?     // JPEG data URL of the handwritten name
    var sheetImage: String?    // older builds: JPEG data URL of the marked sheet (now stored as a file, see photoPath)
    var photoPath: String?     // the marked full-resolution photo in the "sheets" storage bucket
    var localPhoto: String?    // that photo on the phone until it's uploaded (never sent to the table)
    var answers: String
    let scannedAt: Date
    var review: [String: RowReview]?   // rows waiting for (or settled by) the teacher, by question index
    var form: String?          // the sheet it was read from: nil = the test's own sheet, "zipgrade20" = ZipGrade's form
    var takenOn: String?       // the date the student wrote on the sheet, as read
}

/// Fields the teacher can fix after a scan.
struct ScanPatch: Encodable {
    let studentId: String?
    let studentName: String?
    let period: Int?
    var answers: String? = nil
    var review: [String: RowReview]? = nil

    func encode(to encoder: Encoder) throws {   // send nulls too, so clearing a field works
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(studentId, forKey: .studentId)
        try c.encode(studentName, forKey: .studentName)
        try c.encode(period, forKey: .period)
        if let answers { try c.encode(answers, forKey: .answers) }
        if let review { try c.encode(review, forKey: .review) }
    }
    enum CodingKeys: String, CodingKey { case studentId, studentName, period, answers, review }
}

/// A saved scan as the server has it (for a test's stats and results).
struct ScanRecord: Codable, Identifiable, Sendable, Equatable {
    let id: String
    let quizId: String
    var period: Int?
    var studentId: String?
    var studentName: String?
    let nameImage: String?
    var answers: String
    let scoreOverride: Double?
    let scannedAt: Date
    let photoPath: String?
    var review: [String: RowReview]?
    var form: String?
    var takenOn: String?

    /// Where the photo's bubbles are: ZipGrade's form, or the test's own sheet.
    func layout(_ quiz: Quiz) -> SheetLayout? { form == SheetKind.zipgrade20.rawValue ? ZipGrade.form20 : quiz.layout }
}

extension ScanRecord {
    /// A scan still waiting to upload.
    init(_ upload: ScanUpload) {
        self.init(id: upload.id, quizId: upload.quizId, period: upload.period, studentId: upload.studentId, studentName: upload.studentName,
                  nameImage: upload.nameImage, answers: upload.answers, scoreOverride: nil, scannedAt: upload.scannedAt, photoPath: upload.photoPath,
                  review: upload.review, form: upload.form, takenOn: upload.takenOn)
    }
}

/// Just enough of every scan to show each test's and each student's count and average.
struct ScanSummaryRow: Codable, Sendable {
    let quizId: String
    let studentId: String?
    let answers: String
    let scoreOverride: Double?
}

struct APIError: LocalizedError {
    let status: Int
    let message: String
    var errorDescription: String? { message }
}

/// Minimal Supabase REST client: sign in, read tests and scans, save scans.
enum API {
    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        d.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            guard let date = parseDate(text) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Bad date \(text)"))
            }
            return date
        }
        return d
    }()

    private static let withFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// ISO 8601 with or without fractional seconds. Postgres sends microseconds; the formatter wants milliseconds.
    static func parseDate(_ text: String) -> Date? {
        var t = text
        if let dot = t.firstIndex(of: "."), let end = t[dot...].firstIndex(where: { $0 == "+" || $0 == "-" || $0 == "Z" }) {
            let digits = String(t[t.index(after: dot)..<end].prefix(3))
            t.replaceSubrange(t.index(after: dot)..<end, with: digits.padding(toLength: 3, withPad: "0", startingAt: 0))
        }
        return withFraction.date(from: t) ?? plain.date(from: t)
    }

    private struct AuthResponse: Decodable {
        struct User: Decodable { let id: String }
        let accessToken: String
        let refreshToken: String
        let expiresIn: Double
        let user: User
    }

    static func signIn(email: String, password: String) async throws -> Session {
        try await auth("password", ["email": email, "password": password])
    }

    static func refresh(_ refreshToken: String) async throws -> Session {
        try await auth("refresh_token", ["refresh_token": refreshToken])
    }

    /// Newest first.
    static func tests(_ token: String) async throws -> [Quiz] {
        let data = try await request("/rest/v1/quizzes?select=id,title,num_questions,num_choices,answer_key,points_per_question,bonus_count,layout,code,question_tags&order=created_at.desc", token: token)
        return try decoder.decode([Quiz].self, from: data)
    }

    static func students(_ token: String) async throws -> [Student] {
        let data = try await request("/rest/v1/students?select=id,name,period,number&order=name", token: token)
        return try decoder.decode([Student].self, from: data)
    }

    /// Adds students to the class list; returns them as saved.
    static func addStudents(_ list: [(name: String, period: Int?)], _ token: String) async throws -> [Student] {
        struct Row: Encodable { let name: String; let period: Int? }
        let data = try await request("/rest/v1/students?select=id,name,period,number", method: "POST", token: token,
                                     body: try encoder.encode(list.map { Row(name: $0.name, period: $0.period) }), prefer: "return=representation")
        return try decoder.decode([Student].self, from: data)
    }

    /// A test's scans, newest first.
    static func scans(_ quizId: String, _ token: String) async throws -> [ScanRecord] {
        let data = try await request("/rest/v1/scans?quiz_id=eq.\(quizId)&select=id,quiz_id,period,student_id,student_name,name_image,answers,score_override,scanned_at,photo_path,review,form,taken_on&order=scanned_at.desc", token: token)
        return try decoder.decode([ScanRecord].self, from: data)
    }

    static func scanSummaries(_ token: String) async throws -> [ScanSummaryRow] {
        let data = try await request("/rest/v1/scans?select=quiz_id,student_id,answers,score_override", token: token)
        return try decoder.decode([ScanSummaryRow].self, from: data)
    }

    /// A student's scans across tests, newest first.
    static func scans(studentId: String, _ token: String) async throws -> [ScanRecord] {
        let data = try await request("/rest/v1/scans?student_id=eq.\(studentId)&select=id,quiz_id,period,student_id,student_name,name_image,answers,score_override,scanned_at,photo_path,review,form,taken_on&order=scanned_at.desc", token: token)
        return try decoder.decode([ScanRecord].self, from: data)
    }

    static func updateStudent(_ id: String, name: String, period: Int?, _ token: String) async throws {
        struct Row: Encodable {
            let name: String, period: Int?
            func encode(to encoder: Encoder) throws {   // send a null period too, so clearing it works
                var c = encoder.container(keyedBy: CodingKeys.self)
                try c.encode(name, forKey: .name)
                try c.encode(period, forKey: .period)
            }
            enum CodingKeys: String, CodingKey { case name, period }
        }
        _ = try await request("/rest/v1/students?id=eq.\(id)", method: "PATCH", token: token, body: try encoder.encode(Row(name: name, period: period)), prefer: "return=minimal")
    }

    /// Their scans stay, without the student.
    static func deleteStudent(_ id: String, _ token: String) async throws {
        _ = try await request("/rest/v1/students?id=eq.\(id)", method: "DELETE", token: token)
    }

    static func deleteStudents(_ ids: [String], _ token: String) async throws {
        guard !ids.isEmpty else { return }
        _ = try await request("/rest/v1/students?id=in.(\(ids.joined(separator: ",")))", method: "DELETE", token: token)
    }

    // TESTING ONLY — remove before production (with AppStore.wipeEverything and the Testing section in SettingsView).
    /// Deletes every scan, student, test and sheet photo on the signed-in account.
    static func wipeEverything(userId: String, _ token: String) async throws {
        struct Object: Decodable { let name: String }
        struct List: Encodable { let prefix: String; let limit: Int; let offset: Int }
        struct Remove: Encodable { let prefixes: [String] }
        while true {
            let data = try await request("/storage/v1/object/list/sheets", method: "POST", token: token,
                                         body: try JSONEncoder().encode(List(prefix: userId, limit: 1000, offset: 0)))
            let names = try JSONDecoder().decode([Object].self, from: data).map { "\(userId)/\($0.name)" }
            if names.isEmpty { break }
            _ = try await request("/storage/v1/object/sheets", method: "DELETE", token: token, body: try JSONEncoder().encode(Remove(prefixes: names)))
        }
        // Row-level security limits each delete to this account's rows; PostgREST wants a filter on every delete.
        for table in ["scans", "students", "quizzes"] {
            _ = try await request("/rest/v1/\(table)?id=not.is.null", method: "DELETE", token: token)
        }
    }

    /// A marked sheet photo from the private "sheets" bucket.
    static func photo(_ path: String, _ token: String) async throws -> Data {
        try await request("/storage/v1/object/authenticated/sheets/\(path)", token: token)
    }

    /// Creates a test with its sheet layout and a code the phone can recognize on printed sheets.
    static func createTest(title: String, questions: Int, choices: Int, key: String, points: Double, bonus: Int,
                           code: Int, _ token: String) async throws -> Quiz {
        struct Row: Encodable {
            let title: String, numQuestions: Int, numChoices: Int, answerKey: String, pointsPerQuestion: Double
            let bonusCount: Int, code: String, layout: SheetLayout
        }
        let row = Row(title: title, numQuestions: questions, numChoices: choices, answerKey: key, pointsPerQuestion: points,
                      bonusCount: bonus, code: String(code), layout: SheetDesign.layout(questions: questions, choices: choices))
        let data = try await request("/rest/v1/quizzes?select=id,title,num_questions,num_choices,answer_key,points_per_question,bonus_count,layout,code",
                                     method: "POST", token: token, body: try encoder.encode([row]), prefer: "return=representation")
        guard let quiz = try decoder.decode([Quiz].self, from: data).first else { throw APIError(status: 0, message: "Not saved") }
        return quiz
    }

    static func updateKey(_ quizId: String, key: String, _ token: String) async throws {
        struct Row: Encodable { let answerKey: String }
        _ = try await request("/rest/v1/quizzes?id=eq.\(quizId)", method: "PATCH", token: token,
                              body: try encoder.encode(Row(answerKey: key)), prefer: "return=minimal")
    }

    static func insert(_ scan: ScanUpload, _ token: String) async throws {
        var row = scan
        row.localPhoto = nil   // phone-only
        // Sending the same scan twice (a retry) updates it. A second scan of a student who already has one for the
        // test fails with 409, and the caller saves it unassigned for the teacher to compare.
        _ = try await request("/rest/v1/scans?on_conflict=id", method: "POST", token: token,
                              body: try encoder.encode([row]), prefer: "resolution=merge-duplicates,return=minimal")
    }

    static func uploadPhoto(_ path: String, _ jpeg: Data, _ token: String) async throws {
        _ = try await request("/storage/v1/object/sheets/\(path)", method: "POST", token: token, body: jpeg,
                              contentType: "image/jpeg", upsert: true)
    }

    static func update(_ id: String, _ patch: ScanPatch, _ token: String) async throws {
        _ = try await request("/rest/v1/scans?id=eq.\(id)", method: "PATCH", token: token, body: try encoder.encode(patch), prefer: "return=minimal")
    }

    static func scan(_ id: String, _ token: String) async throws -> ScanRecord? {
        let data = try await request("/rest/v1/scans?id=eq.\(id)&select=id,quiz_id,period,student_id,student_name,name_image,answers,score_override,scanned_at,photo_path,review,form,taken_on", token: token)
        return try decoder.decode([ScanRecord].self, from: data).first
    }

    /// The student's scan for a test, if they have one.
    static func scanId(quizId: String, studentId: String, _ token: String) async throws -> String? {
        struct Row: Decodable { let id: String }
        let data = try await request("/rest/v1/scans?quiz_id=eq.\(quizId)&student_id=eq.\(studentId)&select=id", token: token)
        return try decoder.decode([Row].self, from: data).first?.id
    }

    static func delete(_ id: String, _ token: String) async throws {
        _ = try await request("/rest/v1/scans?id=eq.\(id)", method: "DELETE", token: token)
    }

    private static func auth(_ grant: String, _ body: [String: String]) async throws -> Session {
        let data = try await request("/auth/v1/token?grant_type=\(grant)", method: "POST", body: try JSONEncoder().encode(body))
        let r = try decoder.decode(AuthResponse.self, from: data)
        return Session(accessToken: r.accessToken, refreshToken: r.refreshToken, userId: r.user.id,
                       expiresAt: Date().addingTimeInterval(r.expiresIn))
    }

    private static func request(_ path: String, method: String = "GET", token: String? = nil, body: Data? = nil,
                                prefer: String? = nil, contentType: String = "application/json", upsert: Bool = false) async throws -> Data {
        guard let url = URL(string: Config.supabaseURL + path) else { throw APIError(status: 0, message: "Bad Supabase URL in Supabase.swift") }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue(Config.supabaseKey, forHTTPHeaderField: "apikey")
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            req.httpBody = body
            req.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        if let prefer { req.setValue(prefer, forHTTPHeaderField: "Prefer") }
        if upsert { req.setValue("true", forHTTPHeaderField: "x-upsert") }
        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            let message = ["msg", "error_description", "message", "error"].compactMap { json[$0] as? String }.first
            throw APIError(status: status, message: message ?? "Server error \(status)")
        }
        return data
    }
}

/// Small wrapper around the iOS Keychain (this-device-only items).
enum Keychain {
    static func set(_ key: String, _ data: Data?) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: key]
        SecItemDelete(query as CFDictionary)
        guard let data else { return }
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    static func get(_ key: String) -> Data? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrAccount as String: key,
                                    kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess ? out as? Data : nil
    }
}
