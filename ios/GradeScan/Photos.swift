import Foundation

/// Marked sheet photos on the phone (for cards and until they upload), in Application Support so they survive the app closing.
enum Photos {
    private static var folder: URL {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Photos", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Saves the JPEG and returns its file name, or nil if it couldn't be written.
    static func save(_ data: Data, id: String) -> String? {
        let name = "\(id).jpg"
        return (try? data.write(to: folder.appendingPathComponent(name), options: .atomic)) != nil ? name : nil
    }

    static func load(_ name: String) -> Data? { try? Data(contentsOf: folder.appendingPathComponent(name)) }

    static func remove(_ name: String) { try? FileManager.default.removeItem(at: folder.appendingPathComponent(name)) }

    static func url(_ name: String) -> URL { folder.appendingPathComponent(name) }

    /// Deletes photos nothing refers to any more (left behind when the app closed mid-scan).
    static func prune(keeping: Set<String>) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        for name in names where !keeping.contains(name) { remove(name) }
    }
}
