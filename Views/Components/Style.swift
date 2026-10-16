import AppKit
import SwiftUI

enum Style {
    static let panelSize = CGSize(width: 560, height: 620)
    /// Horizontal inset for content outside lists, matching the inset list style's text edge.
    static let contentInset: CGFloat = 20
    static let motion = Animation.smooth(duration: 0.22)
}

/// The panel's translucent backdrop. `NSVisualEffectView` follows Reduce Transparency and
/// Increase Contrast automatically.
struct PanelBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
