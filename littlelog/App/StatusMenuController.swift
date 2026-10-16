import AppKit
import OSLog
import ServiceManagement
import UniformTypeIdentifiers

/// The menu bar item: open the panel, manage assistant (MCP) access, launch at login, quit.
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
        menu.addItem(.sectionHeader(title: "ChatGPT & Codex"))
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
        let toggle = item("Allow Access", #selector(toggleAssistantAccess))
        toggle.state = assistant.isEnabled ? .on : .off
        menu.addItem(toggle)

        switch assistant.status {
        case .off:
            menu.addItem(note("Lets ChatGPT and Codex read and add your tasks"))
            return
        case .starting:
            menu.addItem(note("Starting…"))
        case .running:
            menu.addItem(note("Listening on 127.0.0.1:\(AssistantAccess.port)"))
        case .failed(let message):
            menu.addItem(note("Couldn't start: \(message)"))
        }

        menu.addItem(item("Set Up Codex & ChatGPT Desktop…", #selector(setUpCodex)))
        menu.addItem(item("Copy Codex Configuration", #selector(copyCodexConfiguration)))
        menu.addItem(item("Copy Tunnel Command for ChatGPT Web & Phone", #selector(copyTunnelCommand)))
        menu.addItem(item("Reset Access Token…", #selector(resetToken)))
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

    /// Adds littlelog to `~/.codex/config.toml`, which the Codex CLI and the ChatGPT desktop app
    /// share. The sandbox only allows writing a file the user picks, so they confirm it here.
    @objc private func setUpCodex() {
        guard let assistant else { return }
        NSApp.activate()
        let picker = NSOpenPanel()
        picker.title = "Set Up Codex & ChatGPT Desktop"
        picker.message = "Choose config.toml in your .codex folder. littlelog adds its own section and leaves the rest unchanged."
        picker.prompt = "Add littlelog"
        picker.directoryURL = Self.realHomeDirectory.appending(path: ".codex", directoryHint: .isDirectory)
        picker.showsHiddenFiles = true
        picker.canChooseDirectories = false
        picker.allowsMultipleSelection = false
        picker.allowedContentTypes = [UTType(filenameExtension: "toml") ?? .plainText]
        guard picker.runModal() == .OK, let url = picker.url else { return }

        do {
            let existing = try String(contentsOf: url, encoding: .utf8)
            let merged = CodexConfig.merging(existing, block: assistant.codexConfigBlock)
            // Written in place: the sandbox grants access to this file only, not its folder.
            try merged.write(to: url, atomically: false, encoding: .utf8)
            showAlert(
                "littlelog is set up",
                "Codex and the ChatGPT desktop app will load it in their next session. Restart them if they're open.",
                style: .informational
            )
        } catch {
            Logger.app.error("couldn't update Codex config: \(error.localizedDescription, privacy: .public)")
            showAlert(
                "Couldn't update config.toml",
                "\(error.localizedDescription)\n\nUse Copy Codex Configuration and paste it into the file instead.",
                style: .warning
            )
        }
    }

    @objc private func copyCodexConfiguration() {
        guard let assistant else { return }
        copy(assistant.codexConfigBlock)
    }

    @objc private func copyTunnelCommand() {
        guard let assistant else { return }
        copy(assistant.tunnelCommand)
    }

    @objc private func resetToken() {
        guard let assistant else { return }
        NSApp.activate()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Reset the access token?"
        alert.informativeText = "Codex, the ChatGPT desktop app and any tunnel using the current token stop working until you set them up again."
        alert.addButton(withTitle: "Reset Token")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try assistant.resetToken()
        } catch {
            Logger.app.error("couldn't reset token: \(error.localizedDescription, privacy: .public)")
            showAlert("Couldn't reset the token", error.localizedDescription, style: .warning)
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
            showAlert("Couldn't change Open at Login", error.localizedDescription, style: .warning)
        }
    }

    // MARK: Helpers

    private func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private func showAlert(_ title: String, _ message: String, style: NSAlert.Style) {
        NSApp.activate()
        let alert = NSAlert()
        alert.alertStyle = style
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }

    /// The user's real home folder; inside the sandbox `homeDirectoryForCurrentUser` is the container.
    private static var realHomeDirectory: URL {
        if let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir {
            return URL(filePath: String(cString: directory), directoryHint: .isDirectory)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }
}
