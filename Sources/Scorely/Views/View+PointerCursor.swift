import AppKit
import SwiftUI

extension View {
    /// Shows the pointing-hand cursor on hover. AppKit doesn't do this automatically for custom
    /// tap targets (or even real Buttons), so clickable elements otherwise keep the plain arrow.
    func pointerCursor() -> some View {
        onHover { isHovering in
            if isHovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
    }
}
