# QuotaStrip

**See your Claude Code and Codex usage quota right on the MacBook Pro Touch Bar.**

[简体中文](README.zh-CN.md)

That old Touch Bar nobody uses? QuotaStrip turns it into a live dashboard for your AI coding
agents. No more guessing how much quota you have left or getting surprised by a rate limit
mid-task — it's always there, one glance away.

![QuotaStrip on the Touch Bar](docs/screenshot.png)

Each service gets its own panel: a brand logo, plus two rows — your **5-hour window** and your
**weekly quota** — each with a progress bar, the exact percentage, and when it resets.

---

## Features

**Two services, two windows, at a glance**
- Claude and Codex side by side, each showing the **5-hour** and **7-day** windows.
- Progress bar + **bold right-aligned percentage** + reset time on every row.
- Brand logos so you can tell them apart instantly.

**Color coding that warns you early**
- Bars and percentages go **green → yellow (≥50%) → red (≥80%)** as you burn through quota.

**Reset times done right**
- The 5h row shows the **reset clock time** (24-hour, no am/pm).
- The 7d row shows **time remaining** (e.g. `2d9h`) so you know how long you've got.
- When the 5h window is **under 30 minutes from resetting**, its time turns **yellow** — a nudge
  to spend the rest of the window before it refills.

**"It's waiting for you" reminder** 🔴
- When Claude or Codex stops and **waits for your input or a permission confirmation**, a red `!`
  badge appears on its logo (and in the menu bar). You'll know to go respond instead of leaving it
  hanging.
- Detection is **two-layer**: a zero-config heuristic that reads session logs (works out of the
  box, even for sessions already running) plus optional hooks for instant precision.
- The badge clears the moment you reply, or when you tap the panel.

**Tap to jump in**
- Tap a panel to **bring the matching desktop app to the front** (Claude.app / Codex.app). Not
  installed? It opens the usage webpage instead.

**Honest about rate limits**
- Anthropic's usage endpoint is rate-limited. When it returns 429, QuotaStrip shows the last known
  numbers with a small **yellow dot**, and strictly honors the server's `Retry-After` before trying
  again. A window whose reset time has passed is shown as 0% so you're never misled by stale highs.
- A **connection log** (menu → *View connection log*) records every real request: `ok`, `429`, or
  network errors. Cache hits aren't logged.

**Stays out of your way**
- Keeps the system **Control Strip** on the right and an **esc** key on the left.
- Restores itself when your Mac wakes from sleep.
- Menu-bar gauge icon with: *Refresh now* (forced), *Re-show Touch Bar*, open usage pages,
  *View connection log*, *Start at login*, *Quit*.

---

## Install

### Option A — Download (recommended)

1. Grab `QuotaStrip.zip` from the [Releases](../../releases) page and unzip it.
2. Drag **QuotaStrip.app** into your **Applications** folder.
3. **First launch:** right-click the app → **Open** (this is needed once because the app isn't
   notarized — see [Why the warning?](#why-the-gatekeeper-warning) below).
4. When prompted, enable QuotaStrip under **System Settings → Privacy & Security → Accessibility**
   (only needed for the **esc** key — quota display works without it).
5. *(Optional)* Run `./install-hooks.sh` to enable the Codex "waiting for you" reminder.

That's it — the panels appear on your Touch Bar.

### Option B — Build from source

Requires Xcode command-line tools (`xcode-select --install`).

```bash
git clone https://github.com/hohocf/QuotaStrip.git
cd QuotaStrip
./build.sh --run
```

`build.sh` compiles a **universal binary** (Intel + Apple Silicon), bundles everything, and
ad-hoc signs the app.

---

## How it works

QuotaStrip lives in the Touch Bar via the same private `DFRFoundation` API that
[MTMR](https://github.com/Toxblh/MTMR) and [Pock](https://github.com/pigigaldi/Pock) use. A small
bundled Python script (`quota.py`) provides the data:

- **Claude** — uses your **existing Claude Code login** (OAuth token from the macOS keychain) to
  call Anthropic's official **read-only** usage endpoint. Cached ~10 minutes; never polled
  aggressively.
- **Codex** — parsed **100% locally** from `~/.codex/sessions` logs. **Zero network requests.**

The app refreshes every 20 seconds. Codex and the waiting-reminder are real-time; Claude's numbers
come from the ~10-minute cache (force a live fetch any time via menu → *Refresh now*).

---

## Compatibility

- Any **Touch Bar MacBook Pro** — Intel (2016–2020) and the Apple Silicon 13" (M1 2020 / M2 2022).
  The release is a universal binary, native on both.
- macOS 11+ for the app itself. **Start at login** needs macOS 13+ (everything else works below it).

---

## Privacy & "will this get my account banned?"

Short answer: **very low risk.** QuotaStrip is deliberately polite:

- **Read-only.** It only *queries* your usage — the same endpoint Claude Code itself uses for
  `/usage`. It never makes inference requests, never impersonates a client, never bypasses anything.
- **Local-first.** Codex data never leaves your machine. Your Claude token never leaves your machine.
- **Respects rate limits.** On 429 it backs off exactly as the server asks (`Retry-After`).

This is the same category of tool as other community usage widgets. The realistic risks are that
Anthropic's *unofficial* usage endpoint could change one day (the worst case is the panel shows
"no data" until updated), not anything account-level. If you want to be extra conservative, raise
`CLAUDE_CACHE_TTL` in `quota.py`.

---

## Why the Gatekeeper warning?

This is a free, open-source project without a paid Apple Developer account ($99/yr), so the app is
**ad-hoc signed**, not notarized. macOS will warn on first open. Either:

- **Right-click → Open** once (then it's trusted), or
- Remove the quarantine flag:
  ```bash
  xattr -dr com.apple.quarantine /Applications/QuotaStrip.app
  ```

This is standard for indie open-source Mac tools (MTMR, Pock, etc.). The source is right here —
read it, or build it yourself.

---

## License

[MIT](LICENSE) © hohocf

Logos for Claude and Codex belong to Anthropic and OpenAI respectively and are used only to
identify each service.
