import SwiftUI

/// Frosted-glass card recipe shared by tiles, slots, and bar containers: a material fill plus a
/// low-opacity tint layer plus a stroked border, clipped and hit-tested to the same rounded shape.
struct GlassCard: ViewModifier {
    var cornerRadius: CGFloat = DesignSystem.Radius.medium
    var tint: Color = .clear
    var borderColor: Color = DesignSystem.Colors.border
    var borderWidth: CGFloat = 1

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background(
                shape.fill(.thinMaterial)
                    .overlay(shape.fill(tint.opacity(0.18)))
            )
            .overlay(shape.strokeBorder(borderColor, lineWidth: borderWidth))
            .contentShape(shape)
    }
}

extension View {
    func glassCard(
        cornerRadius: CGFloat = DesignSystem.Radius.medium,
        tint: Color = .clear,
        borderColor: Color = DesignSystem.Colors.border,
        borderWidth: CGFloat = 1
    ) -> some View {
        modifier(GlassCard(cornerRadius: cornerRadius, tint: tint, borderColor: borderColor, borderWidth: borderWidth))
    }
}
