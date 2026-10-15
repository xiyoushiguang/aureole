import Foundation
import AureoleCore

/// Made-up numbers and sessions for `--demo` and `--snapshot`: a Claude window running out before its reset, a
/// session waiting on a permission, others working or done, a Codex run and a script's lane. Everything is
/// relative to `now`, so a snapshot always looks current. No real names, folders or prompts.
enum DemoData {
    static let billing = "demo-billing-refactor"
    static let notes = "demo-release-notes"
    static let login = "demo-login-page"
    static let explore = "demo-explore"
    static let codexCI = "demo-codex-ci"
    static let nightly = "task-nightly-backup"

    static func usage(now: Date) -> [ProviderSnapshot] {
        let start = now.addingTimeInterval(-160 * 60)          // the 5-hour window began 2 h 40 min ago
        let reset = start.addingTimeInterval(5 * 3600)
        let weekReset = now.addingTimeInterval(3 * 86400 + 5 * 3600)
        var out: [ProviderSnapshot] = []
        // Readings every two minutes: a slow first hour, then two busy sessions.
        var used = 0.0
        var t = start
        while t < now {
            let m = t.timeIntervalSince(start) / 60
            used += m < 60 ? 0.3 : m < 100 ? 0.9 : 1.2
            let windows = [
                UsageWindow(key: "five_hour", label: "5h", kind: .fiveHour, usedPercent: min(used, 62), resetsAt: reset, duration: 5 * 3600),
                UsageWindow(key: "seven_day", label: "Week", kind: .sevenDay, usedPercent: 41, resetsAt: weekReset, duration: 7 * 86400),
            ]
            out.append(ProviderSnapshot(provider: .claude, windows: windows, fetchedAt: t, planLabel: "Max"))
            t = t.addingTimeInterval(120)
        }
        let last = UsageWindow(key: "five_hour", label: "5h", kind: .fiveHour, usedPercent: 62, resetsAt: reset, duration: 5 * 3600)
        out.append(ProviderSnapshot(provider: .claude, windows: [last, UsageWindow(key: "seven_day", label: "Week", kind: .sevenDay,
                                                                                    usedPercent: 41, resetsAt: weekReset, duration: 7 * 86400)],
                                    fetchedAt: now, planLabel: "Max"))
        out.append(ProviderSnapshot(provider: .codex, windows: [
            UsageWindow(key: "primary", label: "Week", kind: .sevenDay, usedPercent: 34, resetsAt: now.addingTimeInterval(4 * 86400), duration: 7 * 86400),
        ], fetchedAt: now, planLabel: "Pro"))
        return out
    }

    struct Sessions {
        var list: [AgentSession]
        var titles: [String: String]
        var context: [String: Int]
        var approvals: [ApprovalRequest]
    }

    static func sessions(now: Date) -> Sessions {
        func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
        func session(_ id: String, _ p: ProviderID, cwd: String, started: Double) -> AgentSession {
            var s = AgentSession(provider: p, sessionId: id, cwd: cwd, now: ago(started))
            s.termProgram = "iTerm.app"
            return s
        }

        var billing = session(Self.billing, .claude, cwd: "~/work/shop-api", started: 95)
        billing.set(.working, at: ago(92)); billing.set(.idle, at: ago(70)); billing.set(.working, at: ago(64))
        billing.turnStartedAt = ago(64)
        billing.lastTool = "Bash"; billing.lastDetail = "npm run test -- --watch=false"
        billing.recent = [SessionActivity(at: ago(2), text: "Bash · npm run test -- --watch=false"),
                          SessionActivity(at: ago(4), text: "Edit · invoice.ts"), SessionActivity(at: ago(6), text: "Read · tax.ts")]
        billing.promptPreview = "Move the tax rules out of the invoice service"
        billing.set(.waitingPermission, at: ago(1.7))
        billing.waitingMessage = "Bash: npm run test -- --watch=false"
        billing.updatedAt = ago(1.7)

        var notes = session(Self.notes, .claude, cwd: "~/work/shop-api", started: 40)
        notes.set(.working, at: ago(38)); notes.set(.idle, at: ago(30)); notes.set(.working, at: ago(18))
        notes.turnStartedAt = ago(18)
        notes.lastTool = "Edit"; notes.lastDetail = "CHANGELOG.md"
        notes.promptPreview = "Draft the notes for 2.4"
        notes.updatedAt = ago(0.3)

        var login = session(Self.login, .claude, cwd: "~/work/web", started: 150)
        login.set(.working, at: ago(148)); login.set(.idle, at: ago(110)); login.set(.working, at: ago(17))
        login.turnStartedAt = ago(17)
        login.set(.idle, at: ago(3))
        login.lastEvent = "Stop"
        login.promptPreview = "Switch the login page to the new form"
        login.updatedAt = ago(3)

        var ci = session(Self.codexCI, .codex, cwd: "~/work/shop-api", started: 50)
        ci.set(.working, at: ago(48)); ci.set(.idle, at: ago(35)); ci.set(.working, at: ago(12))
        ci.turnStartedAt = ago(12)
        ci.lastTool = "shell"; ci.lastDetail = "pytest tests/test_api.py -x"
        ci.updatedAt = ago(0.5)

        var nightly = TaskLaneUpdate(id: "nightly-backup", state: .working, name: "Nightly backup", detail: "Uploading photos 4 of 10",
                                     progress: 0.4).apply(to: nil, now: ago(26))!
        nightly.updatedAt = ago(1)

        let titles = [Self.billing: "Refactor the billing service", Self.notes: "Write the release notes",
                      Self.login: "Migrate the login page", Self.codexCI: "Fix the flaky CI test"]
        let approval = ApprovalRequest(id: "demo-approval", sessionId: Self.billing, provider: .claude, tool: "Bash",
                                       full: "npm run test -- --watch=false", at: ago(1.7), expires: now.addingTimeInterval(42),
                                       alwaysRule: "Bash(npm run test:*)")
        return Sessions(list: [billing, notes, login, ci, nightly], titles: titles,
                        context: [Self.billing: 412_000, Self.notes: 48_000, Self.login: 131_000], approvals: [approval])
    }

    /// Token use that matches the story above: the waiting session did most of the recent work.
    static func ledger(now: Date) -> TokenLedger {
        var l = TokenLedger()
        func spend(_ session: String, _ p: ProviderID, model: String, from: Double, to: Double, perMinute: TokenTally) {
            var m = from
            while m > to {
                l.add(LedgerCall(at: now.addingTimeInterval(-m * 60), model: model, tally: perMinute), provider: p, session: session)
                m -= 1
            }
        }
        let heavy = TokenTally(input: 40, cacheWrite1h: 9_000, cacheRead: 240_000, output: 2_600)
        let light = TokenTally(input: 20, cacheWrite1h: 4_000, cacheRead: 90_000, output: 1_200)
        spend(Self.explore, .claude, model: "claude-opus-5-5", from: 158, to: 100, perMinute: light)
        spend(Self.login, .claude, model: "claude-opus-5-5", from: 148, to: 110, perMinute: light)
        spend(Self.billing, .claude, model: "claude-opus-5-5", from: 92, to: 70, perMinute: light)
        spend(Self.billing, .claude, model: "claude-opus-5-5", from: 64, to: 2, perMinute: heavy)
        spend(Self.notes, .claude, model: "claude-sonnet-5-5", from: 38, to: 30, perMinute: light)
        spend(Self.notes, .claude, model: "claude-sonnet-5-5", from: 18, to: 0, perMinute: light)
        spend(Self.login, .claude, model: "claude-opus-5-5", from: 17, to: 3, perMinute: light)
        spend(Self.codexCI, .codex, model: "gpt-5.6-terra", from: 48, to: 35, perMinute: light)
        spend(Self.codexCI, .codex, model: "gpt-5.6-terra", from: 12, to: 0, perMinute: light)
        l.titles = [Self.explore: "Explore the codebase", Self.billing: "Refactor the billing service",
                    Self.notes: "Write the release notes", Self.login: "Migrate the login page"]
        return l
    }
}
