import AppKit
import Carbon.HIToolbox
import AureoleCore

/// ⌃⌥⌘A anywhere hides or shows Aureole (for screen sharing and recordings). A Carbon hot key: it needs no
/// Accessibility permission. Three modifiers, so it does not take a shortcut other apps already use
/// (⌘⌥H, for one, is "Hide Others" everywhere).
@MainActor
final class HotKey {
    static let shared = HotKey()
    static let display = "⌃⌥⌘A"
    private var ref: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    fileprivate var action: (() -> Void)?

    func register(_ action: @escaping () -> Void) {
        self.action = action
        guard ref == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { HotKey.shared.action?() } }
            return noErr
        }, 1, &spec, nil, &handlerRef)
        let id = EventHotKeyID(signature: OSType(0x4155_524F), id: 1)   // "AURO"
        let status = RegisterEventHotKey(UInt32(kVK_ANSI_A), UInt32(cmdKey | optionKey | controlKey), id,
                                         GetApplicationEventTarget(), 0, &ref)
        if status != noErr { AureoleLog.shared.log("hot key \(Self.display) not available (\(status))") }
    }
}
