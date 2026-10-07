import SwiftUI

/// Stand-in for `.pickerStyle(.segmented)`: the native control always draws the selected segment's
/// text white, which can't be overridden, so this draws its own sliding accent pill with
/// `onAccent` text on top.
struct SegmentedTabs<Value: Hashable, Label: View>: View {
    @Binding var selection: Value
    let options: [Value]
    @ViewBuilder let label: (Value) -> Label

    @Environment(\.onDarkHeader) private var onDarkHeader
    @Namespace private var pill

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                let isSelected = option == selection
                Button {
                    selection = option
                } label: {
                    label(option)
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .lineLimit(1)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 3)
                        .frame(maxWidth: .infinity)
                        .foregroundStyle(isSelected ? DesignSystem.Colors.onAccent : (onDarkHeader ? DesignSystem.Colors.headerText : DesignSystem.Colors.textPrimary))
                        .background {
                            if isSelected {
                                RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .fill(DesignSystem.Colors.accentPrimary)
                                    .matchedGeometryEffect(id: "pill", in: pill)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
        .padding(2)
        .animation(DesignSystem.Motion.springQuick, value: selection)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(onDarkHeader ? Color.white.opacity(0.08) : DesignSystem.Colors.surfaceTint.opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(onDarkHeader ? Color.white.opacity(0.12) : DesignSystem.Colors.border, lineWidth: 1)
        )
    }
}
