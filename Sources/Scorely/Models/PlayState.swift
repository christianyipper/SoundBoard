import SwiftUI

enum PlayState {
    case idle
    case playing
    case played

    /// Tint layered into a tile/slot's glassCard background.
    var tileColor: Color {
        switch self {
        case .idle, .played: return DesignSystem.Colors.surfaceTint
        case .playing: return DesignSystem.Colors.successGlow
        }
    }

    var foregroundColor: Color {
        switch self {
        case .idle, .played: return DesignSystem.Colors.textPrimary
        case .playing: return .white
        }
    }

    /// The soft glow color to apply while active, nil when there's nothing to glow.
    var glowColor: Color? {
        self == .playing ? DesignSystem.Colors.successGlow : nil
    }
}
