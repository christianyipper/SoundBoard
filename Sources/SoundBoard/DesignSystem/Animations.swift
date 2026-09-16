import SwiftUI

extension DesignSystem {
    /// Reusable animation curves for a smooth, modern feel — springs for interactive state
    /// changes, gentle repeating eases for ambient glow pulses.
    enum Motion {
        static let springSmooth = Animation.spring(response: 0.4, dampingFraction: 0.75)
        static let springQuick = Animation.spring(response: 0.25, dampingFraction: 0.8)
        static let gentlePulse = Animation.easeInOut(duration: 2.2).repeatForever(autoreverses: true)
        static let glowPulse = Animation.easeInOut(duration: 1.6).repeatForever(autoreverses: true)
        static let quickFade = Animation.easeInOut(duration: 0.2)
    }
}
