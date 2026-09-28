import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Camera frames the teacher saved when a sheet wouldn't scan (opt-in, in Settings), with what the scanner made of
/// them, kept on the phone until they're shared from Settings.
enum ProblemFrames {
    static var folder: URL {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("ProblemFrames")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Saved frames and their notes, oldest first.
    static func all() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { ["jpg", "json"].contains($0.pathExtension) }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static var count: Int { all().filter { $0.pathExtension == "jpg" }.count }

    static func save(_ jpeg: Data, note: String) {
        let name = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        try? jpeg.write(to: folder.appendingPathComponent("\(name).jpg"))
        try? Data(note.utf8).write(to: folder.appendingPathComponent("\(name).json"))
    }

    static func clear() {
        for url in all() { try? FileManager.default.removeItem(at: url) }
    }

    /// A camera frame's brightness plane as a grayscale JPEG.
    static func jpeg(_ img: LumaImage) -> Data? {
        var pixels = [UInt8](repeating: 0, count: img.width * img.height)
        for y in 0..<img.height {
            for x in 0..<img.width { pixels[y * img.width + x] = img.base[y * img.bytesPerRow + x] }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(width: img.width, height: img.height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: img.width,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }
}
