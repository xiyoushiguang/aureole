import AppKit
import SwiftUI
import AureoleCore

/// `--snapshot <dir>`: draws the panel with the demo data into PNG files and quits. Used for README pictures and
/// to compare the panel before and after a change without hovering over a real notch.
@MainActor
enum Snapshotter {
    /// What gets drawn: the open panel, the same with the waiting session's card up, and the closed notch.
    struct Shot {
        let name: String
        let open: Bool
        let focus: String?
    }

    static let shots = [Shot(name: "panel", open: true, focus: nil),
                        Shot(name: "panel-approval", open: true, focus: DemoData.billing),
                        Shot(name: "closed", open: false, focus: nil)]

    static func run(to dir: URL, language: Language) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let settings = SettingsStore(defaults: LaunchMode.demoDefaults())
        settings.language = language
        // Still pictures: the breathing glow and flowing forecast are live layers that a snapshot cannot hold.
        settings.ambientMotion = false
        let store = UsageStore(settings: settings, demo: true)
        let sessions = SessionStore(settings: settings)
        let ledger = LedgerStore()
        let now = Date()
        store.loadDemo(DemoData.usage(now: now))
        let d = DemoData.sessions(now: now)
        sessions.loadDemo(d.list, titles: d.titles, context: d.context, approvals: d.approvals, now: now)
        ledger.freeze(DemoData.ledger(now: now))
        render(shots, settings: settings, store: store, sessions: sessions, ledger: ledger, dir: dir, language: language)
    }

    private static func render(_ shots: [Shot], settings: SettingsStore, store: UsageStore, sessions: SessionStore,
                               ledger: LedgerStore, dir: URL, language: Language) {
        guard let shot = shots.first else { NSApp.terminate(nil); return }
        // The panel picks up a focused lane from the argument domain, as `-debugFocusLane` does on a real launch.
        UserDefaults.standard.setVolatileDomain(shot.focus.map { ["debugFocusLane": $0] } ?? [:], forName: UserDefaults.argumentDomain)
        let model = NotchViewModel()
        model.geometry = .placeholder
        model.isOpen = shot.open
        model.pinned = shot.open
        model.waitingCount = sessions.board.waiting.count
        model.doneCount = sessions.board.done.count
        let size = CGSize(width: model.openWidth, height: model.maxOpenHeight)
        let root = NotchRootView(model: model, store: store, sessions: sessions, ledger: ledger, settings: settings, actions: nil)
            .frame(width: size.width, height: size.height, alignment: .top)
            .background(Color(white: 0.16))     // a desktop-grey backdrop, so the black panel has an edge
        let host = NSHostingView(rootView: root)
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -30_000, y: -30_000))
        window.orderFrontRegardless()
        // Let SwiftUI lay out, measure the lanes and settle its springs before drawing.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            let height = shot.open ? min(size.height, model.openContentHeight + 24) : model.closedSize.height + 24
            let width = shot.open ? size.width : model.closedSize.width + 160
            let crop = CGRect(x: (size.width - width) / 2, y: 0, width: width, height: height)
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                let scale = CGFloat(rep.pixelsWide) / host.bounds.width
                if let cg = rep.cgImage?.cropping(to: CGRect(x: crop.minX * scale, y: crop.minY * scale,
                                                             width: crop.width * scale, height: crop.height * scale)),
                   let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) {
                    let suffix = language == .chineseSimplified ? ".zh" : ""
                    let url = dir.appendingPathComponent(shot.name + suffix + ".png")
                    try? png.write(to: url)
                    print("wrote \(url.path)")
                }
            }
            window.orderOut(nil)
            render(Array(shots.dropFirst()), settings: settings, store: store, sessions: sessions, ledger: ledger, dir: dir, language: language)
        }
    }
}
