#!/bin/bash
# Codex notify hook: called when Codex stops to wait for input/approval.
# Drops an attention marker that quota.py reads; it auto-clears when the session
# logs new activity, or when you tap the QuotaStrip panel.
mkdir -p "$HOME/.cache/quotastrip"
touch "$HOME/.cache/quotastrip/codex_attention"
