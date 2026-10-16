import AppKit
import Carbon.HIToolbox
import OSLog
import SwiftData
import SwiftUI

/// A floating panel that takes keyboard focus without activating the app,
/// so the app you were using stays frontmost and regains focus when littlelog hides.
final class LittlelogPanel: NSPanel {
    var keyHandler: ((NSEvent) -> Bool)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, keyHandler?(event) == true { return }
        super.sendEvent(event)
    }
}

final class PanelController: NSObject, NSWindowDelegate {
    private let panel: LittlelogPanel
    private let state: AppState
    private var spaceObserver: NSObjectProtocol?
    private var outsideClickMonitor: Any?

    /// Bumped on every show/hide so a finishing fade-out never hides a panel that was reopened.
    private var presentation = 0
    private var isHiding = false
    private var isPositioning = false
    /// Where the user last dragged the panel, kept per display.
    private var draggedOrigins: [CGDirectDisplayID: NSPoint] = [:]

    init(state: AppState, container: ModelContainer) {
        self.state = state
        panel = LittlelogPanel(
            contentRect: NSRect(origin: .zero, size: Style.panelSize),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()
        configurePanel()
        installContent(container: container)

        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.hide(.spaceChanged)
            }
        }
    }

    var isShown: Bool { panel.isVisible && panel.isKeyWindow && !isHiding }

    func toggle() {
        isShown ? hide(.shortcut) : show()
    }

    func show() {
        presentation += 1
        isHiding = false
        state.panelWillAppear()
        installOutsideClickMonitor()

        if panel.isVisible {
            panel.animator().alphaValue = 1
            panel.makeKeyAndOrderFront(nil)
            return
        }

        position()
        if reduceMotion {
            panel.alphaValue = 1
            panel.makeKeyAndOrderFront(nil)
            return
        }
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    enum HideReason: String {
        case shortcut, keyboard, focusLost, clickOutside, spaceChanged
    }

    func hide(_ reason: HideReason) {
        guard panel.isVisible, !isHiding else { return }
        Logger.app.debug("hiding panel: \(reason.rawValue, privacy: .public)")
        isHiding = true
        presentation += 1
        let hiding = presentation
        removeOutsideClickMonitor()
        state.panelDidHide()

        guard !reduceMotion else {
            finishHiding()
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.1
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.presentation == hiding else { return }
                self.finishHiding()
            }
        }
    }

    private func finishHiding() {
        panel.orderOut(nil)
        panel.alphaValue = 1
        isHiding = false
    }

    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    // MARK: NSWindowDelegate

    /// Hides only once keyboard focus has actually left littlelog. System windows that live in
    /// this process (text input, Writing Tools, autocorrection) can briefly take key status.
    func windowDidResignKey(_ notification: Notification) {
        Task { [weak self] in
            await Task.yield()
            guard let self, !self.panel.isKeyWindow, NSApp.keyWindow == nil else { return }
            self.hide(.focusLost)
        }
    }

    func windowDidMove(_ notification: Notification) {
        guard !isPositioning, panel.isVisible, let display = panel.screen?.displayID else { return }
        draggedOrigins[display] = panel.frame.origin
    }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        state.undoManager
    }

    // MARK: Setup

    private func configurePanel() {
        panel.title = "littlelog"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.isMovable = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.hasShadow = true
        panel.delegate = self
        panel.keyHandler = { [weak self] event in
            self?.handleKey(event) ?? false
        }
    }

    /// The hosting controller bridges SwiftUI `.toolbar` and `.searchable` into the panel's real
    /// NSToolbar, so the system draws them as native Liquid Glass toolbar items.
    private func installContent(container: ModelContainer) {
        let root = RootView()
            .environment(state)
            .modelContainer(container)
        let hosting = NSHostingController(rootView: root)
        hosting.sceneBridgingOptions = [.toolbars, .title]
        hosting.sizingOptions = []
        panel.contentViewController = hosting
        panel.setContentSize(Style.panelSize)
        panel.toolbarStyle = .unified
    }

    /// Opens on the display under the pointer: where the user last dragged it there, else centered.
    private func position() {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        else { return }

        let visible = screen.visibleFrame
        let size = panel.frame.size
        var origin = NSPoint(
            x: (visible.midX - size.width / 2).rounded(),
            y: (visible.midY - size.height / 2).rounded()
        )
        if let display = screen.displayID,
           let dragged = draggedOrigins[display],
           visible.contains(NSRect(origin: dragged, size: size)) {
            origin = dragged
        }

        isPositioning = true
        panel.setFrameOrigin(origin)
        isPositioning = false
    }

    // MARK: Outside clicks

    /// Global monitors see clicks routed to other apps. Because littlelog never becomes the active
    /// app, clicks inside its own panel can be reported here too, so the pointer is checked first.
    private func installOutsideClickMonitor() {
        guard outsideClickMonitor == nil else { return }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.panel.frame.contains(NSEvent.mouseLocation) else { return }
                self.hide(.clickOutside)
            }
        }
    }

    private func removeOutsideClickMonitor() {
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
            self.outsideClickMonitor = nil
        }
    }

    // MARK: Keyboard

    private func handleKey(_ event: NSEvent) -> Bool {
        if let textView = panel.firstResponder as? NSTextView, textView.hasMarkedText() {
            return false
        }
        let flags = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function])

        if flags == .command, let key = event.charactersIgnoringModifiers?.lowercased() {
            switch key {
            case "1": state.select(.notes)
            case "2": state.select(.today)
            case "n": state.newItem()
            case "f": state.focusSearch()
            case "w": hide(.keyboard)
            default: return false
            }
            return true
        }

        guard flags.isEmpty else { return false }
        switch Int(event.keyCode) {
        case kVK_Escape:
            if !state.handleEscape() { hide(.keyboard) }
            return true
        case kVK_Return where !(panel.firstResponder is NSText):
            // Return on the focused notes list opens the selection; text fields keep their own Return.
            guard state.section == .notes, state.openNote == nil, state.highlightedNoteID != nil else { return false }
            state.openHighlightedNote()
            return true
        case kVK_UpArrow:
            return state.moveHighlight(by: -1)
        case kVK_DownArrow:
            return state.moveHighlight(by: 1)
        default:
            return false
        }
    }
}

private extension NSScreen {
    var displayID: CGDirectDisplayID? {
        deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}
