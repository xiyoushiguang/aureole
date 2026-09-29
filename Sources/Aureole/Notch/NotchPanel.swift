import AppKit

/// Borderless, non-activating panel that floats above the menu bar on every Space.
final class NotchPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        animationBehavior = .none
        appearance = NSAppearance(named: .darkAqua)   // the panel is always black; never inherit light-mode text colours
        acceptsMouseMovedEvents = true
        ignoresMouseEvents = true
        isFloatingPanel = true
        // Must come after isFloatingPanel: that setter resets the level.
        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 3)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
