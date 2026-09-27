import SwiftUI
import UIKit

/// GradeScan brand: Green Sage #98A869 on warm, olive-tinted neutrals (same tokens as the portal).
enum Brand {
    /// Fills: the main button, chosen bubbles, chart bars. Text on sage is `ink` in both modes.
    static let sage = Color(light: 0x98A869, dark: 0xA9B97A)
    /// Sage for text and icons (the app's accent color): readable on white and on black.
    static let sageStrong = Color(light: 0x5F6E3A, dark: 0xC3D19A)
    /// Deep sage for tinted glass over the camera, where the text is always white.
    static let moss = Color(hex: 0x5F6E3A)
    static let ink = Color(hex: 0x1C1F17)
    /// Needs a look: an unknown name, a missing period, rows to check. Readable as text in both modes.
    static let warn = Color(light: 0xB45309, dark: 0xE3B55B)
    static let good = Color(light: 0x15803D, dark: 0x4ADE80)
    static let bad = Color(light: 0xDC2626, dark: 0xF87171)
}

extension View {
    /// The main action on a screen: sage with ink text in both modes, like the portal's primary button.
    func primaryButton() -> some View {
        buttonStyle(.borderedProminent).tint(Brand.sage).foregroundStyle(Brand.ink)
    }
}

extension Color {
    init(hex: UInt32) { self.init(uiColor: UIColor(hex: hex)) }

    init(light: UInt32, dark: UInt32) {
        self.init(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light) })
    }
}

private extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}
