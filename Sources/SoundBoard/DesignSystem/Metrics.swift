import CoreGraphics

extension DesignSystem {
    /// Standardized corner-radius scale, replacing the ad hoc 10/12 literals previously scattered
    /// across card-style views.
    enum Radius {
        static let small: CGFloat = 10
        static let medium: CGFloat = 16
        static let large: CGFloat = 22
    }
}
