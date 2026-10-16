import Carbon.HIToolbox

/// A single system-wide shortcut registered through Carbon, which needs no extra permissions.
final class HotkeyManager {
    enum RegistrationError: LocalizedError {
        case handlerInstallFailed(OSStatus)
        case shortcutUnavailable(OSStatus)

        var errorDescription: String? {
            switch self {
            case .handlerInstallFailed(let status):
                "couldn't install the shortcut handler (OSStatus \(status))"
            case .shortcutUnavailable(let status):
                "the shortcut is already in use by another app (OSStatus \(status))"
            }
        }
    }

    private static let signature: OSType = 0x4C4C_4F47 // 'LLOG'

    private let action: () -> Void
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    init(action: @escaping () -> Void) {
        self.action = action
    }

    /// Registers ⌘⇧L by default. Calling again replaces any previous registration.
    func register(
        keyCode: UInt32 = UInt32(kVK_ANSI_L),
        modifiers: UInt32 = UInt32(cmdKey | shiftKey)
    ) throws(RegistrationError) {
        unregister()

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            hotKeyEventHandler,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &handlerRef
        )
        guard installStatus == noErr else {
            handlerRef = nil
            throw .handlerInstallFailed(installStatus)
        }

        let hotKeyID = EventHotKeyID(signature: Self.signature, id: 1)
        let registerStatus = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        guard registerStatus == noErr else {
            hotKeyRef = nil
            unregister()
            throw .shortcutUnavailable(registerStatus)
        }
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let handlerRef {
            RemoveEventHandler(handlerRef)
            self.handlerRef = nil
        }
    }

    fileprivate func handle(_ hotKeyID: EventHotKeyID) -> OSStatus {
        guard hotKeyID.signature == Self.signature else { return OSStatus(eventNotHandledErr) }
        action()
        return noErr
    }
}

/// Carbon delivers hot key events on the main event loop.
nonisolated private func hotKeyEventHandler(
    _ nextHandler: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard status == noErr else { return status }
    let receivedID = hotKeyID
    let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
    return MainActor.assumeIsolated {
        manager.handle(receivedID)
    }
}
