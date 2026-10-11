import AppKit
import Carbon.HIToolbox
import SwiftUI

extension View {
    /// While this view is on screen, Tab / Shift-Tab in one of its text fields moves to the
    /// next / previous field in the same section (GamesheetField.tabGroup), wrapping around at the
    /// ends, instead of AppKit's default of walking every field on the page.
    func gamesheetTabNavigation(focus: FocusState<GamesheetField?>.Binding) -> some View {
        modifier(GamesheetTabNavigation(focus: focus))
    }
}

private struct GamesheetTabNavigation: ViewModifier {
    var focus: FocusState<GamesheetField?>.Binding
    @State private var monitor: Any?

    func body(content: Content) -> some View {
        content
            .onAppear {
                guard monitor == nil else { return }
                // Runs before the field editor sees the key, so the default key-view loop never fires.
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                    moveFocus(for: event) ? nil : event
                }
            }
            .onDisappear {
                if let monitor { NSEvent.removeMonitor(monitor) }
                monitor = nil
            }
    }

    /// Returns true when the event was a Tab that moved focus (and so should be swallowed).
    private func moveFocus(for event: NSEvent) -> Bool {
        guard event.keyCode == UInt16(kVK_Tab),
              event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
              let current = focus.wrappedValue else { return false }
        let group = current.tabGroup
        guard let index = group.firstIndex(of: current) else { return false }
        let step = event.modifierFlags.contains(.shift) ? -1 : 1
        focus.wrappedValue = group[(index + step + group.count) % group.count]
        return true
    }
}
