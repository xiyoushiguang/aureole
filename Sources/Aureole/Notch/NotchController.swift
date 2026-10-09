import AppKit
import Combine
import SwiftUI
import AureoleCore

@MainActor
final class NotchViewModel: ObservableObject {
    @Published var isOpen = false
    @Published var pinned = false
    @Published var geometry = NotchGeometry.placeholder

    /// Concave "ears" at the top corners. Zero in both states: nothing may stick out over the menu bar,
    /// and the open panel simply hangs from the screen edge with square top corners.
    let openEar: CGFloat = 0
    var ear: CGFloat { isOpen ? openEar : 0 }
    /// Sessions waiting on you / finished and unseen; shown under the closed notch so you need not hover to find out.
    @Published var waitingCount = 0
    @Published var doneCount = 0
    var needsAttention: Bool { waitingCount + doneCount > 0 }
    /// How far the closed shape hangs below the notch: just enough for the halo, or for a line of status when something needs you.
    var closedDrop: CGFloat { needsAttention ? 24 : 6 }
    /// Invisible margin around the notch that also triggers the hover.
    let hoverMargin: CGFloat = 20
    /// The horizon layout needs a much wider panel than the list.
    @Published var horizon = true
    var openWidth: CGFloat { horizon ? min(1000, geometry.screenFrame.width - 80) : 580 }
    /// Envelope the panel window is sized to; the drawn shape is smaller.
    var maxOpenHeight: CGFloat { min(horizon ? 900 : 760, geometry.screenFrame.height - 40) }
    @Published var openContentHeight: CGFloat = 200
    var openSize: CGSize { CGSize(width: openWidth, height: min(maxOpenHeight, openContentHeight)) }

    var closedSize: CGSize {
        CGSize(width: geometry.notchRect.width, height: geometry.notchRect.height + closedDrop)
    }
}

@MainActor
final class NotchController {
    let panel = NotchPanel()
    let model = NotchViewModel()
    private var monitors: [Any] = []
    private var openWork: DispatchWorkItem?
    private var closeWork: DispatchWorkItem?

    private var cancellables: Set<AnyCancellable> = []

    init(store: UsageStore, sessions: SessionStore, settings: SettingsStore, actions: AppActions) {
        sessions.$board.sink { [weak self] b in
            guard let model = self?.model else { return }
            if model.waitingCount != b.waiting.count { model.waitingCount = b.waiting.count }
            if model.doneCount != b.done.count { model.doneCount = b.done.count }
        }.store(in: &cancellables)
        let root = NotchRootView(model: model, store: store, sessions: sessions, settings: settings, actions: actions)
        let host = NSHostingView(rootView: root)
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = host
        installMonitors()
        settings.$panelLayout.removeDuplicates().sink { [weak self] layout in
            self?.model.horizon = layout == .horizon
            DispatchQueue.main.async { self?.layout() }
        }.store(in: &cancellables)
    }

    func attach(to screen: NSScreen?) {
        model.geometry = NotchGeometry.detect(on: screen)
        layout()
        panel.orderFrontRegardless()
    }

    private func layout() {
        let g = model.geometry
        let size = CGSize(width: model.openWidth, height: model.maxOpenHeight)
        let frame = CGRect(x: g.notchRect.midX - size.width / 2, y: g.screenFrame.maxY - size.height,
                           width: size.width, height: size.height)
        panel.setFrame(frame, display: true)
    }

    /// Screen-space rect that opens the panel when hovered (closed state).
    private var hoverRect: CGRect {
        let n = model.geometry.notchRect
        return CGRect(x: n.minX - model.hoverMargin, y: n.minY - model.closedDrop - 10,
                      width: n.width + 2 * model.hoverMargin, height: n.height + model.closedDrop + 10)
    }

    /// Screen-space rect of the open panel.
    private var openRect: CGRect {
        let g = model.geometry
        let s = model.openSize
        return CGRect(x: g.notchRect.midX - s.width / 2, y: g.screenFrame.maxY - s.height, width: s.width, height: s.height)
    }

    private func installMonitors() {
        let handler: (NSEvent) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.mouseMoved(to: NSEvent.mouseLocation) }
        }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: handler) {
            monitors.append(m)
        }
        // Esc closes the open panel. macOS only hands another app's key presses to a monitor once the user has
        // granted Accessibility (Settings → General offers it); without that this simply never fires.
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard event.keyCode == 53 else { return }
            MainActor.assumeIsolated { if self?.model.isOpen == true { self?.setOpen(false) } }
        }) {
            monitors.append(m)
        }
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { event in
            handler(event)
            return event
        } as Any)
    }

    private func mouseMoved(to point: NSPoint) {
        if model.isOpen {
            if model.pinned { return }
            if openRect.insetBy(dx: -10, dy: -10).contains(point) {
                closeWork?.cancel()
                closeWork = nil
            } else if closeWork == nil {
                let work = DispatchWorkItem { [weak self] in
                    MainActor.assumeIsolated { self?.setOpen(false) }
                }
                closeWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
            }
        } else {
            if hoverRect.contains(point) {
                if openWork == nil {
                    let work = DispatchWorkItem { [weak self] in
                        MainActor.assumeIsolated { self?.setOpen(true) }
                    }
                    openWork = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
                }
            } else {
                openWork?.cancel()
                openWork = nil
            }
        }
    }

    private func setOpen(_ open: Bool) {
        openWork?.cancel(); openWork = nil
        closeWork?.cancel(); closeWork = nil
        guard model.isOpen != open else { return }
        model.isOpen = open
        panel.ignoresMouseEvents = !open
        if !open { model.pinned = false }
    }

    func setPinnedOpen(_ open: Bool) {
        setOpen(open)
        model.pinned = open
    }

    func togglePinned() {
        if model.isOpen && model.pinned {
            setOpen(false)
        } else {
            setOpen(true)
            model.pinned = true
        }
    }
}
