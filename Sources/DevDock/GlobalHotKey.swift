import Carbon

/// A system-wide shortcut registered with Carbon's RegisterEventHotKey. It needs no
/// Accessibility permission and no dependency. Swap in the KeyboardShortcuts package later if
/// settings need a shortcut recorder.
final class GlobalHotKey {
    /// Control-Option-M (M for music).
    static let toggleKeyCode = UInt32(kVK_ANSI_M)
    static let toggleModifiers = UInt32(controlKey | optionKey)

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let action: () -> Void

    /// Returns nil if the shortcut can't be registered, for example when another app owns it.
    /// Carbon delivers the event on the main thread.
    init?(keyCode: UInt32, modifiers: UInt32, action: @escaping () -> Void) {
        self.action = action

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let context = Unmanaged.passUnretained(self).toOpaque()
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData in
                guard let userData else { return OSStatus(eventNotHandledErr) }
                Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue().action()
                return OSStatus(noErr)
            },
            1,
            &eventType,
            context,
            &handlerRef
        )
        guard installStatus == OSStatus(noErr) else { return nil }

        let hotKeyID = EventHotKeyID(signature: OSType(0x4444_4B31), id: 1) // "DDK1"
        let registerStatus = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        // On failure, deinit removes the handler installed above.
        guard registerStatus == OSStatus(noErr) else { return nil }
    }

    deinit {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        if let handlerRef { RemoveEventHandler(handlerRef) }
    }
}
