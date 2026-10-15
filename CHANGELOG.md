# Changelog

## 0.7.0 — 2026-10-15

- **Gemini CLI and opencode.** Settings → Sessions installs Aureole's helper into Gemini CLI's hooks
  (`~/.gemini/settings.json`) or a small plugin for opencode (`~/.config/opencode/plugins/aureole.js`).
  Their sessions get lanes with state, current tool, waiting-for-permission, titles, tokens and value at
  API prices (Gemini prices from Google's pricing page, including the increases it announces). Observed
  only: approving from the panel stays Claude Code and Codex.
- **Spend history.** Settings → Spend: value at API prices per day (30 days, 90 days, a year) and per
  month for each agent. Day totals are kept for 400 days; the first launch reads back as far as the
  transcripts on disk go (a few seconds, in the background).
- **Prices** for gpt-6 models (Codex's current default was showing no value) and OpenAI's long-context
  rates above 272K input tokens.
- **Always allow** reads plainly when Claude Code offers a session change rather than a rule
  ("folder proj, accept edits (this session)"); verified end to end against Claude Code 2.1.296.
- The request box on an approval card is as tall as the request, up to 140 pt, instead of always 140.
- The ServerChan channel is now listed as **WeChat**, with setup steps under it.
- README: an animated tour (rendered from the demo data), Homebrew install.
- Fixed: a script lane that reports `done` and exits right away now stays (with its check mark, and
  announced) for 30 minutes instead of vanishing within seconds.
- Fixed: lane ids that differ only by a dot (`a.b`, `ab`) no longer share one record.
- Fixed (new in this version): a Codex thread resumed more than 8 days after it began is counted again;
  rebuilding the ledger keeps day totals whose transcripts are gone; opencode events reach Aureole in
  order; the spend chart keeps both agents' bars on a shared day.

## 0.6.0 — 2026-10-14

- **Who used the quota.** The usage area on the horizon is split into one band per session, by what each
  session spent while the curve rose; a legend under the arc and each lane give the share. An estimate,
  labelled as one; rises with no tokens behind them count as *other*.
- **API-price value.** A token ledger read from Claude Code transcripts (sub-agents counted to their
  session) and Codex rollouts, incrementally, about 2 ms a pass: tokens, cache hit rate and the value at
  public API prices per session (`≈$3.2` on the lane, the full breakdown on its card) and for the window.
- **Always allow, exactly as offered.** When Claude Code suggests a standing rule for a permission prompt,
  the card offers **Always allow** with that rule on the button and hands it back unchanged.
- **Lanes for your scripts.** `aureole-hook --lane <id> --state working|waiting|done|idle|end` puts a
  nightly job or a long build on the time axis; it leaves when the script exits.
- **Demo and snapshots.** `scripts/demo.sh` opens the app with sample data; `scripts/snapshot.sh` renders
  the panel to PNG (English and Chinese) for README pictures and before/after comparisons.
- **Hide with ⌃⌥⌘A** (or the menu bar item), for screen sharing.
- **Settings warn about other hooks** on the same events (another app answering permission prompts or
  announcing finished turns would make alerts arrive twice).
- The "Used %" label moves clear of the "Now" pill when usage is high.

## 0.5.0 — 2026-10-09

- **Quieter notifications.** Nothing is sent while the session's terminal or app is in front and you are
  at the Mac. **Mute** a session from its card. **Quiet hours** (Settings → General) hold back every push.
- **Background runs** (`claude -p`, `codex exec`, scripts with no terminal) are listed apart, marked
  *Background*, and never notified, so a night job no longer pings you at 3 a.m.
- **Sessions you can tell apart.** Untitled sessions are named by their first prompt; Codex sessions use
  the titles Codex gives its threads; two sessions that would read the same get "· 2".
- **Answer Claude's questions from the panel** (with panel approvals on): pick an option, Send answer.
- **Choose the screen:** the notch screen, the main display, or whichever screen the pointer is on.
- **One-click update:** downloads, verifies the signature and Gatekeeper, swaps the app, relaunches.
- **Uninstall Aureole…** removes the hooks and status line it added, restores yours, and trashes its data.
  The README now explains manual cleanup too.
- **Copy diagnostics** for bug reports (no tokens, prompts or names).
- **Freshness per provider** in the panel header, amber when a provider's numbers are over ten minutes old.
- **Extra usage spend** shows when you have any (status line `spend_limit`, or the endpoint's extra usage).

## 0.4.1 — 2026-10-08

- **Motion that marks news.** A session that has just started waiting sends out a ripple; one that has
  just finished pops in its check mark; lanes slide to their new place; the closed notch's dot bumps
  when the count rises; Allow once / Deny confirm on the card (or say it was too late).
- **Ambient motion.** The lit stretch of horizon breathes and the forecast flows toward where it ends;
  new readings slide the curve into place; numbers roll. Off in Settings, and with Reduce Motion.
- **Much less CPU.** Animations run on Core Animation at low frame rates over small areas. Fixes an
  older drain: while a session waited, the pulsing kept Aureole at about 5% CPU with the panel closed
  (28% open, plus the window server); now about 0.2% (1–2%).
- **Esc closes the panel** once Accessibility is granted (offered in Settings → General).
- **Clearer alerts:** "✅ … is done", "🟠 … needs your approval", "🟠 … has a question for you".
- If macOS refuses notifications, the log now says so instead of staying silent.

## 0.4.0 — 2026-10-03

- **Signed and notarized.** Releases are signed with a Developer ID and notarized by Apple: no more
  Privacy & Security detour on first launch.
- **Finds your agents.** The welcome guide scans for Claude Code and Codex (command line and desktop
  apps) and for where each running session lives, a terminal or a desktop app, and says what a click
  will do there. Sessions inside a desktop app (e.g. Codex) bring that app forward.
- Horizon labels no longer overlap ("no quota here" vs. "steady pace", hour marks vs. the reset).
- **Codex sessions.** Codex now has hooks; Settings → Sessions → Codex hooks registers the same helper
  in `~/.codex/hooks.json` (your `notify` setting is left alone). Codex asks you to trust it once.
- **Approve from the panel** (opt-in, off by default). Hover a waiting session: the card shows the full
  request and offers *Allow once* or *Deny*. Nothing is allowed without that click, there is no "always
  allow", and if you do not answer within 15/30/60 s the terminal asks as usual.
- **More terminals.** Jump to WezTerm and kitty panes, Ghostty 1.3+ tabs, and the VS Code or Cursor
  window that has the session's folder. Warp and Alacritty come to the front.
- **Quiet and nearly full.** A working session with no event for ten minutes, or a context past 85%,
  is called out on its lane.
- **Welcome guide** on first launch (sign-ins, hooks, status line, notifications, launch at login), and
  a once-a-day check for a newer release that shows "New version x.y.z ›" in the panel.

## 0.3.0 — 2026-10-02

- **Weekly forecast.** Weekly windows (and per-model weeklies, and Codex's weekly) are forecast from
  the week's average pace, shown as %/day with a weekday ("runs out Thu 15:00"), and announced once
  from 20% when they would run out before the reset. The half-hour fit used before swung wildly over days.
- **Usage from Claude Code's status line** (Settings → Sessions, opt-in). Claude Code hands its status
  line the 5-hour and weekly numbers and each session's exact context use; Aureole reads them there
  and asks the usage endpoint only every ten minutes while they keep coming (for per-model windows).
  Context % becomes exact instead of estimated. A status line you already have keeps running.
- **The closed notch says when something needs you.** A line drops below the notch:
  "● Waiting 2 · ✓ Done 1", the dot breathing while a session waits. No need to hover to find out.
- **Notifications for sessions.** A session that has waited on you for 2 minutes (configurable, or off)
  and a task that finished are announced through the same channels as usage alerts: macOS
  notifications, WeChat (ServerChan), Bark, Telegram and the rest. Each wait and each finish once.
- **Done, unseen.** A turn that ran a minute or more and then stopped shows as a blue "done · unseen"
  lane until you jump to it, instead of looking like any other idle session.

## 0.2.1 — 2026-10-01

- **Waiting capsule.** Sessions that need you get an amber capsule under the conclusion, with a jump
  button for each (two, then +N).
- **Details card.** Hover a lane to see what the session is requesting, its prompt, its last tool
  calls, context size and folder, with a Jump to terminal button.
- English layout fix: the top row no longer truncates the conclusion or the Codex line.

## 0.2.0 — 2026-10-01

- **Horizon panel.** Time runs along a planet's edge with "now" at the sun; the arc shows usage,
  forecast, steady pace and reset.
- **A lane per Claude Code session** on the same clock: past working/waiting stretches, a light with
  a context ring, and what it is doing now. Waiting sessions first; click to jump to the terminal.
- Session tracking through Claude Code hooks (Settings → Sessions → Install hooks).
- List layout as an alternative (Settings → Panel layout).
- Simplified Chinese README.
- Fix: clicking a session no longer freezes the panel while macOS asks for Automation permission.

## 0.1.0 — 2026-09-30

- First public release: Claude and Codex 5-hour and weekly windows in the notch, pace bars, reset
  times, burn-rate forecast, routing hint, notifications to macOS and a dozen chat services,
  English and Simplified Chinese.
