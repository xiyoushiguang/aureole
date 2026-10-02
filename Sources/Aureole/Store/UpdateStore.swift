import AppKit
import SwiftUI
import Combine
import AureoleCore

/// Knows whether a newer release is out. Checks at most once a day, shortly after launch and then daily.
@MainActor
final class UpdateStore: ObservableObject {
    static let shared = UpdateStore()

    @Published private(set) var available: UpdateChecker.Release?
    @Published private(set) var checking = false
    private var timer: Timer?
    private let lastCheckKey = "lastUpdateCheck"

    func start(enabled: @escaping () -> Bool) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in
            if enabled() { self?.check(force: false) }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { if enabled() { self?.check(force: false) } }
        }
    }

    func check(force: Bool) {
        let last = UserDefaults.standard.double(forKey: lastCheckKey)
        guard force || Date().timeIntervalSince1970 - last > 86400, !checking else { return }
        checking = true
        Task { [weak self] in
            let release = await UpdateChecker.check()
            await MainActor.run {
                guard let self else { return }
                self.checking = false
                self.available = release
                UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: self.lastCheckKey)
                if let release { AureoleLog.shared.log("update available: \(release.version)") }
            }
        }
    }

    func openRelease() {
        NSWorkspace.shared.open(available?.url ?? UpdateChecker.releasesPage)
    }
}

/// "New version 0.3.1 ›" for the panel footers; nothing when up to date.
struct UpdateLink: View {
    @ObservedObject var updates = UpdateStore.shared

    var body: some View {
        if let r = updates.available {
            Button(L10n.f("New version %@ ›", r.version)) { updates.openRelease() }
                .foregroundStyle(Theme.amber)
                .help(r.url.absoluteString)
        }
    }
}
