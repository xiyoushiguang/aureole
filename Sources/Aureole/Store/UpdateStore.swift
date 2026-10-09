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
    /// Progress text while an update downloads and installs; nil otherwise.
    @Published private(set) var installing: String?
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

    /// Downloads the release's disk image, checks it is signed by the same developer as this copy and passes
    /// Gatekeeper, swaps it in (the old copy goes to the Trash) and relaunches. Anything unexpected falls back
    /// to opening the release page.
    func install() {
        guard let release = available, installing == nil else { return }
        guard let dmg = release.dmgURL else { openRelease(); return }
        let appPath = Bundle.main.bundlePath
        installing = L10n.t("Downloading…")
        Task.detached(priority: .userInitiated) {
            do {
                let staged = try await Updater.prepare(dmg: dmg, currentApp: appPath, version: release.version) { text in
                    Task { @MainActor in UpdateStore.shared.installing = text }
                }
                try Updater.swapAndRelaunch(staged: staged, currentApp: appPath, version: AureoleInfo.version)
                AureoleLog.shared.log("update \(release.version) staged; relaunching")
                await MainActor.run { NSApp.terminate(nil) }
            } catch {
                AureoleLog.shared.log("update failed: \(error.localizedDescription)")
                await MainActor.run {
                    UpdateStore.shared.installing = nil
                    let alert = NSAlert()
                    alert.messageText = L10n.t("Could not install the update")
                    alert.informativeText = error.localizedDescription + "\n\n" + L10n.t("The release page opens so you can install it by hand.")
                    alert.runModal()
                    UpdateStore.shared.openRelease()
                }
            }
        }
    }
}

/// The steps of an in-place update, each checked; nothing is replaced until the new copy has passed them all.
enum Updater {
    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ s: String) { errorDescription = s }
    }

    @discardableResult
    static func run(_ tool: String, _ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        guard p.terminationStatus == 0 else {
            throw Failure("\((tool as NSString).lastPathComponent) failed: \(text.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return text
    }

    static func team(of app: String) -> String? {
        (try? run("/usr/bin/codesign", ["-dv", app])).flatMap(UpdateChecker.teamIdentifier(inCodesignOutput:))
    }

    /// Returns the path of the verified new app, copied out of the disk image into a temporary folder.
    static func prepare(dmg: URL, currentApp: String, version: String, progress: @escaping (String) -> Void) async throws -> String {
        // Only an app the user can replace, run from where they put it (not a translocated, read-only copy).
        let parent = (currentApp as NSString).deletingLastPathComponent
        guard !currentApp.contains("/AppTranslocation/"), FileManager.default.isWritableFile(atPath: parent) else {
            throw Failure(L10n.t("Aureole is running from a location it cannot update. Move it to Applications first."))
        }
        guard let myTeam = team(of: currentApp) else {
            throw Failure(L10n.t("This copy is not signed with a Developer ID (a local build), so it cannot check an update."))
        }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("aureole-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let (downloaded, response) = try await URLSession.shared.download(from: dmg)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure(L10n.t("The download failed.")) }
        let image = work.appendingPathComponent("update.dmg")
        try FileManager.default.moveItem(at: downloaded, to: image)

        progress(L10n.t("Checking…"))
        let mount = work.appendingPathComponent("mnt").path
        try run("/usr/bin/hdiutil", ["attach", image.path, "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount, "-quiet"])
        defer { _ = try? run("/usr/bin/hdiutil", ["detach", mount, "-quiet", "-force"]) }
        guard let name = try FileManager.default.contentsOfDirectory(atPath: mount).first(where: { $0.hasSuffix(".app") }) else {
            throw Failure(L10n.t("The disk image has no app in it."))
        }
        let staged = work.appendingPathComponent(name).path
        try run("/usr/bin/ditto", [(mount as NSString).appendingPathComponent(name), staged])

        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", staged])
        guard team(of: staged) == myTeam else { throw Failure(L10n.t("The update is not signed by the same developer. Not installed.")) }
        try run("/usr/sbin/spctl", ["--assess", "--type", "execute", staged])   // notarized, accepted by Gatekeeper
        let newVersion = Bundle(path: staged)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        guard newVersion == version else { throw Failure(L10n.f("Expected version %@, found %@.", version, newVersion)) }
        return staged
    }

    /// A small script waits for this process to quit, moves the old copy to the Trash, puts the new one in its
    /// place and opens it.
    static func swapAndRelaunch(staged: String, currentApp: String, version: String) throws {
        let trash = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash/Aureole \(version) \(Int(Date().timeIntervalSince1970)).app").path
        let script = """
        while kill -0 \(getpid()) 2>/dev/null; do sleep 0.2; done
        mv "$1" "$3" && /usr/bin/ditto "$2" "$1" && /usr/bin/xattr -dr com.apple.quarantine "$1" 2>/dev/null
        if [ -d "$1" ]; then /usr/bin/open "$1"; else mv "$3" "$1"; /usr/bin/open "$1"; fi
        """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script, "aureole-update", currentApp, staged, trash]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
    }
}

/// "New version 0.3.1 ›" for the panel footers; nothing when up to date.
struct UpdateLink: View {
    @ObservedObject var updates = UpdateStore.shared

    var body: some View {
        if let r = updates.available {
            Button(updates.installing ?? L10n.f("Update to %@ ›", r.version)) { updates.install() }
                .foregroundStyle(Theme.amber)
                .disabled(updates.installing != nil)
                .help(L10n.t("Downloads, checks and installs the new version, then reopens Aureole."))
        }
    }
}
