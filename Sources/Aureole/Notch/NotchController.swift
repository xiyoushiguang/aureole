import AppKit
import Combine
import SwiftUI
import AureoleCore

@MainActor
final class NotchViewModel: ObservableObject {
    @Published var isOpen = false
    @Published var pinned = false
    /// Second layer: the session board grown below the usage rows. Always pinned while expanded.
    @Published var expanded = false
    @Published var geometry = NotchGeometry.placeholder

    /// Concave "ears" at the top corners. Zero in both states: nothing may stick out over the menu bar,
    /// and the expanded panel simply hangs from the screen edge with square top corners.
    let openEar: CGFloat = 0
    var ear: CGFloat { isOpen ? openEar : 0 }
    /// How far the closed shape hangs below the notch: just enough for the halo.
    let closedDrop: CGFloat = 6
    /// Invisible margin around the notch that also triggers the hover.
    let hoverMargin: CGFloat = 20
    let openWidth: CGFloat = 580
    /// Envelope the panel window is sized to; the drawn shape is smaller.
    var maxOpenHeight: CGFloat { expanded ? 760 : 360 }
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
        let root = NotchRootView(model: model, store: store, sessions: sessions, settings: settings, actions: actions)
        let host = NSHostingView(rootView: root)
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = host
        installMonitors()
        model.$expanded.removeDuplicates().sink { [weak self] _ in
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

    /// Screen-space rect of the expanded panel.
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
        monitors.append(NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { event in
            handler(event)
            return event
        } as Any)
        // The expanded board is pinned, so a click anywhere else is the way to dismiss it.
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.clickedOutside(at: NSEvent.mouseLocation) }
        }) {
            monitors.append(m)
        }
    }

    private func clickedOutside(at point: NSPoint) {
        guard model.isOpen, model.expanded, !openRect.contains(point) else { return }
        setOpen(false)
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
        if !open { model.pinned = false; model.expanded = false }
    }

    func toggleExpanded() {
        if model.expanded {
            model.expanded = false
            return
        }
        if !model.isOpen { setOpen(true) }
        model.expanded = true
        model.pinned = true
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
