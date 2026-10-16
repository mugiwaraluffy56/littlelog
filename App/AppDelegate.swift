import AppKit
import OSLog
import SwiftData

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var state: AppState?
    private var panelController: PanelController?
    private var hotkey: HotkeyManager?
    private var assistant: AssistantAccess?
    private var statusMenu: StatusMenuController?

    private static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !Self.isRunningTests else { return }

        NSApp.mainMenu = MainMenu.make()

        let container: ModelContainer
        do {
            container = try Persistence.makeContainer()
        } catch {
            presentStorageFailure(error)
            return
        }

        let library = Library(context: container.mainContext)
        library.purgeBlankNotes()
        library.startObservingDayChanges()
        let state = AppState(library: library)
        self.state = state

        let approvals = AccessApprovals()
        let panelController = PanelController(state: state, container: container, approvals: approvals)
        self.panelController = panelController
        // A sign-in request opens the panel so its Allow / Don't Allow prompt is seen right away.
        approvals.onRequest = { [weak panelController] in
            panelController?.show()
        }

        let hotkey = HotkeyManager { [weak panelController] in
            panelController?.toggle()
        }
        var shortcutError: (any Error)?
        do {
            try hotkey.register()
            self.hotkey = hotkey
        } catch {
            shortcutError = error
            Logger.app.error("global shortcut unavailable: \(error.localizedDescription, privacy: .public)")
        }

        var assistantSetupError: String?
        do {
            let assistant = try AssistantAccess(library: library, approvals: approvals)
            assistant.startIfEnabled()
            self.assistant = assistant
        } catch {
            assistantSetupError = error.localizedDescription
            Logger.app.error("assistant access unavailable: \(error.localizedDescription, privacy: .public)")
        }

        statusMenu = StatusMenuController(
            panel: panelController,
            assistant: assistant,
            assistantSetupError: assistantSetupError,
            shortcutAvailable: shortcutError == nil
        )
        panelController.show()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        panelController?.show()
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkey?.unregister()
        state?.prepareForTermination()
    }

    // MARK: Failure

    /// Never falls back to an empty store: that could hide or overwrite the user's existing library.
    private func presentStorageFailure(_ error: any Error) {
        Logger.app.fault("couldn't open the library: \(String(describing: error), privacy: .public)")
        NSApp.activate()
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "littlelog couldn't open its library"
        alert.informativeText = """
        \(error.localizedDescription)

        Nothing was changed or deleted. Quit littlelog and try opening it again.
        """
        alert.addButton(withTitle: "Quit")
        alert.runModal()
        NSApp.terminate(nil)
    }
}
