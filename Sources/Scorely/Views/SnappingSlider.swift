import AppKit
import SwiftUI

/// 0...1 slider whose knob snaps to `steps` even divisions while dragging, without the tick marks
/// SwiftUI's `Slider(step:)` makes AppKit draw. The knob is moved back onto the nearest step on
/// every drag update, so it visibly jumps between steps instead of gliding.
struct SnappingSlider: NSViewRepresentable {
    @Binding var value: Float
    var steps: Int = 10

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSSlider {
        let slider = NSSlider(
            value: snapped(Double(value)),
            minValue: 0,
            maxValue: 1,
            target: context.coordinator,
            action: #selector(Coordinator.valueChanged(_:))
        )
        slider.isContinuous = true
        slider.trackFillColor = NSColor(DesignSystem.Colors.accentPrimary)
        return slider
    }

    func updateNSView(_ slider: NSSlider, context: Context) {
        context.coordinator.parent = self
        let target = snapped(Double(value))
        if slider.doubleValue != target {
            slider.doubleValue = target
        }
    }

    fileprivate func snapped(_ raw: Double) -> Double {
        (raw * Double(steps)).rounded() / Double(steps)
    }

    final class Coordinator: NSObject {
        var parent: SnappingSlider

        init(_ parent: SnappingSlider) {
            self.parent = parent
        }

        @objc func valueChanged(_ slider: NSSlider) {
            let snapped = parent.snapped(slider.doubleValue)
            slider.doubleValue = snapped
            if Float(snapped) != parent.value {
                parent.value = Float(snapped)
            }
        }
    }
}
