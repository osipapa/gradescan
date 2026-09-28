import AVFoundation

/// A short, soft tick for each sheet captured in stand mode, heard even with the ringer off: the phone is propped
/// up and the teacher is looking at the sheets, not the screen.
@MainActor
enum Tick {
    private static let player: AVAudioPlayer? = {
        let rate = 44_100, count = rate * 45 / 1000
        var data = Data()
        func put<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); put(UInt32(36 + count * 2)); data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); put(UInt32(16)); put(UInt16(1)); put(UInt16(1))
        put(UInt32(rate)); put(UInt32(rate * 2)); put(UInt16(2)); put(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); put(UInt32(count * 2))
        for i in 0..<count {   // 1.5 kHz, fading out fast
            let t = Double(i) / Double(rate)
            put(Int16(9000 * sin(2 * .pi * 1500 * t) * exp(-t * 90)))
        }
        let player = try? AVAudioPlayer(data: data)
        player?.prepareToPlay()
        return player
    }()

    static func play() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, options: .mixWithOthers)
        try? AVAudioSession.sharedInstance().setActive(true)
        player?.currentTime = 0
        player?.play()
    }
}
