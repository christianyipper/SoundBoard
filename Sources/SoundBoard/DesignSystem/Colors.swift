import AppKit
import SwiftUI

/// Namespace for the app's "Neverness to Everness"-inspired design tokens.
enum DesignSystem {}

extension Color {
    /// Mirrors an asset-catalog dynamic color, but authored in code so it resolves identically
    /// across all three launch paths (`swift run`, Xcode, and the packaged .app) — Assets.xcassets
    /// isn't wired into the SwiftPM build or Scripts/build-app.sh, so a real asset color set would
    /// silently fail to resolve outside Xcode. Reacts to whatever NSAppearance is active on the
    /// window it's drawn in, including one overridden via .preferredColorScheme.
    static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }
}

private extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

extension DesignSystem {
    /// Soft pastel palette inspired by Neverness to Everness: blush/lavender/mint/cream in light
    /// mode, deep muted plum-navy with the same pastels glowing in dark mode.
    enum Colors {
        static let background = Color.dynamic(light: NSColor(hex: 0xF8F1F4), dark: NSColor(hex: 0x1C1826))

        static let backgroundGradient = LinearGradient(
            colors: [
                Color.dynamic(light: NSColor(hex: 0xFDF3F5), dark: NSColor(hex: 0x221C30)),
                Color.dynamic(light: NSColor(hex: 0xF1ECFA), dark: NSColor(hex: 0x14111C))
            ],
            startPoint: .top,
            endPoint: .bottom
        )

        static let surfaceTint = Color.dynamic(light: NSColor(hex: 0xF6D8E4), dark: NSColor(hex: 0x3A2F4E))
        static let accentPrimary = Color.dynamic(light: NSColor(hex: 0xB79CD9), dark: NSColor(hex: 0xC9A8F2))
        static let accentSecondary = Color.dynamic(light: NSColor(hex: 0x93DFC2), dark: NSColor(hex: 0x7FE8C4))
        static let successGlow = Color.dynamic(light: NSColor(hex: 0x5FCFA0), dark: NSColor(hex: 0x6BE8B8))
        static let dangerGlow = Color.dynamic(light: NSColor(hex: 0xF0728A), dark: NSColor(hex: 0xFF8FA8))

        static let border = Color.dynamic(
            light: NSColor(hex: 0xE3D6EE, alpha: 0.7),
            dark: NSColor(hex: 0x4A3F63, alpha: 0.6)
        )

        static let textPrimary = Color.dynamic(light: NSColor(hex: 0x3A2E44), dark: NSColor(hex: 0xF5ECF7))
        static let textSecondary = Color.dynamic(light: NSColor(hex: 0x8A7B93), dark: NSColor(hex: 0xB3A4C4))
        // Always white: it sits on a saturated glow surface (success/danger) in both color
        // schemes, so it needs to stay light rather than flipping to dark text in dark mode.
        static let onAccent = Color.dynamic(light: NSColor(hex: 0xFFFBFD), dark: NSColor(hex: 0xFFFBFD))
    }
}

extension AppAppearance {
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}
