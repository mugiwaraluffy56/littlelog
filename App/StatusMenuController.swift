import AppKit
import OSLog
import ServiceManagement

/// The menu bar item: open the panel, the ChatGPT connection, launch at login, quit.
/// The menu is rebuilt each time it opens so every item reflects the current state.
final class StatusMenuController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let panel: PanelController
    private let assistant: AssistantAccess?
    private let assistantSetupError: String?
    private let shortcutAvailable: Bool

    init(panel: PanelController, assistant: AssistantAccess?, assistantSetupError: String?, shortcutAvailable: Bool) {
        self.panel = panel
        self.assistant = assistant
        self.assistantSetupError = assistantSetupError
        self.shortcutAvailable = shortcutAvailable
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        if let button = statusItem.button {
            let image = NSImage(systemSymbolName: "note.text", accessibilityDescription: "littlelog")
            image?.isTemplate = true
            button.image = image
        }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let open = item("Open littlelog", #selector(openPanel))
        if shortcutAvailable {
            open.keyEquivalent = "l"
            open.keyEquivalentModifierMask = [.command, .shift]
        }
        menu.addItem(open)
        if !shortcutAvailable {
            menu.addItem(note("⌘⇧L is in use by another app"))
        }

        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "ChatGPT"))
        addAssistantItems(to: menu)

        menu.addItem(.separator())
        let login = item("Open at Login", #selector(toggleOpenAtLogin))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit littlelog", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func addAssistantItems(to menu: NSMenu) {
        guard let assistant else {
            menu.addItem(note("Unavailable: \(assistantSetupError ?? "unknown error")"))
            return
        }
        let toggle = item("Allow ChatGPT Access", #selector(toggleAssistantAccess))
        toggle.state = assistant.isEnabled ? .on : .off
        menu.addItem(toggle)

        switch assistant.status {
        case .stopped:
            menu.addItem(note("Lets ChatGPT read and add your tasks"))
            return
        case .connecting:
            menu.addItem(note("Connecting…"))
        case .connected:
            menu.addItem(note("Ready"))
        case .offline(let reason):
            menu.addItem(note("Offline: \(reason)"))
        }

        let connected = assistant.connectedAppNames
        if !connected.isEmpty {
            menu.addItem(note("Signed in: \(connected.joined(separator: ", "))"))
        }
        menu.addItem(item("Copy ChatGPT Link", #selector(copyConnectorURL)))
        if !connected.isEmpty {
            menu.addItem(item("Sign Out All Apps…", #selector(disconnectAll)))
        }
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    private func note(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    // MARK: Actions

    @objc private func openPanel() {
        panel.show()
    }

    @objc private func toggleAssistantAccess() {
        guard let assistant else { return }
        assistant.setEnabled(!assistant.isEnabled)
    }

    @objc private func copyConnectorURL() {
        guard let assistant else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(assistant.connectorURL, forType: .string)
    }

    @objc private func disconnectAll() {
        guard let assistant else { return }
        NSApp.activate()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Sign out all apps?"
        alert.informativeText = "ChatGPT will ask you to sign in again, and you'll need to allow it on this Mac."
        alert.addButton(withTitle: "Sign Out")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try assistant.disconnectAll()
        } catch {
            Logger.app.error("couldn't sign out apps: \(error.localizedDescription, privacy: .public)")
            showAlert("Couldn't sign out apps", error.localizedDescription)
        }
    }

    @objc private func toggleOpenAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled {
                try service.unregister()
            } else {
                try service.register()
                if service.status == .requiresApproval {
                    SMAppService.openSystemSettingsLoginItems()
                }
            }
        } catch {
            Logger.app.error("open at login failed: \(error.localizedDescription, privacy: .public)")
            showAlert("Couldn't change Open at Login", error.localizedDescription)
        }
    }

    private func showAlert(_ title: String, _ message: String) {
        NSApp.activate()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }
}
