import SwiftUI

/// Notes / Today as plain text. The selected tab sits in a clear Liquid Glass bubble that
/// morphs to the other tab on switch (`glassEffectID` inside a `GlassEffectContainer`).
struct SectionSwitcher: View {
    @Environment(AppState.self) private var state
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var glass

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 2) {
                tab(.notes, title: "Notes", shortcut: "⌘1")
                tab(.today, title: "Today", shortcut: "⌘2")
            }
        }
        .animation(reduceMotion ? nil : Style.motion, value: state.section)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Section")
    }

    private func tab(_ section: AppSection, title: String, shortcut: String) -> some View {
        let isSelected = state.section == section
        return Button {
            state.select(section)
        } label: {
            // The hidden semibold copy reserves the widest width, so tabs never shift.
            ZStack {
                Text(title).fontWeight(.semibold).hidden()
                Text(title).fontWeight(isSelected ? .semibold : .regular)
            }
            .foregroundStyle(isSelected ? .primary : .secondary)
            .padding(.horizontal, 14)
            .frame(height: 30)
            .contentShape(.capsule)
            .modifier(SelectedGlass(isSelected: isSelected, namespace: glass))
        }
        .buttonStyle(.plain)
        .help(Text(verbatim: "\(title) (\(shortcut))"))
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

private struct SelectedGlass: ViewModifier {
    let isSelected: Bool
    let namespace: Namespace.ID

    func body(content: Content) -> some View {
        if isSelected {
            content
                .glassEffect(.clear.interactive(), in: .capsule)
                .glassEffectID("selection", in: namespace)
        } else {
            content
        }
    }
}
