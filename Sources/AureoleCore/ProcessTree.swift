import Foundation
import Darwin

/// Looking up processes: who an agent's parents are, which terminal it sits on, and which app it runs under.
/// Used by the hook (for "jump to") and by the first-launch scan (to see where the user runs agents).
public enum ProcessTree {
    public struct Info: Equatable, Sendable {
        public var pid: pid_t
        public var ppid: pid_t
        public var name: String
    }

    public static func info(_ pid: pid_t) -> Info? {
        var kp = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &kp, &size, nil, 0) == 0, size > 0 else { return nil }
        return Info(pid: pid, ppid: kp.kp_eproc.e_ppid, name: name(of: &kp))
    }

    /// Every process the user can see.
    public static func all() -> [Info] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0, size > 0 else { return [] }
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride + 16)
        size = procs.count * MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &procs, &size, nil, 0) == 0 else { return [] }
        let n = size / MemoryLayout<kinfo_proc>.stride
        return (0..<n).map { i in Info(pid: procs[i].kp_proc.p_pid, ppid: procs[i].kp_eproc.e_ppid, name: name(of: &procs[i])) }
    }

    private static func name(of kp: inout kinfo_proc) -> String {
        withUnsafePointer(to: &kp.kp_proc.p_comm) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN) + 1) { String(cString: $0) }
        }
    }

    /// "ttys003" for the controlling terminal, or nil when there is none.
    public static func controllingTTY(of pid: pid_t) -> String? {
        var kp = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &kp, &size, nil, 0) == 0, size > 0 else { return nil }
        let dev = kp.kp_eproc.e_tdev
        guard dev != 0, dev != -1, let name = devname(dev, S_IFCHR) else { return nil }
        return String(cString: name)
    }

    public static func executablePath(_ pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return nil }
        return String(cString: buf)
    }

    /// The command line a process was started with (argv), or nil when it cannot be read.
    public static func arguments(_ pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return nil }
        // Layout: argc (Int32), the executable path, NUL padding, then argc NUL-terminated strings.
        let argc = buf.withUnsafeBytes { $0.load(as: Int32.self) }
        var i = MemoryLayout<Int32>.size
        while i < size, buf[i] != 0 { i += 1 }
        while i < size, buf[i] == 0 { i += 1 }
        var args: [String] = []
        while args.count < argc, i < size {
            let start = i
            while i < size, buf[i] != 0 { i += 1 }
            args.append(String(decoding: buf[start..<i], as: UTF8.self))
            i += 1
        }
        return args
    }

    /// Whether an agent was started to run unattended: `claude -p` / `--print`, or `codex exec`.
    public static func isHeadless(arguments args: [String]) -> Bool {
        let rest = args.dropFirst()
        if rest.contains("-p") || rest.contains("--print") { return true }
        if let first = rest.first(where: { !$0.hasPrefix("-") }), first == "exec" || first == "e" {
            return args.first.map { ($0 as NSString).lastPathComponent.hasPrefix("codex") } ?? false
        }
        return false
    }

    /// The path of the outermost .app in an executable path ("/Applications/ChatGPT.app/…/codex" → ChatGPT.app).
    public static func outermostApp(inPath path: String) -> String? {
        guard let r = path.range(of: ".app/") else { return nil }
        return String(path[..<r.lowerBound]) + ".app"
    }

    /// The app at the root of the process tree above `pid`: the terminal or desktop app the user started the
    /// agent from. The top-most ancestor inside a .app wins, so a helper binary nested in its own .app (as the
    /// Claude desktop app ships Claude Code) still resolves to the app the user sees.
    public static func rootAppBundleId(of pid: pid_t) -> String? {
        var current = pid
        var found: String?
        for _ in 0..<32 {
            guard current > 1, let i = info(current) else { break }
            if let path = executablePath(current), let app = outermostApp(inPath: path),
               let id = Bundle(path: app)?.bundleIdentifier {
                found = id
            }
            current = i.ppid
        }
        return found
    }
}
