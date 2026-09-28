import SwiftUI

extension DesignSystem {
    /// Rounded system-font type scale for the soft, clean-anime feel — no custom font assets.
    enum Typography {
        static let largeTitle = Font.system(size: 44, weight: .bold, design: .rounded)
        static let title = Font.system(size: 32, weight: .bold, design: .rounded)
        static let headline = Font.system(size: 18, weight: .semibold, design: .rounded)
        static let body = Font.system(size: 18, weight: .regular, design: .rounded)
        static let callout = Font.system(.callout, design: .rounded, weight: .regular)
        static let caption = Font.system(.caption, design: .rounded, weight: .medium)
        static let captionBold = Font.system(.caption2, design: .rounded, weight: .bold)
        /// Larger bold badge type, e.g. the single key-letter/number badges on hotkey slots.
        static let keyBadge = Font.system(size: 16, weight: .bold, design: .rounded)
    }
}
