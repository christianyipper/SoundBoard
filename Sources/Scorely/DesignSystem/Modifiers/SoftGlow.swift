import SwiftUI

/// Two-layer shadow stack (tight core + wide soft halo) — a cheap, shape-agnostic way to give any
/// view a delicate glow without a separate blurred background copy.
struct SoftGlow: ViewModifier {
    let color: Color
    var radius: CGFloat = 12
    var isActive: Bool = true

    func body(content: Content) -> some View {
        content
            .shadow(color: isActive ? color.opacity(0.9) : .clear, radius: isActive ? radius : 0)
            .shadow(color: isActive ? color.opacity(0.45) : .clear, radius: isActive ? radius * 2.2 : 0)
    }
}

extension View {
    func softGlow(_ color: Color, radius: CGFloat = 12, isActive: Bool = true) -> some View {
        modifier(SoftGlow(color: color, radius: radius, isActive: isActive))
    }
}
