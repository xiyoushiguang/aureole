import AppKit
import SwiftUI
import AureoleCore

/// `--film <dir> [--scene journey|compare]`: draws the open panel with the demo data frame by frame, the sky in
/// motion, into numbered JPEG files (30 a second) and quits; ffmpeg turns them into a video. A way to look at
/// motion before building it for real: the live panel would run the same motion on Core Animation layers, not by
/// redrawing itself thirty times a second as this does.
@MainActor
enum Filmer {
    static let fps = 30.0

    /// What one frame shows.
    struct Frame {
        /// How much of the demo's five-hour window is used.
        var peak: Double = 62
        var film = SkyFilm()
        /// The release-notes session has finished its turn.
        var notesDone = false
        /// Claude's numbers are old.
        var stale = false
    }

    private static func smooth(_ a: Double, _ b: Double, _ x: Double) -> Double {
        let k = min(1, max(0, (x - a) / (b - a)))
        return k * k * (3 - 2 * k)
    }

    /// 24 seconds through the four skies: plenty left, running short (a task finishes on the way), nearly gone,
    /// then numbers gone old.
    static func journey(_ t: Double) -> Frame {
        var f = Frame()
        switch t {
        case ..<5: f.peak = 24
        case ..<8: f.peak = 24 + 38 * smooth(5, 8, t)
        case ..<13: f.peak = 62
        case ..<16: f.peak = 62 + 35 * smooth(13, 16, t)
        default: f.peak = 97
        }
        // The demo's forecast starts running dry at about 43% used; embers begin at 95%.
        var sky = SkyPalette.mix(SkyMood.calm.palette, SkyMood.dusk.palette, smooth(38, 48, f.peak))
        sky = .mix(sky, SkyMood.ember.palette, smooth(86, 95, f.peak))
        let old = smooth(20, 21.2, t)
        f.stale = t >= 20
        f.film.palette = .mix(sky, SkyMood.stale.palette, old)
        f.film.t = t
        f.film.live = 1 - old
        let falls = 9.6
        f.notesDone = t >= falls
        if t >= falls, t < falls + 0.9 { f.film.meteor = (t - falls) / 0.9 }
        f.film.newStar = min(1, max(0, (t - falls - 0.75) / 0.6))
        return f
    }

    /// Six seconds at 62% used, for setting the plain sky (`AUREOLE_SKY=flat`) beside the new one.
    static func compare(_ t: Double) -> Frame {
        var f = Frame()
        f.film.t = t
        return f
    }

    static func run(to dir: URL, scene: String, language: Language) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let seconds = scene == "compare" ? 6.0 : 24.0
        let frames = (0..<Int(seconds * fps)).map { i in scene == "compare" ? compare(Double(i) / fps) : journey(Double(i) / fps) }

        let settings = SettingsStore(defaults: LaunchMode.demoDefaults())
        settings.language = language
        // The film moves the sky, the lit stretch and the forecast itself; the live layers would not be captured.
        settings.ambientMotion = false
        let now = Date()
        let sessions = SessionStore(settings: settings)
        let ledger = LedgerStore()
        ledger.freeze(DemoData.ledger(now: now))
        let model = NotchViewModel()
        model.geometry = .placeholder
        model.isOpen = true
        model.pinned = true
        let size = CGSize(width: model.openWidth, height: model.maxOpenHeight)

        var store = UsageStore(settings: settings, demo: true)
        var shown: (peak: Double, stale: Bool, notesDone: Bool)?
        func prepare(_ f: Frame) {
            if shown?.peak != f.peak || shown?.stale != f.stale {
                store = UsageStore(settings: settings, demo: true)
                store.loadDemo(DemoData.usage(now: now, peak: f.peak))
                store.loadDemoTrouble(.claude, f.stale ? .expired(L10n.f("%@ token expired. It renews by itself the next time %@ runs.", "Claude", "Claude Code")) : nil)
            }
            if shown?.notesDone != f.notesDone {
                let d = DemoData.sessions(now: now, notesDone: f.notesDone)
                sessions.loadDemo(d.list, titles: d.titles, context: d.context, approvals: d.approvals, now: now)
                model.waitingCount = sessions.board.waiting.count
                model.doneCount = sessions.board.done.count
            }
            shown = (f.peak, f.stale, f.notesDone)
        }
        func root(_ f: Frame) -> AnyView {
            var film = f.film
            film.now = now
            return AnyView(NotchRootView(model: model, store: store, sessions: sessions, ledger: ledger, settings: settings, actions: nil)
                .frame(width: size.width, height: size.height, alignment: .top)
                .background(Color(white: 0.16))
                .environment(\.skyFilm, film)
                // Every frame is its final state: nothing eases in over the frames after it.
                .transaction { $0.disablesAnimations = true })
        }

        prepare(frames[0])
        let host = NSHostingView(rootView: root(frames[0]))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -30_000, y: -30_000))
        window.orderFrontRegardless()

        var crop = CGRect.zero
        func capture(_ i: Int) {
            guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
            host.cacheDisplay(in: host.bounds, to: rep)
            let scale = CGFloat(rep.pixelsWide) / host.bounds.width
            if crop.isEmpty {
                // The same crop for every frame, with even pixel sizes for the video.
                let height = (min(size.height, model.openContentHeight + 24) * scale / 2).rounded(.down) * 2
                crop = CGRect(x: 0, y: 0, width: (size.width * scale / 2).rounded(.down) * 2, height: height)
            }
            guard let cg = rep.cgImage?.cropping(to: crop),
                  let jpeg = NSBitmapImageRep(cgImage: cg).representation(using: .jpeg, properties: [.compressionFactor: 0.93]) else { return }
            try? jpeg.write(to: dir.appendingPathComponent(String(format: "f%05d.jpg", i)))
        }
        func step(_ i: Int) {
            guard i < frames.count else {
                print("wrote \(frames.count) frames to \(dir.path)")
                window.orderOut(nil)
                NSApp.terminate(nil)
                return
            }
            prepare(frames[i])
            host.rootView = root(frames[i])
            // A turn of the run loop for SwiftUI to take the new values in.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.015) {
                host.layoutSubtreeIfNeeded()
                capture(i)
                step(i + 1)
            }
        }
        // Let SwiftUI lay out and measure the lanes before the first frame.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { step(0) }
    }
}
