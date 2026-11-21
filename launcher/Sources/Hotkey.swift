// A system-wide ⌃⌥⌘K through Carbon's hot key API (no Accessibility permission needed).
import Carbon

enum Hotkey {
    static var action: (() -> Void)?
    private static var ref: EventHotKeyRef?

    static func register(_ handler: @escaping () -> Void) {
        action = handler
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { Hotkey.action?() }
            return noErr
        }, 1, &spec, nil, nil)
        let id = EventHotKeyID(signature: OSType(0x4349_4750), id: 1)  // "CIGP"
        RegisterEventHotKey(UInt32(kVK_ANSI_K), UInt32(controlKey | optionKey | cmdKey), id,
                            GetApplicationEventTarget(), 0, &ref)
    }
}
