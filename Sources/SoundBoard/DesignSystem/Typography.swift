import SwiftUI

extension DesignSystem {
    /// Rounded system-font type scale for the soft, clean-anime feel — no custom font assets.
    enum Typography {
        static let largeTitle = Font.system(.largeTitle, design: .rounded, weight: .bold)
        static let title = Font.system(.title2, design: .rounded, weight: .bold)
        static let headline = Font.system(.headline, design: .rounded, weight: .semibold)
        static let body = Font.system(.body, design: .rounded, weight: .regular)
        static let callout = Font.system(.callout, design: .rounded, weight: .regular)
        static let caption = Font.system(.caption, design: .rounded, weight: .medium)
        static let captionBold = Font.system(.caption2, design: .rounded, weight: .bold)
        /// Larger bold badge type, e.g. the single key-letter/number badges on hotkey slots.
        static let keyBadge = Font.system(.callout, design: .rounded, weight: .bold)
    }
}
