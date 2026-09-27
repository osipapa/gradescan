import Foundation

/// A scanned sheet on the phone: in the current batch, or on the single-mode card.
struct ScanItem: Identifiable, Codable, Equatable {
    let id: String             // also the scans row id
    let quizId: String
    var answers: String
    var period: Int?
    var studentId: String?
    var studentName: String?   // the assigned student's name, or what the handwriting read
    var read: String?          // what handwriting recognition read
    var nameImage: String?     // JPEG data URL of the handwritten name
    var photo: String?         // the marked photo on the phone (file name in Photos)
    let scannedAt: Date
    var processing = true      // the photo and name are still being read
    var photoFailed = false
    var reviewed = false
    var suggestedId: String?   // the student the handwriting probably is, waiting for a one-tap yes
    var rows: [Int: RowReview] = [:]   // rows the teacher checks, by question index
    var duplicateOf: String?   // the student's other scan for this test (in the batch or saved): the teacher keeps one

    var upload: ScanUpload {
        ScanUpload(id: id, quizId: quizId, studentId: studentId, period: period, studentName: studentName,
                   nameImage: nameImage, localPhoto: photo, answers: answers, scannedAt: scannedAt, review: Review.stored(rows))
    }

    /// Something to check: no student, no period, a row waiting for a yes or no, or no usable photo.
    var needsLook: Bool { studentId == nil || period == nil || rows.values.contains { $0.result == nil } || photoFailed || duplicateOf != nil }
}

/// One scan per student per test: spots a second scan of the same sheet or student, for the teacher to compare.
enum BatchRules {
    /// An earlier scan in the batch of the same student for the same test; or, with no student, one with a similar
    /// handwritten name and answers that agree wherever both have a letter.
    static func duplicate(_ item: ScanItem, in items: [ScanItem]) -> Int? {
        items.firstIndex { other in
            guard other.id != item.id, other.quizId == item.quizId, !other.processing else { return false }
            if let student = item.studentId { return other.studentId == student }
            guard other.studentId == nil, let a = item.read, let b = other.read else { return false }
            return NameMatch.distance(NameMatch.tokens(a), NameMatch.tokens(b)) <= 0.3
                && CaptureGate.differences(item.answers, other.answers) == 0
        }
    }

    /// Another scan with the same answers and a loosely similar name: probably the same sheet twice.
    static func lookalike(_ item: ScanItem, in items: [ScanItem]) -> Int? {
        guard let read = item.read else { return nil }
        return items.firstIndex { other in
            other.id != item.id && other.quizId == item.quizId && other.answers == item.answers
                && NameMatch.distance(NameMatch.tokens(read), NameMatch.tokens(other.read ?? "")) <= 0.6
        }
    }
}
