import AppKit
import SwiftUI

extension View {
    /// Keeps content below the window toolbar when the panel's glass runs underneath it.
    /// With a full-size content view, SwiftUI only reserves the title bar's height, not the
    /// bridged toolbar's, so the shortfall is measured from the window and added here.
    func clearsWindowToolbar() -> some View {
        modifier(ToolbarClearance())
    }
}

private struct ToolbarClearance: ViewModifier {
    @State private var windowTopInset: CGFloat = 0

    func body(content: Content) -> some View {
        GeometryReader { proxy in
            content
                .safeAreaPadding(.top, max(0, windowTopInset - proxy.safeAreaInsets.top))
        }
        .background(WindowTopInsetReader(inset: $windowTopInset))
    }
}

/// Reports the distance from the window's top edge to its content layout rect (title bar + toolbar).
private struct WindowTopInsetReader: NSViewRepresentable {
    @Binding var inset: CGFloat

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.onChange = { value in
            if value != inset { inset = value }
        }
        return view
    }

    func updateNSView(_ nsView: ReaderView, context: Context) {
        nsView.onChange = { value in
            if value != inset { inset = value }
        }
        nsView.report()
    }

    final class ReaderView: NSView {
        var onChange: ((CGFloat) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            report()
        }

        override func layout() {
            super.layout()
            report()
        }

        func report() {
            guard let window else { return }
            let value = window.frame.height - window.contentLayoutRect.maxY
            Task { @MainActor [onChange] in onChange?(value) }
        }
    }
}
