# Changelog

## 1.1.0

- Add persistent menu checkboxes for Claude Code and Codex. Disabled services are hidden and excluded from automatic and manual refreshes; switching cancels the current reader.
- Detect the Codex plan from local session logs and show it in the menu. Render actual quota window durations for Plus and Pro, including weekly-only accounts.
- Omit missing Codex windows and show unknown usage after a recorded reset expires instead of inventing 0% usage. Codex refreshes remain local-only.
- Add an About QuotaStrip panel with the app version, build number, and GitHub link.
- Add regression coverage for service selection, local-only reads, account switching, and quota window mapping.
