import Foundation

/// Gemini CLI: its hooks have Claude Code's shape (`hooks.<Event>[].hooks[].command` in ~/.gemini/settings.json)
/// with other event names and timeouts in milliseconds. The helper turns its events into Claude's names, so the
/// same reducer folds them. Observation only: nothing is ever answered for Gemini.
public enum GeminiHooks {
    public static let flag = "--gemini"
    public static let events = ["SessionStart", "BeforeAgent", "BeforeTool", "AfterTool", "Notification", "AfterAgent",
                                "PreCompress", "SessionEnd"]

    public static var home: URL {
        if let h = ProcessInfo.processInfo.environment["GEMINI_CLI_HOME"], !h.isEmpty { return URL(fileURLWithPath: h) }
        return FileManager.default.homeDirectoryForCurrentUser
    }
    public static var settingsURL: URL { home.appendingPathComponent(".gemini/settings.json") }
    /// ~/.gemini/tmp/<project>/chats/session-….jsonl
    public static var chatsRoot: URL { home.appendingPathComponent(".gemini/tmp") }

    /// A Gemini hook payload rewritten with Claude Code's event names and fields; nil for events we skip.
    public static func normalize(_ json: [String: Any]) -> [String: Any]? {
        guard let name = json["hook_event_name"] as? String else { return nil }
        var out = json
        switch name {
        case "SessionStart", "SessionEnd": break
        case "BeforeAgent": out["hook_event_name"] = "UserPromptSubmit"
        case "BeforeTool": out["hook_event_name"] = "PreToolUse"
        case "AfterTool": out["hook_event_name"] = "PostToolUse"
        case "AfterAgent": out["hook_event_name"] = "Stop"
        case "PreCompress": out["hook_event_name"] = "PreCompact"
        case "Notification":
            // The only kind there is: a tool waits for the user's confirmation.
            guard json["notification_type"] as? String == "ToolPermission" else { return nil }
            out["notification_type"] = "permission_prompt"
            let details = json["details"] as? [String: Any]
            if let cmd = details?["command"] as? String, !cmd.isEmpty {
                out["message"] = "Shell: " + cmd
            } else if let file = details?["fileName"] as? String ?? details?["filePath"] as? String {
                out["message"] = (details?["title"] as? String ?? "Edit") + ": " + (file as NSString).lastPathComponent
            }
        default: return nil
        }
        return out
    }
}

/// opencode: no command hooks, but it loads any plugin file in ~/.config/opencode/plugins. Aureole writes a small
/// plugin of its own there that forwards session events to the helper (in Claude Code's terms) and appends each
/// finished reply's token counts to a log under Application Support for the ledger.
public enum OpencodePlugin {
    public static let flag = "--opencode"
    public static let marker = "aureole-opencode-plugin"

    public static var configDir: URL {
        if let x = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"], !x.isEmpty {
            return URL(fileURLWithPath: x).appendingPathComponent("opencode")
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/opencode")
    }
    public static var pluginURL: URL { configDir.appendingPathComponent("plugins/aureole.js") }
    /// One JSONL file per opencode session: `{"id","at","model","input","output","reasoning","cacheRead","cacheWrite"}`.
    public static var usageDir: URL { AureolePaths.appSupport.appendingPathComponent("opencode", isDirectory: true) }

    public static func isInstalled(at url: URL = pluginURL) -> Bool {
        (try? String(contentsOf: url, encoding: .utf8))?.contains(marker) == true
    }

    public static func install(helperPath: String, at url: URL = pluginURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: usageDir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try source(helperPath: helperPath, usageDir: usageDir.path).write(to: url, atomically: true, encoding: .utf8)
    }

    /// Removes the plugin only if it is ours.
    public static func remove(at url: URL = pluginURL) throws {
        guard isInstalled(at: url) else { return }
        try FileManager.default.removeItem(at: url)
    }

    static func js(_ s: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [s], options: [.withoutEscapingSlashes])
        let arr = data.flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        return String(arr.dropFirst().dropLast())
    }

    public static func source(helperPath: String, usageDir: String) -> String {
        """
        // \(marker): written by Aureole (https://github.com/xiyoushiguang/aureole). Remove it from Aureole's
        // settings, or delete this file. It only reports what sessions are doing to Aureole on this Mac.
        import { spawn } from "node:child_process"
        import { appendFileSync, mkdirSync } from "node:fs"

        const HELPER = \(js(helperPath))
        const USAGE = \(js(usageDir))

        export const AureolePlugin = async ({ directory }) => {
          const busy = new Map()      // sessionID -> true while a turn runs
          const children = new Set()  // sub-agent sessions: their work belongs to the parent's turn
          const prompts = new Map()   // sessionID -> the last prompt text
          const counted = new Set()   // assistant message ids already logged
          const send = (event, sessionID, extra = {}) => {
            if (!sessionID || children.has(sessionID)) return
            try {
              const p = spawn(HELPER, ["\(flag)"], { stdio: ["pipe", "ignore", "ignore"] })
              p.on("error", () => {})
              p.stdin.on("error", () => {})
              p.stdin.end(JSON.stringify({ hook_event_name: event, session_id: sessionID, cwd: directory, ...extra }))
            } catch {}
          }
          return {
            "chat.message": async (input, output) => {
              const text = (output?.parts ?? []).filter((x) => x.type === "text").map((x) => x.text).join("\\n")
              if (input?.sessionID && text) prompts.set(input.sessionID, text)
            },
            event: async ({ event }) => {
              const p = event?.properties ?? {}
              switch (event?.type) {
                case "session.created":
                case "session.updated":
                  if (p.info?.parentID) { children.add(p.info.id ?? p.sessionID); return }
                  if (event.type === "session.created") send("SessionStart", p.sessionID ?? p.info?.id)
                  if (p.info?.title) send("Title", p.sessionID ?? p.info?.id, { title: p.info.title })
                  return
                case "session.status":
                  if (p.status?.type === "busy" && !busy.get(p.sessionID)) {
                    busy.set(p.sessionID, true)
                    send("UserPromptSubmit", p.sessionID, { prompt: prompts.get(p.sessionID) ?? "" })
                  }
                  return
                case "session.idle":
                  busy.set(p.sessionID, false)
                  send("Stop", p.sessionID)
                  return
                case "session.deleted":
                  send("SessionEnd", p.sessionID ?? p.info?.id)
                  return
                case "message.part.updated": {
                  const part = p.part
                  if (part?.type !== "tool") return
                  const status = part.state?.status
                  if (status === "running") send("PreToolUse", part.sessionID, { tool_name: part.tool, tool_input: part.state?.input ?? {} })
                  else if (status === "completed" || status === "error") send("PostToolUse", part.sessionID, { tool_name: part.tool })
                  return
                }
                case "permission.asked":
                  send("Notification", p.sessionID, { notification_type: "permission_prompt",
                    message: [p.permission, ...(p.patterns ?? [])].filter(Boolean).join(": ") })
                  return
                case "question.asked":
                  send("Notification", p.sessionID, { notification_type: "elicitation_dialog",
                    message: p.questions?.[0]?.question ?? "" })
                  return
                case "permission.replied":
                case "question.replied":
                case "question.rejected":
                  send("PostToolUse", p.sessionID)
                  return
                case "message.updated": {
                  const m = p.info
                  if (m?.role !== "assistant" || !m.time?.completed || counted.has(m.id)) return
                  counted.add(m.id)
                  const t = m.tokens ?? {}
                  const line = { id: m.id, at: m.time.completed, model: m.modelID, provider: m.providerID,
                    input: t.input ?? 0, output: t.output ?? 0, reasoning: t.reasoning ?? 0,
                    cacheRead: t.cache?.read ?? 0, cacheWrite: t.cache?.write ?? 0, cwd: m.path?.cwd ?? directory }
                  try {
                    mkdirSync(USAGE, { recursive: true, mode: 0o700 })
                    appendFileSync(`${USAGE}/${String(m.sessionID).replace(/[^A-Za-z0-9_-]/g, "")}.jsonl`, JSON.stringify(line) + "\\n", { mode: 0o600 })
                  } catch {}
                  return
                }
              }
            },
          }
        }

        """
    }
}

extension TranscriptLines {
    /// A Gemini CLI chat record with token counts. Gemini counts cached and tool-use prompt tokens inside the
    /// prompt and bills thinking as output; returned in the same buckets as Claude's.
    public static func gemini(_ line: Data) -> (id: String?, call: LedgerCall)? {
        guard line.range(of: Data("\"tokens\"".utf8)) != nil,
              let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              obj["type"] as? String == "gemini", let t = obj["tokens"] as? [String: Any],
              let at = DateParsing.parse(obj["timestamp"]) else { return nil }
        func n(_ k: String) -> Int { (t[k] as? NSNumber)?.intValue ?? 0 }
        let cached = n("cached")
        let tally = TokenTally(input: max(0, n("input") - cached) + n("tool"), cacheRead: cached, output: n("output") + n("thoughts"))
        guard !tally.isEmpty else { return nil }
        return (obj["id"] as? String, LedgerCall(at: at, model: obj["model"] as? String ?? "gemini", tally: tally))
    }

    /// The first line of a Gemini chat file: its session id.
    public static func geminiSession(_ line: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any], obj["type"] == nil else { return nil }
        return obj["sessionId"] as? String
    }

    /// A line of the usage log Aureole's opencode plugin writes. opencode's input excludes cache reads and writes.
    public static func opencode(_ line: Data) -> (id: String?, call: LedgerCall, cwd: String?)? {
        guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let ms = (obj["at"] as? NSNumber)?.doubleValue else { return nil }
        func n(_ k: String) -> Int { (obj[k] as? NSNumber)?.intValue ?? 0 }
        let tally = TokenTally(input: n("input"), cacheWrite5m: n("cacheWrite"), cacheRead: n("cacheRead"),
                               output: n("output") + n("reasoning"))
        guard !tally.isEmpty else { return nil }
        let model = obj["model"] as? String ?? "opencode"
        return (obj["id"] as? String, LedgerCall(at: Date(timeIntervalSince1970: ms / 1000), model: model, tally: tally),
                obj["cwd"] as? String)
    }
}
