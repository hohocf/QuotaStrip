#!/bin/bash
# Optional: enable the "waiting for you" reminder badge.
#
# Claude already works with zero config (QuotaStrip reads session logs). This script adds:
#   - Claude hooks  -> ~/.claude/settings.json   (precise, instant badge)
#   - Codex notify  -> ~/.codex/config.toml       (Codex has no log heuristic, needs this)
#
# Safe to re-run: it backs up each file once and is idempotent. Requires python3 (bundled with macOS).
set -e

CACHE="$HOME/.cache/quotastrip"
NOTIFY="/Applications/QuotaStrip.app/Contents/Resources/codex_notify.sh"
[ -f "$NOTIFY" ] || NOTIFY="$(cd "$(dirname "$0")" && pwd)/Resources/codex_notify.sh"

echo "QuotaStrip: installing waiting-reminder hooks"
echo "  codex notify script: $NOTIFY"

# ---- Claude: ~/.claude/settings.json -------------------------------------------------
CLAUDE_SETTINGS="$HOME/.claude/settings.json"
mkdir -p "$HOME/.claude"
[ -f "$CLAUDE_SETTINGS" ] || echo '{}' > "$CLAUDE_SETTINGS"
[ -f "$CLAUDE_SETTINGS.quotastrip-bak" ] || cp "$CLAUDE_SETTINGS" "$CLAUDE_SETTINGS.quotastrip-bak"

CACHE="$CACHE" python3 - "$CLAUDE_SETTINGS" <<'PY'
import json, os, sys
p = sys.argv[1]; cache = os.environ["CACHE"]
s = json.load(open(p))
touch = {"type": "command", "command": f"mkdir -p {cache} && touch {cache}/claude_attention"}
clear = {"type": "command", "command": f"rm -f {cache}/claude_attention"}
h = s.setdefault("hooks", {})
# Stop / Notification -> show badge ; UserPromptSubmit / SessionEnd -> clear
h["Stop"] = [{"hooks": [touch]}]
h["Notification"] = [{"hooks": [touch]}]
h["UserPromptSubmit"] = [{"hooks": [clear]}]
h["SessionEnd"] = [{"hooks": [clear]}]
json.dump(s, open(p, "w"), indent=2, ensure_ascii=False)
print("  updated", p)
PY

# ---- Codex: ~/.codex/config.toml -----------------------------------------------------
CODEX_CONFIG="$HOME/.codex/config.toml"
if [ -f "$CODEX_CONFIG" ]; then
    [ -f "$CODEX_CONFIG.quotastrip-bak" ] || cp "$CODEX_CONFIG" "$CODEX_CONFIG.quotastrip-bak"
    if grep -q '^notify' "$CODEX_CONFIG"; then
        echo "  note: ~/.codex/config.toml already has a 'notify' key; leaving it untouched."
        echo "        To enable, set:  notify = [\"$NOTIFY\"]"
    else
        printf '\nnotify = ["%s"]\n' "$NOTIFY" >> "$CODEX_CONFIG"
        echo "  updated $CODEX_CONFIG"
    fi
else
    echo "  skipped Codex (no ~/.codex/config.toml; run Codex once first, then re-run this)."
fi

echo "Done. New Claude sessions and Codex will now flag QuotaStrip when waiting for you."
echo "Backups saved as *.quotastrip-bak"
