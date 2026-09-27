import CommonCrypto
import CryptoKit
import Foundation
import Security

// Paste the same values as in portal/index.html (Supabase → Project Settings → API).
enum Config {
    static let supabaseURL = "https://YOUR-PROJECT-REF.supabase.co"
    static let supabaseKey = "YOUR-PUBLISHABLE-OR-ANON-KEY"
}

struct Session: Codable {
    var accessToken: String
    var refreshToken: String
    var userId: String
    var expiresAt: Date
}

struct Quiz: Codable {
    let id: String
    let code: String
    let title: String
    let numQuestions: Int
    let numChoices: Int
    let answerKey: String
    let pointsPerQuestion: Double
    let bonusCount: Int
}

struct StudentRow: Codable {
    let code: String
    let nameEnc: String
}

struct ScanUpload: Codable {
    let quizId: String
    let studentCode: String
    let answers: String
    let scannedAt: Date
}

struct APIError: LocalizedError {
    let status: Int
    let message: String
    var errorDescription: String? { message }
}

/// Minimal Supabase REST client: sign in, read quizzes and roster, upsert scans.
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
        d.dateDecodingStrategy = .iso8601
        return d
    }()

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

    static func quizzes(_ token: String) async throws -> [Quiz] {
        let data = try await request("/rest/v1/quizzes?select=id,code,title,num_questions,num_choices,answer_key,points_per_question,bonus_count", token: token)
        return try decoder.decode([Quiz].self, from: data)
    }

    static func students(_ token: String) async throws -> [StudentRow] {
        let data = try await request("/rest/v1/students?select=code,name_enc", token: token)
        return try decoder.decode([StudentRow].self, from: data)
    }

    /// Insert, or replace the earlier scan of the same student for the same quiz.
    static func upsert(_ scan: ScanUpload, _ token: String) async throws {
        _ = try await request("/rest/v1/scans?on_conflict=quiz_id,student_code", method: "POST", token: token,
                              body: try encoder.encode([scan]), prefer: "resolution=merge-duplicates,return=minimal")
    }

    private static func auth(_ grant: String, _ body: [String: String]) async throws -> Session {
        let data = try await request("/auth/v1/token?grant_type=\(grant)", method: "POST", body: try JSONEncoder().encode(body))
        let r = try decoder.decode(AuthResponse.self, from: data)
        return Session(accessToken: r.accessToken, refreshToken: r.refreshToken, userId: r.user.id,
                       expiresAt: Date().addingTimeInterval(r.expiresIn))
    }

    private static func request(_ path: String, method: String = "GET", token: String? = nil,
                                body: Data? = nil, prefer: String? = nil) async throws -> Data {
        guard let url = URL(string: Config.supabaseURL + path) else { throw APIError(status: 0, message: "Bad Supabase URL in Supabase.swift") }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue(Config.supabaseKey, forHTTPHeaderField: "apikey")
        if let token { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let prefer { req.setValue(prefer, forHTTPHeaderField: "Prefer") }
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

/// Same scheme as the portal: PBKDF2-SHA256 (310,000 rounds, salt "gradescan:<user id>") → AES-256-GCM.
enum NameCrypto {
    static func deriveKey(_ passphrase: String, userId: String) -> Data? {
        let salt = Array("gradescan:\(userId)".utf8)
        var key = [UInt8](repeating: 0, count: 32)
        let status = CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), passphrase, passphrase.utf8.count, salt, salt.count,
                                          CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), 310_000, &key, key.count)
        return status == Int32(kCCSuccess) ? Data(key) : nil
    }

    static func decrypt(_ base64: String, _ key: Data) -> String? {
        guard let data = Data(base64Encoded: base64),
              let box = try? AES.GCM.SealedBox(combined: data),
              let plain = try? AES.GCM.open(box, using: SymmetricKey(data: key)) else { return nil }
        return String(decoding: plain, as: UTF8.self)
    }
}
