import AppKit
import SwiftUI

extension View {
    /// While this view is on screen, a click anywhere outside the text field being edited ends
    /// editing (turning hotkeys back on). Cards, report lines and other views that handle their own
    /// clicks would otherwise swallow the click before an empty-space tap gesture could see it.
    func endsEditingOnOutsideClick() -> some View {
        modifier(EndEditingOnOutsideClick())
    }
}

private struct EndEditingOnOutsideClick: ViewModifier {
    @State private var monitor: Any?

    func body(content: Content) -> some View {
        content
            .onAppear {
                guard monitor == nil else { return }
                monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
                    Self.endEditingIfOutside(event)
                    return event
                }
            }
            .onDisappear {
                if let monitor { NSEvent.removeMonitor(monitor) }
                monitor = nil
            }
    }

    /// Runs before the click is delivered, so a click on another text field still focuses it.
    private static func endEditingIfOutside(_ event: NSEvent) {
        guard let window = event.window,
              let editor = window.firstResponder as? NSTextView, editor.isFieldEditor,
              let field = editor.delegate as? NSTextField else { return }
        let point = field.convert(event.locationInWindow, from: nil)
        guard !field.bounds.contains(point) else { return }
        window.makeFirstResponder(nil)
    }
}
