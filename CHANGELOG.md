# Changelog

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
